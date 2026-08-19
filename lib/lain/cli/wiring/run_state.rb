# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What a chat's RUN STATE is, fresh or resumed: the memory recorder and
      # the journaled Session. A different question from who the chat's
      # collaborators are ({Wiring}), from what capabilities it holds
      # ({ToolsetBuild}), and from what the Agent is built out of
      # ({AgentBuild}) -- and it is the question with an invariant of its own,
      # which is why it is worth a name rather than four statements in an
      # assembler.
      #
      # THE INVARIANT: one Recorder backs the memory_write tool for the whole
      # session -- the single mutable holder of the live {Lain::Memory::Index},
      # so each write supersedes the last (its prior root still resolves the old
      # item). A resumed chat inherits the chain-wide recorder instead, so its
      # manifest sees every memory the resumed sessions wrote. Both halves are
      # then decorated by the chronicle, and BOTH must be: reads and todos
      # journal through {Lain::Session::Journaled}, and each turn_usage pairs
      # with the memory root in force. Decorating one and not the other is a run
      # whose usage records name a memory root its reads never wrote -- which is
      # why the pair is built in one place and handed back together. Identity
      # under --no-journal, so the ordinary run is byte-identical.
      #
      # `worker_env:` is asked for rather than computed: which directory a FRESH
      # chat's Session runs in is the {Lain::Project}'s question, and
      # {Wiring#chat_env} is where it is answered. Only actor-mode subagents
      # lease an environment; the main chat deliberately does not, because the
      # user's own edits belong in the user's own tree.
      module RunState
        module_function

        # @param resumed [#recorder, #session, nil] the resumed chat, nil when fresh
        # @param chronicle [Lain::Chronicle] the run's session file and its journal
        # @param worker_env [Lain::WorkerEnv] the host-side environment a FRESH session runs in
        # @return [Array(Lain::Memory::Recorder, Lain::Session)] the recorder, and the journaled session
        def for(resumed:, chronicle:, worker_env:)
          recorder = resumed ? resumed.recorder : Lain::Memory::Recorder.new
          session = resumed ? resumed.session : Lain::Session.new(memory: recorder, worker_env:)
          chronicle.wrap_memory(recorder)
          [recorder, chronicle.wrap_session(session)]
        end
      end
    end
  end
end
