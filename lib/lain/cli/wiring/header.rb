# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      Header = Data.define(:project, :paths)

      # The session header's run fields: what the resolved backend records, and
      # the provenance of a launch in this project.
      class Header
        # @param backend [Backend] the backend the run resolved
        # The context is built once here, because each `backend.context` call
        # renders the prompt slots again.
        #
        # @param toolset [Toolset] the finished toolset the header pins
        # @return [Hash{Symbol=>Object}] keywords for {Chronicle#start}
        def fields(backend, toolset)
          context = backend.context
          { context:, profile: backend.run_profile, compaction: backend.compaction_header,
            middleware: backend.middleware,
            provenance: SessionRecord::Provenance.launched(project:, toolset:, effort: context.effort, paths:,
                                                           weights: backend.provider.model_identity(backend.model)) }
        end
      end
    end
  end
end
