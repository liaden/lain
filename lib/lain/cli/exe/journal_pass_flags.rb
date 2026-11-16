# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # What both JOURNAL PASSES declare: the model flag band, whose profile flags
      # default to what the session under review recorded, and a `--dry-run` that
      # says what THIS pass would do instead of doing it.
      module JournalPassFlags
        # @param thor [Class] the Thor class the flags accumulate onto
        # @param dry_run [String] what THIS pass would do instead of doing it
        def self.declare(thor, dry_run:)
          thor.method_option :dry_run, type: :boolean, default: false, desc: dry_run
          ModelFlags.declare(thor, recorded: ModelFlags::REVIEWED)
        end
      end
    end
  end
end
