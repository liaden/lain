# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What {Repl#run} builds its editor from, as the one set it is: the Store and Session its buffers
      # read, the epic lain://status draws, where a written epic document is read back, and the scan
      # lain://tree draws fork lines from. {ReviewSeams}' shape, for the same reason: the keywords travel
      # together.
      class EditorSeams
        # @param nvim [Hash, nil] the editor's own options
        # @param agent [Agent] whose Store the buffers read
        # @param session [Session]
        # @param epic [#lines] what lain://status draws
        # @param mount [EpicMount, EpicMount::NoEpic] whose homes a written document is read back through
        # @param feed [StatusFeed] the HUD's feed, given the Store at the first line the run has one
        # @param forks [#call] the scan of the project's session files
        def initialize(nvim:, agent:, session:, epic:, mount:, feed:, forks:)
          @nvim = nvim
          @agent = agent
          @session = session
          @epic = epic
          @mount = mount
          @feed = feed
          @forks = forks
        end

        # Binds the feed as it answers, because {ChatLaunch} builds that feed before Wiring exists and until
        # it holds a Store its inbox_count retires nothing and only climbs.
        #
        # @return [Hash{Symbol=>Object}] keywords for {Repl#run}
        def to_h
          { nvim: @nvim, store: bound_store, session: @session, epic: @epic, epic_docs: @mount.homes, forks: @forks }
        end

        private

        def bound_store = @agent.timeline.store.tap { |store| @feed.bind_store(store) }
      end
    end
  end
end
