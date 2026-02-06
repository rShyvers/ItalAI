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
    MANIFEST_VERSION = 1

    def self.run(site)
      require "vips"
      require "digest"
      require "fileutils"
      require "json"
      require "pathname"
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

      manifest = normalize_manifest(load_manifest(site))
      @manifest_mutex = Mutex.new
      
      paths = Dir.glob(File.join(image_dir, "**", "*"), File::FNM_CASEFOLD).select do |path|
        IMAGE_EXTS.include?(File.extname(path).downcase) && !(File.basename(path) =~ /-\d+w\.webp$/i)
      end
      
      process_images(paths, site, manifest)
      save_manifest(site, manifest)
    end

    def self.process_images(paths, site, manifest)
      if @parallel_available && paths.length > 3
        # Use parallel processing for better performance
        Parallel.each(paths, in_threads: [Parallel.processor_count, 4].min) do |path|
          generate_responsive_images(path, site, manifest)
        end
      else
        # Fall back to sequential processing
        paths.each do |path|
          generate_responsive_images(path, site, manifest)
        end
      end
    end

    def self.generate_responsive_images(path, site, manifest)
      base_path = path.sub(/\.(jpe?g|png)\z/i, "")
      relative_path = Pathname.new(path).relative_path_from(Pathname.new(site.source)).to_s
      digest = Digest::SHA256.file(path).hexdigest
      
      begin
        cached = manifest["files"][relative_path]
        original_width = cached && cached["width"]

        if cached && cached["digest"] == digest
          original_width ||= begin
            image = Vips::Image.new_from_file(path, access: :random)
            image = image.autorot if image.respond_to?(:autorot)
            image.width
          end

          if outputs_present?(base_path, original_width)
            return
          end
        end

        image = Vips::Image.new_from_file(path, access: :random)
        image = image.autorot if image.respond_to?(:autorot)
        original_width = image.width

        # First, generate the base .webp file (for src attribute)
        base_webp_path = "#{base_path}.webp"
        unless File.exist?(base_webp_path) && File.mtime(base_webp_path) >= File.mtime(path) && File.size(base_webp_path) > 0
          save_options = { Q: QUALITY, effort: EFFORT, strip: true }
          
          image.webpsave(base_webp_path, **save_options)
          if File.exist?(base_webp_path) && File.size(base_webp_path) > 0
            puts "[vips-webp] #{File.basename(path)} -> #{File.basename(base_webp_path)}"
          else
            File.delete(base_webp_path) if File.exist?(base_webp_path)
            warn "[vips-webp] failed to generate #{File.basename(base_webp_path)} - file is empty"
          end
        end

        # Then generate responsive sizes (for srcset attribute)
        SIZES.each do |width|
          next if width > original_width
          
          webp_path = "#{base_path}-#{width}w.webp"
          
          # Skip if already exists and is newer than source
          next if File.exist?(webp_path) && File.mtime(webp_path) >= File.mtime(path) && File.size(webp_path) > 0
          
          resized = image.thumbnail_image(width)
          
          save_options = { Q: QUALITY, effort: EFFORT, strip: true }
          
          resized.webpsave(webp_path, **save_options)
          
          # Verify the file was created successfully
          if File.exist?(webp_path) && File.size(webp_path) > 0
            puts "[vips-webp] #{File.basename(path)} -> #{File.basename(webp_path)}"
          else
            File.delete(webp_path) if File.exist?(webp_path)
            warn "[vips-webp] failed to generate #{File.basename(webp_path)} - file is empty"
          end
        end

        update_manifest(manifest, relative_path, digest, original_width)
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

    def self.update_manifest(manifest, relative_path, digest, original_width)
      @manifest_mutex.synchronize do
        manifest["files"][relative_path] = {
          "digest" => digest,
          "width" => original_width
        }
      end
    end

    def self.normalize_manifest(manifest)
      options = {
        "sizes" => SIZES,
        "quality" => QUALITY,
        "effort" => EFFORT
      }

      return default_manifest if manifest["version"] != MANIFEST_VERSION
      return default_manifest if manifest["options"] != options

      manifest["files"] ||= {}
      manifest
    end

    def self.default_manifest
      {
        "version" => MANIFEST_VERSION,
        "options" => {
          "sizes" => SIZES,
          "quality" => QUALITY,
          "effort" => EFFORT
        },
        "files" => {}
      }
    end

    def self.cache_path(site)
      cache_dir = site.respond_to?(:cache_dir) ? site.cache_dir : File.join(site.source, ".jekyll-cache")
      FileUtils.mkdir_p(cache_dir)
      File.join(cache_dir, "vips-webp-manifest.json")
    end

    def self.load_manifest(site)
      path = cache_path(site)
      return default_manifest unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      default_manifest
    end

    def self.save_manifest(site, manifest)
      path = cache_path(site)
      temp = "#{path}.tmp"
      File.write(temp, JSON.pretty_generate(manifest))
      FileUtils.mv(temp, path)
    end
  end
end

Jekyll::Hooks.register :site, :after_init do |site|
  ItalAI::VipsWebpGenerator.run(site)
end
