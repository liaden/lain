# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What the Agent is built FROM: the provider the run talks to, the
      # compaction wiring hung off it, the instrumentation stack, and the
      # executor the board's gate closes over. Its own object because that is a
      # different question from what capabilities the run holds
      # ({ToolsetBuild}) or who the chat's collaborators are ({Wiring}) -- and
      # because wiring.rb's class comment says the next card must extract
      # before it adds, which this is.
      #
      # ⚠️ The {Switchboard} deliberately does NOT live here, and must not move
      # in. `Wiring#switchboard` is memoized at its ONE call site -- the agent
      # build -- and three things read that memo afterwards: `Wiring#approvals`,
      # the command surface, and the gate-policy thunk every subagent inherits.
      # So the board ARRIVES as an argument. A memo in here would leave all
      # three reading nil, which is the failure this extraction was shaped to
      # avoid.
      module AgentBuild
        # The capability policy every chat runs under -- see {#negotiate} for why
        # `:strict`, the only other member of {Capability::Policy::NAMES}, cannot
        # be the value here.
        DEGRADE = :degrade

        module_function

        # Gate and Live share ONE Toolset (the single-map invariant the plan
        # calls out): a second Toolset reference here could let the approval
        # gate and the executor disagree about what a tool name means. It is
        # the BOARD's, not the caller's, because a `/mode` flip changes the
        # live slot without rebuilding either.
        # `session:` is REQUIRED, not defaulted: a defaulted fresh Session would
        # silently mis-wire memory -- a caller passing a recorder-bearing toolset
        # but forgetting session: would get working memory tools with a permanently
        # blind manifest. Forgetting must be a loud ArgumentError, not a quiet
        # degrade (T1 panel, Schneeman).
        # `timeline:` seeds a resumed chat's Agent with the chain-verified
        # Timeline (nil = Agent's fresh default). `views:` is T1's: a streamed
        # tool's bytes are a view, not a record, so the executor writes them to
        # the TTY Channel AND the editor's -- never to the journal, which
        # already holds them in the turn's tool_result.
        #
        # The `tap` gives the turn middleware's thunk a live agent binding. It
        # is ASSIGNED, not merely returned: the thunk is built before the Agent
        # it reads, so left as a bare return expression the local stays nil
        # forever and the first turn raises NoMethodError on it.
        def build(board:, chronicle:, channel:, session:, backend:, timeline: nil, views: nil)
          gate = board.gate(inner: Lain::Effect::Handler::Live.new(toolset: board.toolset,
                                                                   channel: LiveViews.tool_output(channel, views)))

          agent = nil
          Lain::Agent.new(toolset: board.toolset, context: board.graft(backend.context), handler: gate, session:,
                          timeline:, request_override: Lain::Agent::RequestOverride.new, # T18: ResendBridge's slot
                          **backing(backend, channel, -> { agent.timeline },
                                    chronicle:, board:)).tap { |built| agent = built }
        end

        # A8: the provider, and the compaction wiring hung off it -- the per-turn
        # Context source, the eager-summary observer, and the journal tee that
        # feeds the source the cache-read counts the render seam cannot see
        # ({CompactionMount}). One method, because the mount must reference THE
        # ONE provider the run talks to: {Compaction::Cold} compares idle time
        # against that provider's own cache TTL, so a second construction would
        # be a second answer, and the pairing cannot be allowed to come apart.
        #
        # The mount is deliberately NOT memoized. Every piece of run state it
        # hands over -- the Source's accumulated warmth, the Eager's fired
        # summaries -- is memoized in {Backend}, which is loud about a differing
        # rebind ({Backend::Rebound}); the mount itself is a pure assembler over
        # those, so a memo here would only add a second place for a stale
        # collaborator to hide.
        # `board:` reaches {ToolGuard} for the read guard's ledger and queue --
        # the BOARD's, so this agent releases into the run's one region ledger
        # rather than a second nobody reads.
        #
        # It says nothing about subagents, and an earlier edition of this
        # comment claimed it did. {Tools::Subagent} builds its child through a
        # bare `Agent.new` with no `instrumentation:`, so a child's tool
        # middleware is EMPTY: neither this guard nor
        # {Middleware::RefuseSecretWrites} runs for a subagent's tools.
        #
        # Read that as path-kept, content-lost, not as ungated. The child keeps
        # the PATH boundary -- `child_handler` composes its own gate, so a
        # child's `read_file(".env")` still reaches the escalation ladder. What
        # it loses is the CONTENT boundary, which is middleware: an
        # ordinary-classified file's sensitive regions reach a subagent
        # unmasked, and those bytes flow back into the parent's Timeline.
        #
        # The gap predates this card -- the write guard has always had it -- and
        # closing it is a wiring change in `subagent.rb`, not a line here. It is
        # recorded rather than papered over, because a comment claiming coverage
        # that does not exist is worse than no comment.
        def backing(backend, channel, timeline, chronicle:, board:)
          provider = spooled_provider(backend, chronicle:, channel:)
          journal_degradation(backend.context, provider, journal: chronicle.record_journal)
          mount = CompactionMount.new(backend:, provider:, chronicle:, channel:)
          # T10: the run's ONE window book, the same instance the compaction
          # source above and the StatusFeed below the launcher divide by. It is
          # what {Agent#occupancy} answers with no keyword, which is the `ctx`
          # segment of the REPL prompt -- so the prompt and `.lain/state.json`
          # cannot report two occupancies for one turn.
          { provider:, context_window: backend.context_window,
            instrumentation: mount.instrumentation.with(tool_middleware: ToolGuard.stack(chronicle, board),
                                                        turn_middleware: chronicle.turn_middleware(timeline)) }
        end

        # T13: WRITE what this run's Context asks for that its Provider cannot
        # give -- one `capability_degraded` record per missing capability, once
        # per session. {Capability::Policy} shipped with a record type, an
        # emitter and a reader and NO caller: twelve POC journals carried zero
        # such records while {Context::CacheBreakpoints} required
        # `:prompt_caching` from an ollama provider that does not declare it, and
        # {Compare} refuses to compare runs whose degraded sets differ -- so the
        # gap made incomparable runs look comparable.
        #
        # Named for the WRITE, not for the negotiation, because the write is the
        # whole point: {Capability::Policy#resolve} does hand back a
        # {Capability::DegradedSet}, and it is dropped here deliberately. Nothing
        # in a live chat consumes a degraded set -- {Compare} and
        # {Bench::Session::Loader} both rebuild it from the journal, which is the
        # durable answer -- so returning it up through {#backing} would be a
        # contract with no reader, and {#backing} answers "what the Agent is
        # built FROM", which a journaled side effect is not.
        #
        # `:degrade` is the wired policy and the ONLY one that may be wired here.
        # `Policy::Strict#handle_missing` calls {Provider#require!}, which raises
        # {Provider::Unsupported} -- so `:strict` would kill every ollama chat at
        # turn one. Choosing between them is a flag nobody has asked for yet, and
        # a constant is the honest shape until someone does.
        #
        # It lives in THIS module rather than in {Wiring} because the two things
        # it needs are here: the ONE provider the run talks to, and the Context
        # it renders through. Wiring sits at its Metrics/ClassLength budget
        # exactly (110/110, measured), and its class comment's rule is extract
        # rather than grow -- so a call site up there would have had to buy its
        # line from an unrelated refactor. Note for whoever hits that budget
        # next: a NESTED class or module costs the enclosing class only ONE line
        # toward the cop, which is what makes {Wiring::Askers}' shape the
        # in-file escape hatch.
        #
        # Called from {#backing} and not from {#build} so it reads the provider
        # already constructed there; asking {Backend#provider} again would build a
        # second one purely to interrogate a class-level declaration.
        #
        # Session-scoped, not per-turn: {#backing} runs once per chat, so a
        # journal carries one record per missing capability however long the
        # session runs. {Bench::Session::Loader#degraded} folds these to a set,
        # so a per-turn emission would flood the record with nothing downstream
        # ever complaining.
        #
        # @param context [#requires] the Context this run renders through
        # @param provider [#supports?] the ONE provider this run talks to
        # @param journal [#<<] where each record lands -- the run's own, and a
        #   Journal rather than the Chronicle that resolves it, so this depends
        #   on the one message it sends (`Policy.for`'s own `journal:` keyword)
        #   and a spec can hand it a StringIO-backed {Lain::Journal} without
        #   constructing a Chronicle
        def journal_degradation(context, provider, journal:)
          Lain::Capability::Policy.for(DEGRADE, journal:).resolve(context, provider)
        end

        # Both provider construction sites tee their round trips into the
        # chronicle's response spool (see Lain::CLI::Chronicle#spool) -- a real
        # ResponseWal when journaling, the Null spool under --no-journal. `channel:`
        # is the live TTY Channel for the MAIN agent (CE-5 stream_started reaches
        # the frontend); a subagent leaves the Null default -- its stream is not
        # rendered, only the spool tee matters there.
        def spooled_provider(backend, chronicle:, channel: Lain::Channel::Null.instance)
          backend.provider(spool: chronicle.spool, channel:)
        end
      end
    end
  end
end
