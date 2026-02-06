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
      # Only process source images - Jekyll will copy them to _site
      image_dir = File.join(site.source, "assets", "images")
      return unless Dir.exist?(image_dir)

      @cache_base = site.source
      @cache_manifest_path = File.join(site.source, CACHE_FILENAME)
      @cache_manifest = load_cache_manifest
      
      puts "[vips-webp] Cache manifest path: #{@cache_manifest_path}"
      puts "[vips-webp] Cache entries loaded: #{@cache_manifest.size}"
      puts "[vips-webp] Cache manifest contents:\n#{JSON.pretty_generate(@cache_manifest)}"
      
      paths = Dir.glob(File.join(image_dir, "**", "*"), File::FNM_CASEFOLD).select do |path|
        IMAGE_EXTS.include?(File.extname(path).downcase) && !(File.basename(path) =~ /-\d+w\.webp$/i)
      end
      
      puts "[vips-webp] Found #{paths.size} source images to process"
      
      paths.each do |path|
        generate_responsive_images(path)
      end
      
      save_cache_manifest
      puts "[vips-webp] Cache manifest saved with #{@cache_manifest.size} entries"
    end

    def self.generate_responsive_images(path)
      base_path = path.sub(/\.(jpe?g|png)\z/i, "")
      
      begin
        # Calculate fingerprint first
        fingerprint = Digest::SHA256.file(path).hexdigest
        
        # Check cache before loading image (more efficient)
        cache_key = cache_key_for(path)
        cache_entry = @cache_manifest[cache_key]
        if !cache_entry && @cache_manifest[path]
          cache_entry = @cache_manifest[path]
          @cache_manifest.delete(path)
          @cache_manifest[cache_key] = cache_entry
        end
        
        if cache_entry
          puts "[vips-webp] DEBUG: Cache entry found for #{File.basename(path)}"
          puts "[vips-webp] DEBUG: Cached SHA256: #{cache_entry['sha256'][0..10]}..."
          puts "[vips-webp] DEBUG: Current SHA256: #{fingerprint[0..10]}..."
          puts "[vips-webp] DEBUG: Match: #{cache_entry['sha256'] == fingerprint}"
          
          if cache_entry["sha256"] == fingerprint
            # Verify outputs still exist
            if outputs_present?(base_path, cache_entry["width"])
              puts "[vips-webp] ✓ #{File.basename(path)} (cached)"
              return
            else
              puts "[vips-webp] ⚠ #{File.basename(path)} (cache stale - files missing)"
            end
          else
            puts "[vips-webp] ⚠ #{File.basename(path)} (cache stale - file changed)"
          end
        else
          puts "[vips-webp] No cache entry for #{File.basename(path)}"
        end

        # Load image
        image = Vips::Image.new_from_file(path, access: :random)
        image = image.autorot if image.respond_to?(:autorot)
        original_width = image.width

        # Clean up any stale files BEFORE generating new ones
        cleanup_stale_responsive_images(base_path, original_width)

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
        generated_sizes = []
        SIZES.each do |width|
          next if width > original_width
          
          webp_path = "#{base_path}-#{width}w.webp"
          resized = image.thumbnail_image(width)
          resized.webpsave(webp_path, **save_options)
          
          # Verify the file was created successfully
          if File.exist?(webp_path) && File.size(webp_path) > 0
            puts "[vips-webp] #{File.basename(path)} -> #{File.basename(webp_path)}"
            generated_sizes << width
          else
            File.delete(webp_path) if File.exist?(webp_path)
            warn "[vips-webp] failed to generate #{File.basename(webp_path)} - file is empty"
          end
        end

        # Update cache
        @cache_manifest[cache_key] = {
          "sha256" => fingerprint,
          "width" => original_width,
          "sizes" => generated_sizes
        }
      rescue StandardError => e
        warn "[vips-webp] failed on #{path}: #{e.message}"
      end
    end

    def self.cache_key_for(path)
      return path unless @cache_base && path.start_with?(@cache_base)

      path.sub(@cache_base + File::SEPARATOR, "")
    end

    def self.outputs_present?(base_path, original_width)
      base_webp_path = "#{base_path}.webp"
      return false unless File.exist?(base_webp_path) && File.size(base_webp_path) > 0

      expected_sizes = SIZES.select { |w| w <= original_width }
      expected_sizes.each do |width|
        webp_path = "#{base_path}-#{width}w.webp"
        return false unless File.exist?(webp_path) && File.size(webp_path) > 0
      end

      true
    end

    def self.cleanup_stale_responsive_images(base_path, original_width)
      expected_sizes = SIZES.select { |w| w <= original_width }
      
      # Get the directory and base filename
      dir = File.dirname(base_path)
      base_name = File.basename(base_path)

      # Only look for files that match THIS specific base name
      pattern = File.join(dir, "#{base_name}-*w.webp")
      
      Dir.glob(pattern).each do |webp_path|
        match = /-(\d+)w\.webp\z/i.match(webp_path)
        next unless match

        width = match[1].to_i
        next if expected_sizes.include?(width)

        File.delete(webp_path)
        puts "[vips-webp] removed stale #{File.basename(webp_path)}"
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