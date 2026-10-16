# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The memory view and journaled session a chat runs on, and the project
      # store behind both.
      class RunState
        # @param root [String] the PROJECT's root, which keys the memory store
        # @param paths [Paths]
        # @param notice [#call] where the store reports a wait on another chat
        # @param chat_env [Lain::WorkerEnv] the environment a fresh session runs in
        # @param chronicle [#wrap_memory, #wrap_session]
        # @return [RunState]
        def initialize(root:, paths:, notice:, chat_env:, chronicle:)
          @root = root
          @paths = paths
          @notice = notice
          @chat_env = chat_env
          @chronicle = chronicle
        end

        # What a chat's RUN STATE is, fresh or resumed: the memory view and the
        # journaled Session.
        #
        # THE INVARIANT: one Recorder backs the memory_write tool for the whole
        # session -- the single mutable holder of the live {Lain::Memory::Index},
        # so each write supersedes the last. It is this project's VIEW of the one
        # project memory store: a fresh chat opens on the store head, so it sees
        # what earlier chats and `lain consolidate` wrote, while a resumed chat
        # re-opens the view its own record carried and deliberately does not pick
        # up what other chats have written since. BOTH halves must then be
        # decorated by the chronicle: reads and todos journal through
        # {Lain::Session::Journaled}, and each turn_usage pairs with the memory
        # root in force, so decorating one and not the other is a run whose usage
        # records name a memory root its reads never wrote. That is why the pair
        # is built in one place and handed back together. Identity under
        # --no-journal.
        #
        # A fresh Session runs at the {Lain::Project}'s cwd, answered by
        # the injected chat environment; only actor-mode subagents lease an environment, because the
        # user's own edits belong in the user's own tree.
        #
        # PUBLIC: specs drive it to get a real recorder and session to build an
        # assembly against.
        #
        # @param resumed [#recorder, #session, nil] the resumed chat, nil when fresh
        # @return [Array(Lain::Memory::Recorder, Lain::Session)] the view, and the journaled session
        def run_state(resumed)
          recorder = memory_view(resumed)
          chronicle.wrap_memory(recorder)
          [recorder, chronicle.wrap_session(session_over(recorder, resumed))]
        end

        # What a resumed chat is told about the memory it is NOT picking up: its
        # view is the one it recorded, and entries other chats have added since
        # are waiting for a fresh chat rather than lost. A fresh chat is told
        # nothing, because its view already holds them.
        #
        # PUBLIC beside {#run_state}, and for its reason: the pair is what a run's
        # memory state IS, and a spec that can build the one can ask the other.
        #
        # An Array rather than a String-or-nil, so the caller says `.each` and
        # never asks whether there was something to say.
        #
        # @param recorder [Lain::Memory::Recorder] the run's view
        # @param resumed [#recorder, nil] nil when fresh
        # @return [Array<String>]
        def memory_notices(recorder, resumed)
          newer = resumed.nil? ? 0 : project_memory.newer_than(recorder.loaded)
          return [] if newer.zero?

          ["project memory holds #{newer} entr#{newer == 1 ? "y" : "ies"} newer than this session's view; " \
           "a fresh chat in this project starts from all of them"]
        end

        # The one project memory store, keyed to the PROJECT's root rather than to
        # `Dir.pwd`, so a chat started in a subdirectory shares the memory of the
        # project it belongs to. Memoized: one store per run, so the view and the
        # drift count read one file.
        def project_memory
          @project_memory ||= Lain::Memory::ProjectStore.new(project_dir: Lain::ProjectDir.new(root:, paths: @paths),
                                                             notice: @notice || SILENT)
        end

        private

        attr_reader :root, :chat_env, :chronicle

        # A fresh chat opens on the store head; a resumed one re-opens the view
        # its own record carried, so nothing another chat wrote in between joins
        # this session's manifest or moves a root it already recorded.
        def memory_view(resumed) = resumed ? project_memory.resumed(resumed.recorder) : project_memory.view

        # A resumed Session already exists -- {Lain::SessionRecord::Replay} built
        # it over the view it folded -- so it is pointed at the re-opened view
        # rather than rebuilt, which would lose the read-set, pin-set and todo
        # list replay just restored.
        def session_over(recorder, resumed)
          return Lain::Session.new(memory: recorder, worker_env: chat_env, root:) if resumed.nil?

          resumed.session.watch_memory(recorder)
        end
      end
    end
  end
end
