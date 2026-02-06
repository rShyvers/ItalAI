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
    CACHE_FILENAME = ".webp-cache.json".freeze

    def self.run(site)
      require "vips"
      require "json"
      require "digest"
    rescue LoadError => e
      warn "[vips-webp] ruby-vips not available: #{e.message}"
      warn "[vips-webp] Responsive images must be pre-generated locally or in CI"
      return
    else
      # Try to load parallel gem for faster processing
      begin
        require "parallel"
        @parallel_available = true
      rescue LoadError
        @parallel_available = false
      end

      # Only process source images - Jekyll will copy them to _site
      image_dir = File.join(site.source, "assets", "images")
      return unless Dir.exist?(image_dir)

      @cache_manifest_path = File.join(site.source, CACHE_FILENAME)
      @cache_manifest = load_cache_manifest
      @cache_mutex = Mutex.new if @parallel_available
      
      paths = Dir.glob(File.join(image_dir, "**", "*"), File::FNM_CASEFOLD).select do |path|
        IMAGE_EXTS.include?(File.extname(path).downcase) && !(File.basename(path) =~ /-\d+w\.webp$/i)
      end
      
      process_images(paths)
      save_cache_manifest
    end

    def self.process_images(paths)
      if @parallel_available && paths.length > 3
        # Use parallel processing for better performance
        Parallel.each(paths, in_processes: [Parallel.processor_count, 4].min) do |path|
          generate_responsive_images(path)
        end
      else
        # Fall back to sequential processing
        paths.each do |path|
          generate_responsive_images(path)
        end
      end
    end

    def self.generate_responsive_images(path)
      base_path = path.sub(/\.(jpe?g|png)\z/i, "")
      
      begin
        # Calculate fingerprint first
        fingerprint = Digest::SHA256.file(path).hexdigest
        
        # Load image to get width
        image = Vips::Image.new_from_file(path, access: :random)
        image = image.autorot if image.respond_to?(:autorot)
        original_width = image.width

        # Check cache
        cache_entry = @cache_manifest[path]
        if cache_entry && 
           cache_entry["sha256"] == fingerprint && 
           cache_entry["width"] == original_width &&
           outputs_present?(base_path, original_width)
          puts "[vips-webp] skipping #{File.basename(path)} (cached)"
          return
        end

        # Generate the base .webp file (for src attribute)
        base_webp_path = "#{base_path}.webp"
        save_options = { Q: QUALITY, effort: EFFORT, strip: true }
        
        image.webpsave(base_webp_path, **save_options)
        if File.exist?(base_webp_path) && File.size(base_webp_path) > 0
          puts "[vips-webp] #{File.basename(path)} -> #{File.basename(base_webp_path)}"
        else
          File.delete(base_webp_path) if File.exist?(base_webp_path)
          warn "[vips-webp] failed to generate #{File.basename(base_webp_path)} - file is empty"
          return
        end

        # Generate responsive sizes (for srcset attribute)
        SIZES.each do |width|
          next if width > original_width
          
          webp_path = "#{base_path}-#{width}w.webp"
          resized = image.thumbnail_image(width)
          resized.webpsave(webp_path, **save_options)
          
          # Verify the file was created successfully
          if File.exist?(webp_path) && File.size(webp_path) > 0
            puts "[vips-webp] #{File.basename(path)} -> #{File.basename(webp_path)}"
          else
            File.delete(webp_path) if File.exist?(webp_path)
            warn "[vips-webp] failed to generate #{File.basename(webp_path)} - file is empty"
          end
        end

        cleanup_stale_responsive_images(base_path, original_width)

        # Update cache (with mutex for parallel processing)
        update_cache = lambda do
          @cache_manifest[path] = {
            "sha256" => fingerprint,
            "width" => original_width,
            "sizes" => SIZES.select { |w| w <= original_width }
          }
        end

        if @parallel_available
          @cache_mutex.synchronize(&update_cache)
        else
          update_cache.call
        end
      rescue StandardError => e
        warn "[vips-webp] failed on #{path}: #{e.message}"
      end
    end

    def self.outputs_present?(base_path, original_width)
      base_webp_path = "#{base_path}.webp"
      return false unless File.exist?(base_webp_path) && File.size(base_webp_path) > 0

      SIZES.each do |width|
        next if width > original_width
        webp_path = "#{base_path}-#{width}w.webp"
        return false unless File.exist?(webp_path) && File.size(webp_path) > 0
      end

      true
    end

    def self.cleanup_stale_responsive_images(base_path, original_width)
      expected_sizes = SIZES.select { |w| w <= original_width }

      Dir.glob("#{base_path}-*w.webp").each do |path|
        match = /-(\d+)w\.webp\z/i.match(path)
        next unless match

        width = match[1].to_i
        next if expected_sizes.include?(width)

        File.delete(path)
        puts "[vips-webp] removed stale #{File.basename(path)}"
      end
    rescue StandardError => e
      warn "[vips-webp] failed to clean stale images for #{File.basename(base_path)}: #{e.message}"
    end

    def self.load_cache_manifest
      return {} unless @cache_manifest_path && File.exist?(@cache_manifest_path)

      JSON.parse(File.read(@cache_manifest_path))
    rescue StandardError => e
      warn "[vips-webp] failed to load cache manifest: #{e.message}"
      {}
    end

    def self.save_cache_manifest
      return unless @cache_manifest_path

      File.write(@cache_manifest_path, JSON.pretty_generate(@cache_manifest))
    rescue StandardError => e
      warn "[vips-webp] failed to write cache manifest: #{e.message}"
    end
  end
end

Jekyll::Hooks.register :site, :after_init do |site|
  ItalAI::VipsWebpGenerator.run(site)
end