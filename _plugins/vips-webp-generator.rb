# Vips WebP generator
# Converts JPG and PNG under assets/images to WebP during Jekyll build using libvips.
# Generates multiple responsive sizes for automatic srcset usage.

module ItalAI
  class VipsWebpGenerator
    IMAGE_EXTS = %w[.jpg .jpeg .png].freeze
    # Generate these widths for responsive images
    SIZES = [400, 800, 1200, 1600].freeze
    QUALITY = 78  # Reduced for better compression
    EFFORT = 6    # Increased for better compression
    SAVE_OPTIONS = { Q: QUALITY, effort: EFFORT, strip: true }.freeze

    def self.run(site)
      require "vips"
      require "parallel"
    rescue LoadError => e
      warn "[vips-webp] Missing dependencies: #{e.message}"
      warn "[vips-webp] Responsive images must be pre-generated locally or in CI"
      return
    else
      # Only process source images - Jekyll will copy them to _site
      image_dir = File.join(site.source, "assets", "images")
      return unless Dir.exist?(image_dir)

      @force_regen = ENV["WEBP_FORCE_REGEN"] == "1"
      
      paths = Dir.glob(File.join(image_dir, "**", "*"), File::FNM_CASEFOLD).select do |path|
        IMAGE_EXTS.include?(File.extname(path).downcase) && !(File.basename(path) =~ /-\d+w\.webp$/i)
      end
      sources_by_base = {}
      paths.each do |path|
        base_path = path.sub(/\.(jpe?g|png)\z/i, "")
        sources_by_base[base_path] ||= path
      end
      paths = sources_by_base.values

      @path_locks_mutex = Mutex.new
      @path_locks = {}
      
      log_info "Found #{paths.size} source images to process"
      
      worker_count = ENV.fetch("WEBP_WORKERS", Parallel.processor_count).to_i
      worker_count = 1 if worker_count < 1

      Parallel.each_with_index(paths, in_threads: worker_count) do |path, index|
        Thread.current[:webp_worker_id] = (index % worker_count) + 1
        generate_responsive_images(path)
      end
    end

    def self.generate_responsive_images(path)
      base_path = path.sub(/\.(jpe?g|png)\z/i, "")

      with_path_lock(base_path) do
        begin
          source_mtime = File.mtime(path)

          # Fast path: if outputs exist and are newer than source, skip entirely
          unless @force_regen
            cleanup_zero_outputs(base_path)
            if base_output_fresh?(base_path, source_mtime)
              original_width = read_image_width(path)
              if outputs_fresh?(base_path, source_mtime, original_width)
                log_info "✓ #{File.basename(path)} (fresh outputs)"
                return
              end
            end
          end

          # Load image for processing
          image = Vips::Image.new_from_file(path, access: :random)
          image = image.autorot if image.respond_to?(:autorot)
          original_width = image.width

          # Clean up any stale files BEFORE generating new ones
          cleanup_stale_responsive_images(base_path, original_width)

          # Generate the base .webp file (for src attribute)
          base_webp_path = "#{base_path}.webp"
          image.webpsave(base_webp_path, **SAVE_OPTIONS)
          if File.size?(base_webp_path)
            log_info "#{File.basename(path)} -> #{File.basename(base_webp_path)}"
          else
            File.delete(base_webp_path) if File.exist?(base_webp_path)
            log_warn "failed to generate #{File.basename(base_webp_path)} - file is empty"
            return
          end

          # Generate responsive sizes (for srcset attribute)
          SIZES.each do |width|
            next if width > original_width
            
            webp_path = "#{base_path}-#{width}w.webp"
            resized = image.thumbnail_image(width)
            resized.webpsave(webp_path, **SAVE_OPTIONS)
            
            # Verify the file was created successfully
            if File.size?(webp_path)
              log_info "#{File.basename(path)} -> #{File.basename(webp_path)}"
            else
              File.delete(webp_path) if File.exist?(webp_path)
              log_warn "failed to generate #{File.basename(webp_path)} - file is empty"
            end
          end
        rescue StandardError => e
          log_warn "failed on #{path}: #{e.message}"
        end
      end
    end

    def self.with_path_lock(base_path)
      lock = @path_locks_mutex.synchronize do
        @path_locks[base_path] ||= Mutex.new
      end

      lock.synchronize { yield }
    end

    def self.base_output_fresh?(base_path, source_mtime)
      base_webp_path = "#{base_path}.webp"
      if File.exist?(base_webp_path) && !File.size?(base_webp_path)
        File.delete(base_webp_path)
        return false
      end
      return false unless File.size?(base_webp_path)
      File.mtime(base_webp_path) >= source_mtime
    rescue StandardError
      false
    end

    def self.read_image_width(path)
      image = Vips::Image.new_from_file(path, access: :sequential)
      image = image.autorot if image.respond_to?(:autorot)
      image.width
    rescue StandardError
      0
    end

    def self.outputs_fresh?(base_path, source_mtime, original_width)
      base_webp_path = "#{base_path}.webp"
      if File.exist?(base_webp_path) && !File.size?(base_webp_path)
        File.delete(base_webp_path)
        return false
      end
      return false unless File.size?(base_webp_path)
      return false if File.mtime(base_webp_path) < source_mtime

      expected_sizes = SIZES.select { |w| w <= original_width }
      expected_sizes.each do |width|
        webp_path = "#{base_path}-#{width}w.webp"
        if File.exist?(webp_path) && !File.size?(webp_path)
          File.delete(webp_path)
          return false
        end
        return false unless File.size?(webp_path)
        return false if File.mtime(webp_path) < source_mtime
      end

      true
    rescue StandardError => e
      log_warn "failed to check freshness for #{File.basename(base_path)}: #{e.message}"
      false
    end

    def self.cleanup_zero_outputs(base_path)
      paths = ["#{base_path}.webp"]
      SIZES.each { |width| paths << "#{base_path}-#{width}w.webp" }

      paths.each do |webp_path|
        next unless File.exist?(webp_path)
        next if File.size?(webp_path)

        File.delete(webp_path)
        log_info "removed empty #{File.basename(webp_path)}"
      end
    rescue StandardError => e
      log_warn "failed to clean empty outputs for #{File.basename(base_path)}: #{e.message}"
    end

    def self.cleanup_stale_responsive_images(base_path, original_width)
      expected_sizes = SIZES.select { |w| w <= original_width }
      
      # Get the directory and base filename
      dir = File.dirname(base_path)
      base_name = File.basename(base_path)

      # Only look for files that match THIS specific base name with exact pattern
      pattern = File.join(dir, "#{base_name}-[0-9]*w.webp")
      
      Dir.glob(pattern).each do |webp_path|
        # Ensure we only match files that are exactly "basename-123w.webp"
        # and not "basename-something-123w.webp"
        basename_pattern = /\A#{Regexp.escape(base_name)}-(\d+)w\.webp\z/i
        match = basename_pattern.match(File.basename(webp_path))
        next unless match

        width = match[1].to_i
        next if expected_sizes.include?(width)

        File.delete(webp_path)
        log_info "removed stale #{File.basename(webp_path)}"
      end
    rescue StandardError => e
      log_warn "failed to clean stale images for #{File.basename(base_path)}: #{e.message}"
    end

    def self.log_info(message)
      worker = Thread.current[:webp_worker_id]
      prefix = worker ? "[worker-#{worker}]" : ""
      puts "[vips-webp]#{prefix} #{message}"
    end

    def self.log_warn(message)
      worker = Thread.current[:webp_worker_id]
      prefix = worker ? "[worker-#{worker}]" : ""
      warn "[vips-webp]#{prefix} #{message}"
    end

  end
end

Jekyll::Hooks.register :site, :after_init do |site|
  ItalAI::VipsWebpGenerator.run(site)
end