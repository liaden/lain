# frozen_string_literal: true

module Lain
  module Bench
    # The header sections of a committed fixture session. Fixed values, so the
    # bytes name no machine and a rerun reproduces them: the real harness and
    # policy digests would change with every checkout.
    module FixtureSections
      ROOT = "/fixture/project"
      HOME = "/fixture/user"

      module_function

      # @param toolset [Toolset] the tools the fixture session offers
      # @return [SessionRecord::Sections]
      def for(toolset)
        provenance = SessionRecord::Provenance.current(toolset:, root: ROOT, cwd: ROOT, home: HOME, effort: nil,
                                                       harness: "fixture", policy: "fixture")
        # Root-qualified: {Bench::CLI} shadows the top-level one inside `Bench`.
        profile = ::Lain::CLI::RunProfile.from_options({ provider: "anthropic" }).to_header
        SessionRecord::Sections.new(profile:, arms: ::Lain::CLI::Arms::DEFAULT.to_header,
                                    provenance: provenance.to_header)
      end
    end
  end
end
