# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      Header = Data.define(:project, :paths, :epic)

      # The session header's run fields: what the resolved backend records, and
      # the provenance of a launch in this project.
      class Header
        # @param backend [Backend] the backend the run resolved
        # The context is built once here, because each `backend.context` call
        # renders the prompt slots again.
        #
        # @param toolset [Toolset] the finished toolset the header pins
        # @param arms [Arms] the run's arms, which the backend does not hold
        # @return [Hash{Symbol=>Object}] keywords for {Chronicle#start}
        def fields(backend, toolset, arms)
          context = backend.context
          provenance = SessionRecord::Provenance.launched(project:, toolset:, effort: context.effort, paths:,
                                                          weights: backend.provider.model_identity(backend.model))
          sections = SessionRecord::Sections.of(profile: backend.run_profile, arms:, provenance:,
                                                compaction: backend.compaction_header,
                                                middleware: backend.middleware,
                                                summarizer: { "provider" => backend.summarizer_name,
                                                              "model" => backend.summarizer_model })
          { context:, sections:, workspace: epic.workspace }
        end
      end
    end
  end
end
