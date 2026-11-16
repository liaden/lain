# frozen_string_literal: true

module Lain
  module Boot
    # What every executable does before its own Thor class exists: pick the bundle, replay the cached load path,
    # start Bootsnap and load the library. The caller keeps its own exit and stderr, so a refusal raised
    # while `lain` loads surfaces here as the exception it is.
    #
    # Only from a source checkout does it touch Bundler. `bundler/setup` resolves the Gemfile it finds by walking
    # UP FROM THE CWD, so an unconditional require would make the INSTALLED gem, run inside a project with a
    # Gemfile of its own, resolve THAT bundle and die before `lain` gets a say. A checkout has a Gemfile beside
    # `exe/` and the packaged gem ships none; the cwd is deliberately not consulted. BUNDLE_GEMFILE is pinned
    # as well, with `||=` so an explicit one still wins, because the guard alone leaves a checkout invoked from
    # another repository resolving that repository's Gemfile.
    module Launch
      class << self
        # @param checkout [String] the directory holding `Gemfile` in a source checkout, absent in the gem
        # @return [void]
        def call(checkout: File.expand_path("../../..", __dir__))
          xdg = ENV.fetch("XDG_CACHE_HOME", "")
          # Paths is not loaded yet, so its XDG rule is restated here.
          cache_home = File.expand_path(xdg.empty? ? "~/.cache" : xdg)
          load_path(File.join(checkout, "Gemfile"), cache_home)
          require "thor"
          bootsnap(cache_home)
          require "lain"
        end

        private

        def load_path(gemfile, cache_home)
          return unless File.exist?(gemfile)

          ENV["BUNDLE_GEMFILE"] ||= gemfile
          require File.expand_path("frozen_load_path", __dir__)
          cache = ENV.fetch("LAIN_LOAD_PATH_CACHE") { File.join(cache_home, "lain", "load_path") }
          FrozenLoadPath.setup(gemfile: ENV.fetch("BUNDLE_GEMFILE"), cache_dir: cache)
        end

        # A process that already ran Bootsnap.setup (a spec worker, a child given -rbootsnap/setup) keeps its own.
        # A cache that cannot be had must never stop lain.
        def bootsnap(cache_home)
          return if defined?(::Bootsnap) || ENV["LAIN_BOOTSNAP"] == "0"

          require "bootsnap"
          ::Bootsnap.setup(cache_dir: ENV.fetch("LAIN_BOOTSNAP_CACHE") { File.join(cache_home, "lain", "bootsnap") })
        rescue LoadError, SystemCallError
          nil
        end
      end
    end
  end
end
