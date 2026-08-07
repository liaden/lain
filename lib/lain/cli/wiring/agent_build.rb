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
                          **backing(backend, channel, -> { agent.timeline }, chronicle:)).tap { |built| agent = built }
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
        def backing(backend, channel, timeline, chronicle:)
          provider = spooled_provider(backend, chronicle:, channel:)
          mount = CompactionMount.new(backend:, provider:, chronicle:, channel:)
          { provider:,
            instrumentation: mount.instrumentation.with(tool_middleware: ToolGuard.stack(chronicle),
                                                        turn_middleware: chronicle.turn_middleware(timeline)) }
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
