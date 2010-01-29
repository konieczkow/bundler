require "rubygems/remote_fetcher"
require "rubygems/format"
require "digest/sha1"

module Bundler
  module Source
    class Rubygems
      attr_reader :uri, :options

      def initialize(options = {})
        @options = options
        @uri = options[:uri]
        @uri = URI.parse(@uri) unless @uri.is_a?(URI)
        raise ArgumentError, "The source must be an absolute URI" unless @uri.absolute?
      end

      def specs
        @specs ||= fetch_specs
      end

      def install(spec)
        Bundler.ui.info "* #{spec.name} (#{spec.version})"
        if Index.from_installed_gems[spec].any?
          Bundler.ui.info "  * already installed... skipping"
          return
        end

        destination = Gem.dir

        Bundler.ui.info "  * Downloading..."
        gem_path  = Gem::RemoteFetcher.fetcher.download(spec, uri, destination)
        Bundler.ui.info "  * Installing..."
        installer = Gem::Installer.new gem_path,
          :install_dir => Gem.dir,
          :ignore_dependencies => true

        installer.install
      end

    private

      def fetch_specs
        index = Index.new
        Bundler.ui.info "Source: Fetching remote index for `#{uri}`... "
        (main_specs + prerelease_specs).each do |name, version, platform|
          spec = RemoteSpecification.new(name, version, platform, @uri)
          spec.source = self
          index << spec
        end
        Bundler.ui.info "done."
        index
      end

      def main_specs
        Marshal.load(Gem::RemoteFetcher.fetcher.fetch_path("#{uri}/specs.4.8.gz"))
      rescue Gem::RemoteFetcher::FetchError => e
        raise ArgumentError, "#{to_s} is not a valid source: #{e.message}"
      end

      def prerelease_specs
        Marshal.load(Gem::RemoteFetcher.fetcher.fetch_path("#{uri}/prerelease_specs.4.8.gz"))
      rescue Gem::RemoteFetcher::FetchError
        Bundler.logger.warn "Source '#{uri}' does not support prerelease gems"
        []
      end
    end

    class GemCache
      def initialize(options)
        @path = options[:path]
      end

      def specs
        @specs ||= begin
          index = Index.new

          Dir["#{@path}/*.gem"].each do |gemfile|
            spec = Gem::Format.from_file_by_path(gemfile).spec
            spec.source = self
            index << spec
          end

          index
        end
      end

      def install(spec)
        destination = Gem.dir

        installer = Gem::Installer.new "#{@path}/#{spec.full_name}.gem",
          :install_dir => Gem.dir,
          :ignore_dependencies => true

        installer.install
      end
    end

    class Path
      attr_reader :path, :options

      def initialize(options)
        @options = options
        @glob = options[:glob] || "{,*/}*.gemspec"
        @path = options[:path]
      end

      def specs
        @specs ||= begin
          index = Index.new

          Dir["#{path}/#{@glob}"].each do |file|
            file = Pathname.new(file)
            if spec = eval(File.read(file))
              spec = Specification.from_gemspec(spec)
              spec.loaded_from = file
              spec.source      = self
              index << spec
            end
          end
          index
        end
      end

      alias local_specs specs
    end

    class Git < Path
      attr_reader :uri, :ref

      def initialize(options)
        @options = options
        @glob = options[:glob] || "{,*/}*.gemspec"
        @uri  = options[:uri]
        @ref  = options[:ref] || options[:branch] || 'master'
      end

      def options
        @options.merge(:ref => revision)
      end

      def path
        Bundler.install_path.join("#{base_name}-#{uri_hash}-#{ref}")
      end

      def specs
        @specs ||= begin
          index = Index.new
          # Start by making sure the git cache is up to date
          cache
          # Find all gemspecs in the repo
          in_cache do
            out   = %x(git ls-tree -r #{revision}).strip
            lines = out.split("\n").select { |l| l =~ /\.gemspec$/ }
            # Loop over the lines and extract the relative path and the
            # git hash
            lines.each do |line|
              next unless line =~ %r{^(\d+) (blob|tree) ([a-zf0-9]+)\t(.*)$}
              hash, file = $3, $4
              # Read the gemspec
              if spec = eval(%x(git cat-file blob #{$3}))
                spec = Specification.from_gemspec(spec)
                spec.relative_loaded_from = file
                spec.source = self
                index << spec
              end
            end
          end
          index
        end
      end

      def install(spec)
        @installed ||= begin
          FileUtils.mkdir_p(path)
          Dir.chdir(path) do
            unless File.exist?(".git")
              %x(git clone --recursive --no-checkout #{cache_path} #{path})
            end
            %x(git fetch --quiet)
            %x(git reset --hard #{revision})
            %x(git submodule init)
            %x(git submodule update)
          end
          true
        end
      end

    private

      def base_name
        File.basename(uri, ".git")
      end

      def uri_hash
        Digest::SHA1.hexdigest(URI.parse(uri).normalize.to_s.sub(%r{/$}, ''))
      end

      def cache_path
        @cache_path ||= Bundler.cache.join("git", "#{base_name}-#{uri_hash}")
      end

      def cache
        if cache_path.exist?
          Bundler.ui.info "Source: Updating `#{uri}`... "
          in_cache { `git fetch --quiet #{uri} master:master` }
        else
          Bundler.ui.info "Source: Cloning `#{uri}`... "
          FileUtils.mkdir_p(cache_path.dirname)
          `git clone #{uri} #{cache_path} --bare --no-hardlinks`
        end
        Bundler.ui.info "Done."
      end

      def revision
        @revision ||= in_cache { `git rev-parse #{ref}`.strip }
      end

      def in_cache(&blk)
        Dir.chdir(cache_path, &blk)
      end
    end
  end
end