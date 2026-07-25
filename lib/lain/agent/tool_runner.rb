# frozen_string_literal: true

require "async"

module Lain
  class Agent
    # Turns an assistant turn's tool_use blocks into the tool_result blocks that
    # answer them.
    #
    # Split out of the Agent because it answers a different question. The Agent
    # decides *when* to run tools; this decides *how* -- building the Effect,
    # threading it through the tool middleware, and shaping the outcome into wire
    # blocks. Correctness gates 3, 4, and 5 all live in that shaping, and they are
    # easier to see when they are not interleaved with the state machine.
    #
    # Gate 2 stays with the Agent, because "all results in ONE user turn" is a
    # statement about the Timeline, not about any individual tool.
    class ToolRunner
      # Two tool_uses in one turn sharing an id. Gate 4 pairs each tool_result
      # to the tool_use it answers BY that id, so a duplicate makes the pairing
      # ambiguous -- and a Hash built from them silently keeps the LAST, which
      # would label the first result with the second tool's name. Loud, at the
      # first place the ambiguity is observable.
      class DuplicateToolUse < Error; end

      # The post-dispatch observers a {ToolRunner} accepts: one message,
      # `#observe(tool_result_block, tool_name)`, sent once per completed
      # result. The duck is deliberately narrow -- a wire block plus the name
      # of the tool that filled it carries everything an observer of *results*
      # can want, and nothing about oracles or summaries leaks into the
      # dispatcher.
      #
      # The name is a second argument because it is NOT on the block:
      # {#result_block} emits the four keys gate 4 pins, and that block is the
      # `tool_result` the provider receives. It rides beside the block instead.
      #
      # The eager-summary observer this seam exists for is
      # {Effect::Handler::Summarizing::Observer}, which lives with the policy
      # it applies. It is the mount production should use, and it and the
      # {Effect::Handler::Summarizing} decorator are ALTERNATIVES, never both
      # against one {Oracle::Eager}: the decorator fires from inside the
      # handler chain, i.e. inside {#gather}, and would consume each digest
      # before this seam is ever offered the result.
      module Observer
        # Observes nothing, so a ToolRunner built without one behaves exactly
        # as it did before the seam existed.
        class Null
          def observe(_block, _tool_name) = nil
        end
      end

      # `toolset:` exists for {#answered_questions}' harvest alone -- dispatch
      # itself still routes through `handler`, never a direct tool lookup.
      # `observer:` is the post-dispatch seam {#observe} describes.
      def initialize(handler:, middleware: Middleware::Stack.new, toolset: Toolset.new,
                     observer: Observer::Null.new)
        @handler = handler
        @middleware = middleware
        @toolset = toolset
        @observer = observer
      end

      # @return [Array<Hash>] one tool_result block per tool_use, in wire order
      #
      # Barrier semantics: the turn splits into maximal CONTIGUOUS runs of
      # parallel-safe tools; each safe run gathers concurrently, and each
      # unsafe tool is a barrier that runs alone -- strictly after everything
      # before it, strictly before everything after it. Execution order
      # therefore never diverges from wire order: [safe, unsafe, safe] runs
      # exactly as #sequential would (a run of one gains nothing), while
      # [safe, safe, unsafe, safe] overlaps only the leading pair. The
      # rejected alternative -- gather the safe SUBSET first, the unsafe
      # remainder after -- reorders execution against the wire order the
      # model saw: a silent causal lie the moment an unsafe tool writes what
      # a later safe tool reads.
      def run(response, context:)
        uses = response.tool_uses
        safety = safety_by_name(uses)
        blocks = contiguous_runs(uses, safety).flat_map do |run|
          gatherable?(run, safety) ? gather(run, context) : sequential(run, context)
        end
        observe_all(uses, blocks)
        blocks
      end

      # One user-turn delivery (I6, ruled): the tool_result blocks PLUS the
      # causal edges the Agent's commit cites -- the consumption edge that
      # retires an answered question from {Event::Projection#pending}("human")
      # (the full rule lives on {Tools::AskHuman#take_answered_questions}).
      # Both are properties of the dispatch that just ran, which is why they
      # are built here as one value: the tools run FIRST, since only a
      # completed dispatch makes the hand-over readable. Toolsets with nothing
      # to hand over yield `causal_parents: []`, so ordinary turns' recorded
      # digests do not move.
      #
      # @return [Hash] {Timeline#commit} kwargs: `content:`, `causal_parents:`
      def delivery(response, context:)
        content = run(response, context:)
        { content:, causal_parents: answered_questions }
      end

      private

      # The observation seam, deliberately HERE and not inside {#gather}. An
      # observer may spawn work on the ambient reactor -- an eager summary is
      # the motivating case -- and {Oracle::Eager#fire} consumes its digest
      # BEFORE it spawns, so any fire that is later reaped burns that content's
      # key for the whole session. #gather is where reaping happens, on both
      # paths: with no ambient reactor its `Sync` builds and closes one of its
      # own, and on the live path an interrupt mid-fan-out unwinds the run's
      # reactor, whose close terminates transients outright. (A plain stop does
      # not reap them -- async skips transient children and reparents them on
      # `consume` -- but the digest is spent either way.) Called from {#run}
      # once every run has gathered, the observation instead inherits the
      # CALLER's reactor -- the agent loop's, which outlives the turn -- and
      # where the caller has none it degrades to the clean no-op #fire performs
      # before it consumes anything. An interrupt never reaches here at all, so
      # a stopped turn commits exactly what it always did AND leaves every
      # digest still summarizable.
      #
      # Observation is a side channel, so a broken observer costs the turn
      # nothing -- the same containment {Oracle::Eager} gives a failed fire.
      # That it is also SILENT is a named debt, not an oversight: a ToolRunner
      # holds no journal and nothing outside the frontend may write to $stderr,
      # so today there is nowhere for the failure to go. Give this object a
      # journal and this rescue should record instead of swallow. `Async::Stop`
      # is not a StandardError, so a stop still cancels the tree.
      # Pairs each block back to the tool_use it answers, because the NAME the
      # observer needs is on the tool_use ({#dispatch} reads it there) and not
      # on the block gate 4 pins. Keyed by `tool_use_id` rather than by
      # position, and `fetch`ed: an unpaired block would be a dispatcher bug,
      # not a summary to skip. Nothing about {#dispatch}'s return or {#gather}'s
      # arity moves for this -- the pairing happens after both have finished.
      def observe_all(uses, blocks)
        names = names_by_id(uses)
        blocks.each { |block| observe(block, names.fetch(block["tool_use_id"])) }
      end

      # NOT `to_h`, which is last-wins and would answer a lie: the first
      # block would pair to the second tool's name with nothing raised, in the
      # one method whose `fetch` was chosen for loudness.
      def names_by_id(uses)
        uses.each_with_object({}) do |tool_use, names|
          id = tool_use.fetch("id")
          refuse_duplicate(names, id, tool_use.fetch("name"))
          names[id] = tool_use.fetch("name")
        end
      end

      def refuse_duplicate(names, id, name)
        return unless names.key?(id)

        raise DuplicateToolUse, "two tool_uses share id #{id.inspect} (#{names.fetch(id)} and #{name}); " \
                                "gate 4 pairs each tool_result to its tool_use by that id"
      end

      def observe(block, tool_name)
        @observer.observe(block, tool_name)
      rescue StandardError
        nil
      end

      # {#delivery}'s harvest, duck-collected from whichever tools answer the
      # hand-over message; each hands over exactly once.
      def answered_questions
        @toolset.select { |tool| tool.respond_to?(:take_answered_questions) }
                .flat_map(&:take_answered_questions)
      end

      # The safety decision's single owner: one handler-chain lookup per
      # distinct tool name per turn, computed HERE and consulted (via `fetch`,
      # so an unlisted name fails loudly) by BOTH {#contiguous_runs} and
      # {#gatherable?} -- no re-lookup per neighbour comparison, and no second
      # derivation that could silently disagree with the partition and
      # downgrade a safe run to sequential. Names the chain does not hold (a
      # Mock handler, an unknown tool) map to false: never parallel-safe.
      # Per-TURN on purpose, never per-runner: deferred disclosure can add
      # tools mid-session, so a name's answer is only stable within one turn.
      #
      # @return [Hash{String => Boolean}]
      def safety_by_name(uses)
        uses.map { |tool_use| tool_use.fetch("name") }.uniq
            .to_h { |name| [name, @handler.tool_named(name)&.parallel_safe? || false] }
      end

      # `chunk_while` is exactly this partition: a chunk extends only while
      # both neighbours are parallel-safe, so every unsafe tool -- adjacent to
      # nothing it may run beside -- falls out as its own singleton run, the
      # barrier {#run} dispatches alone. {#run} always passes the turn's one
      # precomputed map; the default only serves a direct diagnostic caller.
      def contiguous_runs(uses, safety = safety_by_name(uses))
        uses.chunk_while { |left, right| safety.fetch(left.fetch("name")) && safety.fetch(right.fetch("name")) }
      end

      # The default, order-preserving map: each tool_use resolved before the next.
      # Load-bearing for tools that make no parallelism claim -- gate 2 is an
      # ordering over the RETURNED blocks, and a sequential map trivially honours
      # it. Every run that is not a multi-tool stretch of parallel_safe? tools
      # lands here.
      def sequential(uses, context)
        uses.map { |tool_use| result_block(tool_use, context) }
      end

      # Fan the tool_uses out as sibling Async tasks, then gather their results in
      # tool_use order. Gate 2 is unmoved: `map(&:wait)` restores the schedule the
      # model asked for however the tasks actually finished, so out-of-order
      # completion still lands in ONE user turn ordered by tool_use. A stop of the
      # hosting task cancels the siblings as one tree (structured cancellation), so
      # an interrupt mid-fan-out returns nothing to commit rather than a partial
      # set. `Sync` joins the Agent's reactor when there is one and spins one up
      # otherwise, so a direct caller outside a reactor works too.
      def gather(uses, context)
        Sync do |task|
          uses.map { |tool_use| task.async { result_block(tool_use, context) } }
              .map(&:wait)
        end
      end

      # Concurrency is opted into per tool AND only within one contiguous run
      # of them: {#contiguous_runs} isolates every unsafe tool in a singleton
      # run, so a tool that made no parallelism claim is never dispatched
      # alongside another. One tool_use has nothing to gather, so a run of one
      # stays sequential too. The all? is the gate's own definition, not dead
      # weight -- and it reads the SAME {#safety_by_name} map the partition
      # chunked by, so the two can never disagree.
      def gatherable?(uses, safety)
        uses.size > 1 && uses.all? { |tool_use| safety.fetch(tool_use.fetch("name")) }
      end

      def result_block(tool_use, context)
        result = dispatch(tool_use, context)
        {
          "type" => "tool_result",
          # Gate 4: the id must match the tool_use that asked for it.
          "tool_use_id" => tool_use.fetch("id"),
          "content" => result.content,
          # Gate 3: a failed tool is reported, never dropped and never raised past
          # the loop. Handler::Live is where the conversion happens.
          "is_error" => result.error?
        }
      end

      def dispatch(tool_use, context)
        effect = Effect::ToolCall.new(
          tool_use_id: tool_use.fetch("id"),
          name: tool_use.fetch("name"),
          # Gate 5: a parsed object, never a serialized JSON string. The Provider
          # guarantees this even on the streaming path, where the wire hands back
          # `input` as a raw String.
          input: tool_use.fetch("input")
        )
        @middleware.call({ effect:, context: }, &@handler.to_app).result
      end
    end
  end
end
