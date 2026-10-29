# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/release PATH`: forgets the run's decline and lapse for a file, so the
      # model's next read of it parks on the release prompt again. A related
      # directory is refused by name, because its regions are masked without
      # ever asking and there is nothing there to forget.
      class Release
        USAGE = "/release PATH -- forget a declined or lapsed release so the next read asks again"
        RELATED = "related directories are masked and never released"

        # @param cwd [String] absolute; where a relative PATH resolves
        # @param ledger [Sensitivity::Ledger] the run's one ledger
        # @param sensitivity [#related?] the run's own path boundary
        def initialize(cwd:, ledger:, sensitivity:)
          @cwd = cwd
          @ledger = ledger
          @sensitivity = sensitivity
          freeze
        end

        def name = "release"

        def usage = USAGE

        def call(args, _env)
          written = args.to_s.strip
          return USAGE if written.empty?

          path = File.expand_path(written, @cwd)
          return "#{written}: #{RELATED}" if @sensitivity.related?(path)

          forgotten(written, @ledger.forget(path))
        end

        private

        def forgotten(written, count)
          return "nothing was declined for #{written}" if count.zero?

          "#{written}: forgot #{count} declined or lapsed region(s), so the next read asks again"
        end
      end
    end
  end
end
