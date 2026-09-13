# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What a chat's RUN STATE is, fresh or resumed: the memory recorder and
      # the journaled Session.
      #
      # THE INVARIANT: one Recorder backs the memory_write tool for the whole
      # session -- the single mutable holder of the live {Lain::Memory::Index},
      # so each write supersedes the last. A resumed chat inherits the
      # chain-wide recorder instead, so its manifest sees every memory the
      # resumed sessions wrote. BOTH halves must then be wired to the
      # chronicle: reads and todos journal through the Session's own journal,
      # and each turn_usage pairs with the memory root in force, so wiring
      # one and not the other is a run whose usage records name a memory root
      # its reads never wrote. That is why the pair is built in one place and
      # handed back together. Identity under --no-journal.
      #
      # `worker_env:` is asked for rather than computed: which directory a FRESH
      # chat's Session runs in is the {Lain::Project}'s question, answered in
      # {Wiring#chat_env}. Only actor-mode subagents lease an environment; the
      # main chat deliberately does not, because the user's own edits belong in
      # the user's own tree.
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
