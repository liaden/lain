# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What the Agent is built FROM: the provider the run talks to, the
      # compaction wiring hung off it, the instrumentation stack, and the
      # executor the board's gate closes over.
      #
      # The {Switchboard} deliberately does NOT live here, and must not move
      # in. `Wiring#switchboard` is memoized at its ONE call site -- the agent
      # build -- and three things read that memo afterwards: `Wiring#approvals`,
      # the command surface, and the gate-policy thunk every subagent inherits.
      # So the board ARRIVES as an argument; a memo in here would leave all
      # three reading nil.
      module AgentBuild
        # The capability policy every chat runs under -- see
        # {#journal_degradation} for why `:strict`, the only other member of
        # {Capability::Policy::NAMES}, cannot be the value here.
        DEGRADE = :degrade

        module_function

        # Gate and Live share ONE Toolset: a second Toolset reference here
        # could let the approval gate and the executor disagree about what a
        # tool name means. It is the BOARD's, not the caller's, because a
        # `/mode` flip changes the live slot without rebuilding either.
        #
        # `session:` is REQUIRED, not defaulted: a caller passing a
        # recorder-bearing toolset but forgetting it would get working memory
        # tools with a permanently blind manifest, and forgetting must be a
        # loud ArgumentError rather than a quiet degrade. `views:` exists
        # because a streamed tool's bytes are a view, not a record, so the
        # executor writes them to the TTY Channel AND the editor's -- never to
        # the journal, which already holds them in the turn's tool_result.
        #
        # The `tap` gives the turn middleware's thunk a live agent binding. It
        # is ASSIGNED, not merely returned: the thunk is built before the Agent
        # it reads, so left as a bare return expression the local stays nil
        # forever and the first turn raises NoMethodError on it.
        #
        # `root:` is the PROJECT's root, where every snapshot is rooted, and
        # `paths:` the state home a shadow snapshot scope keeps its store in.
        def build(board:, chronicle:, channel:, session:, backend:, root:, paths: Lain::Paths.new, timeline: nil,
                  views: nil)
          gate = board.gate(inner: Lain::Effect::Handler::Live.new(toolset: board.toolset,
                                                                   channel: LiveViews.tool_output(channel, views)))

          agent = nil
          Lain::Agent.new(toolset: board.toolset, context: board.graft(backend.context), handler: gate, session:,
                          timeline:, request_override: Lain::Agent::RequestOverride.new, # ResendBridge's slot
                          snapshot_slot: snapshots(board, root:, paths:, journal: chronicle.record_journal, channel:),
                          **backing(backend, channel, -> { agent.timeline },
                                    chronicle:, board:)).tap { |built| agent = built }
        end

        # Born here, under the posture the board starts in, and handed to the
        # board, because the board is the one object a `/mode` flip goes
        # through ({Switchboard#apply} rebinds it). The board's own build is
        # not where it can be born: that runs before any root reaches it.
        def snapshots(board, root:, paths:, journal:, channel:)
          Lain::Agent::SnapshotSlot.new(root:, scope: board.snapshot_scope, paths:, journal:, channel:).tap do |slot|
            board.bind_snapshots(slot)
          end
        end

        # The provider, and the compaction wiring hung off it -- the per-turn
        # Context source, the eager-summary observer, and the journal tee that
        # feeds the source the cache-read counts the render seam cannot see
        # ({CompactionMount}). One method, because the mount must reference THE
        # ONE provider the run talks to: {Compaction::Cold} compares idle time
        # against that provider's own cache TTL, so a second construction would
        # be a second answer.
        #
        # The mount is deliberately NOT memoized. Every piece of run state it
        # hands over is memoized in {Backend}, which is loud about a differing
        # rebind ({Backend::Rebound}); the mount is a pure assembler over
        # those, so a memo here would only add a second place for a stale
        # collaborator to hide. `board:` reaches {ToolGuard} for the read
        # guard's ledger and queue -- the BOARD's, so this agent releases into
        # the run's one region ledger rather than a second nobody reads.
        #
        # THE GUARD DOES NOT REACH SUBAGENTS. {Tools::Subagent} builds its
        # child through a bare `Agent.new` with no `instrumentation:`, so a
        # child's tool middleware is EMPTY: neither this guard nor
        # {Middleware::RefuseSecretWrites} runs for a subagent's tools. Read
        # that as path-kept, content-lost rather than ungated -- `child_handler`
        # composes its own gate, so a child's `read_file(".env")` still reaches
        # the escalation ladder, but an ordinary-classified file's sensitive
        # regions reach a subagent unmasked and flow back into the parent's
        # Timeline. Closing it is a wiring change in `subagent.rb`, not a line
        # here.
        def backing(backend, channel, timeline, chronicle:, board:)
          provider = spooled_provider(backend, chronicle:, channel:)
          journal_degradation(backend.context, provider, journal: chronicle.record_journal)
          mount = CompactionMount.new(backend:, provider:, chronicle:, channel:)
          # The run's ONE window book, the same instance the compaction source
          # and the StatusFeed divide by, so the REPL prompt's `ctx` segment
          # and the state feed cannot report two occupancies for one turn.
          #
          # The ANSWER inside it is refreshable and the trigger lives here,
          # OUTSIDE the book: {Middleware::ResolveWindow} re-resolves once per
          # turn until the answer is authoritative. The book has no clock and
          # no turn count, and one that re-resolved per READ would let a single
          # turn's three readers see three windows.
          window = backend.context_window
          { provider:, context_window: window,
            instrumentation: mount.instrumentation.with(tool_middleware: ToolGuard.stack(chronicle, board),
                                                        turn_middleware: turn_phase(chronicle, timeline, window)) }
        end

        # The turn stack, with the window refresh OUTERMOST -- ahead of the
        # chronicle's own members, because re-resolving a denominator is not
        # part of the turn a journal records, and everything downstream that
        # reads a window must see the refreshed one. A {Middleware::Stack}
        # rather than a `>>` composition because the ordering is the footgun,
        # and a Stack is the shape that stays inspectable.
        def turn_phase(chronicle, timeline, window)
          Middleware::Stack.new([Middleware::ResolveWindow.new(book: window),
                                 *chronicle.turn_middleware(timeline).to_a])
        end

        # WRITE what this run's Context asks for that its Provider cannot
        # give -- one `capability_degraded` record per missing capability, once
        # per session. {Capability::Policy} shipped with a record type, an
        # emitter and a reader and NO caller: twelve POC journals carried zero
        # such records while {Context::CacheBreakpoints} required
        # `:prompt_caching` from an ollama provider that does not declare it,
        # and {Compare} refuses to compare runs whose degraded sets differ -- so
        # the gap made incomparable runs look comparable.
        #
        # Named for the WRITE, not the negotiation: {Capability::Policy#resolve}
        # does hand back a {Capability::DegradedSet} and it is dropped here
        # deliberately, because nothing in a live chat consumes one ({Compare}
        # and {Bench::Session::Loader} rebuild it from the journal, which is the
        # durable answer).
        #
        # `:degrade` is the ONLY policy that may be wired here.
        # `Policy::Strict#handle_missing` calls {Provider#require!}, which raises
        # {Provider::Unsupported} -- so `:strict` would kill every ollama chat at
        # turn one. A constant is the honest shape until someone asks for a flag.
        #
        # It lives in THIS module rather than in {Wiring} because the two things
        # it needs are here: the ONE provider the run talks to, and the Context
        # it renders through. Wiring sits at its Metrics/ClassLength budget
        # exactly (110/110, measured). For whoever hits that budget next: a
        # NESTED class or module costs the enclosing class only ONE line toward
        # the cop, which is what makes {Wiring::Askers}' shape the in-file
        # escape hatch.
        #
        # Session-scoped, not per-turn: {Bench::Session::Loader#degraded} folds
        # these to a set, so a per-turn emission would flood the record with
        # nothing downstream complaining.
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
        # chronicle's response spool. `channel:` is the live TTY Channel for the
        # MAIN agent (stream_started reaches the frontend); a subagent leaves
        # the Null default, since its stream is not rendered and only the spool
        # tee matters there.
        def spooled_provider(backend, chronicle:, channel: Lain::Channel::Null.instance)
          backend.provider(spool: chronicle.spool, channel:)
        end
      end
    end
  end
end
