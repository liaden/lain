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

      # {Answers} handed to {#run} that were built for a DIFFERENT turn. Once
      # `answers:` is written, `response` serves only as the default's source --
      # every use comes off the accumulator -- so a mismatched pair would answer
      # one turn's calls with another's ids and commit it. Internal-only today
      # ({Agent::ToolDelivery} builds both from one response, one line apart),
      # which is exactly when a silent version is cheapest to prevent. Named for
      # {Collaborators#refuse_foreign_toolset}, which guards the same class of
      # wiring mistake one collaborator over.
      class ForeignAnswers < Error; end

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

      # One turn's answers, filled in as each call resolves.
      #
      # It exists because {#run}'s accumulator used to be a LOCAL: an interrupt
      # unwound the local and took with it the results already EARNED, so the
      # obvious repair -- answer every call in the torn turn with "cancelled" --
      # replaces a finished tool's real output with a claim that it produced
      # none. That is fabrication, in the one direction this whole repair exists
      # to avoid. A tool that finished keeps its own output; only a call with no
      # answer is answered here.
      #
      # Keyed by the {Response::ToolUse} lens object, never by its id: the lens
      # defines no `eql?`, so two calls sharing one id hold separate slots
      # rather than collapsing into one. That ambiguity stays {#names_by_id}'s
      # to refuse -- and {#run} now asks for the names BEFORE it dispatches, so
      # a duplicate id can no longer reach a commit down the cancellation path,
      # where the observer that used to raise never runs.
      #
      # Mutable on purpose, and the one mutable thing here: it is an
      # accumulator, not a value. Nothing it holds is shared past the turn.
      class Answers
        # The half of the notice BOTH repairs state, REFERENCED and never
        # copied: {CLI::Resume::Cancellation} mints the same block when a torn
        # session is loaded, and two shapes for one fact is how two repairs of
        # one defect come to disagree. Only {CLI::Resume::Cancellation::EFFECTS_UNKNOWN}
        # is this side's to replace, because only this side was present at the
        # tear.
        #
        # Resolved through methods and not constants because `lain.rb` loads
        # `agent` before `cli`, so the constant does not exist yet while this
        # class body runs. That inversion -- the loop reading a constant out of
        # the CLI -- is a LAYERING DEBT named here rather than hidden: the
        # shared half belongs in a neutral home (`lib/lain/tool/cancellation.rb`,
        # indexed from `lib/lain/tool.rb`), which is T3's own recommendation and
        # sits outside both cards' file scope.
        def self.no_result = CLI::Resume::Cancellation::NO_RESULT

        # Frozen, because an interpolated literal is mutable even under
        # `frozen_string_literal` and this String is read straight into a
        # deeply-frozen record. Composed per call rather than memoized: a
        # memo would be class-level mutable state, and only a torn turn ever
        # asks.
        #
        # It claims what the tear genuinely knows and no more -- {#dispatching}
        # was never marked, so no effect was ever built for this call.
        def self.never_dispatched
          "#{no_result} The run was interrupted before this call was dispatched, " \
          "so the tool did not run and had no effects.".freeze
        end

        # "May be" and not "were": {#dispatching} marks the call BEFORE the
        # effect is built, so this over-claims in the safe direction -- and the
        # sentence tells the model to check rather than to assume either way.
        def self.was_running
          "#{no_result} The run was interrupted while this call was running, " \
          "so its effects may be partly applied -- check before assuming they happened.".freeze
        end

        # A stranded call {Tool::ResultBlock}'s gate 4 refuses to build a result
        # for, because it names no usable id. Translated rather than left as
        # the builder's ArgumentError, and named to match
        # {CLI::Resume::Cancellation::Unpairable}, which is the same refusal on
        # the load side: a raw ArgumentError escaping a repair leaves its caller
        # holding neither the repair nor the failure it was handling -- and
        # here that caller is unwinding from an interrupt it still has to
        # re-raise.
        class Unpairable < Error; end

        # @param response [Lain::Response]
        def self.for(response) = new(response.tool_uses)

        # The turn's calls in wire order -- the SAME lenses {#blocks} keys by,
        # which is why {#run} reads them from here instead of asking the
        # Response a second time (`#tool_uses` mints a fresh lens per call).
        attr_reader :uses

        def initialize(uses)
          @uses = uses.to_a.freeze
          @blocks = {}
          @dispatched = {}
        end

        def dispatching(tool_use) = @dispatched[tool_use] = true

        def answered(tool_use, block) = @blocks[tool_use] = block

        # @return [Array<Hash>] one tool_result block per call, in wire order:
        #   the tool's own output where it returned, a cancellation notice
        #   where it did not. Gate 2's ordering, restored from `uses` rather
        #   than from completion order.
        def blocks = @uses.map { |tool_use| @blocks.fetch(tool_use) { cancellation(tool_use) } }

        # @return [Boolean] whether any call went unanswered -- false for a turn
        #   torn AFTER every tool returned, which commits real results and is
        #   not a cancellation at all.
        def cancelled? = unanswered.any?

        # The three id lists {Telemetry::ToolCancelled} carries, from ONE walk:
        # `cancelled` is every call with no output, `running` its dispatched
        # subset, `completed` the calls that kept their own. Answered together
        # because they are one partition of one list, and asking for them
        # separately walked it four times on the path that is already unwinding.
        def partition
          missing = unanswered
          { cancelled: missing.map(&:id),
            running: missing.select { |tool_use| @dispatched.key?(tool_use) }.map(&:id),
            completed: (@uses - missing).map(&:id) }
        end

        # Whether these answers were built for `response`. By id in wire order,
        # never by lens identity: {Response#tool_uses} mints a fresh lens per
        # call, so two reads of one response are never `equal?`.
        def answers?(response) = @uses.map(&:id) == response.tool_uses.map(&:id)

        private

        def unanswered = @uses.reject { |tool_use| @blocks.key?(tool_use) }

        # The same mint every real result comes through, so gates 3 and 4 hold
        # for a cancellation exactly as they do for an answer.
        def cancellation(tool_use)
          Tool::ResultBlock.of(Tool::Result.error(notice(tool_use)), tool_use_id: tool_use.id).to_h
        rescue ArgumentError => e
          raise Unpairable, e.message
        end

        def notice(tool_use)
          @dispatched.key?(tool_use) ? self.class.was_running : self.class.never_dispatched
        end
      end

      # Which capability set {#answered_questions} harvests from. Readable
      # because it is not private business: the harvest becomes the committed
      # turn's `causal_parents:`, so an {Agent} handed a runner it did not build
      # has to check that the two of them are looking at the same set
      # ({Collaborators#refuse_foreign_toolset}).
      attr_reader :toolset

      # Readable for the same reason `toolset` is: what a runner was wired to is not
      # private business when the Agent did not build it.
      attr_reader :handler, :middleware, :observer

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
      # `answers:` is where the turn's blocks accumulate. It defaults to a fresh
      # one, so every existing caller is unchanged -- the {Agent} passes its own
      # because a caller that will have to answer an INTERRUPT needs the partial
      # results to outlive the unwind ({Answers}).
      #
      # The names are resolved BEFORE dispatch rather than after: two calls
      # sharing an id is gate 4's ambiguity, and refusing it here means it can
      # never reach a Timeline commit down the cancellation path, where the
      # observation that used to raise never runs. No tool runs either, which is
      # the better refusal anyway.
      def run(response, context:, answers: Answers.for(response))
        refuse_foreign_answers(response, answers)
        uses = answers.uses
        names = names_by_id(uses)
        safety = safety_by_name(uses)
        contiguous_runs(uses, safety).each do |run|
          gatherable?(run, safety) ? gather(run, context, answers) : sequential(run, context, answers)
        end
        answers.blocks.tap { |blocks| observe_all(names, blocks) }
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
      def delivery(response, context:, answers: Answers.for(response))
        content = run(response, context:, answers:)
        { content:, causal_parents: answered_questions }
      end

      # {#delivery}'s value for a turn the run was INTERRUPTED in the middle of:
      # the same two keys, over the answers the unwind left behind. No `meta:`,
      # for the reason T3's projection carries none -- one turn mixes a real
      # result with cancelled ones, so the fact lives per block, and a meta
      # added later moves the digest.
      #
      # **It harvests.** The choice is not free: `answered_questions` clears each
      # tool as it reads it, so harvesting twice loses the second read's edges
      # and harvesting never leaves an answer delivered with no consumption edge
      # at all. Exactly one harvest happens per turn, because the two paths are
      # exclusive -- {#delivery} computes `content` FIRST, so a raise out of
      # {#run} means it never reached its own harvest. And the harvest belongs
      # HERE rather than being skipped, because the blocks being committed
      # include any `ask_human` that COMPLETED before the tear: that block is
      # the answer's delivery into the conversation, so this is the turn whose
      # `causal_parents` retire the question. Skipping it would leave the answer
      # in the record with nothing citing it, and let some later, unrelated turn
      # claim the edge instead.
      #
      # A stop cannot land mid-harvest: `take_answered_questions` is pure Ruby
      # with no suspension point, and structured cancellation only lands at one
      # ({Agent::Budget#interrupt} states the same guarantee for the Timeline).
      #
      # @param answers [Answers] the turn's partial answers
      # @return [Hash] {Timeline#commit} kwargs: `content:`, `causal_parents:`
      def cancelled_delivery(answers)
        { content: answers.blocks, causal_parents: answered_questions }
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
      # before it consumes anything.
      #
      # **An interrupt still never reaches here, and since T6 that is the point
      # rather than a happy accident.** A stopped turn no longer commits nothing
      # -- {Agent#perform_tools} now commits the results already earned plus a
      # cancellation for each call that has none -- so the second half of the old
      # claim is what carries the weight: those committed digests were never
      # offered to an observer, therefore {Oracle::Eager#fire} never consumed
      # them, therefore every one of them is still summarizable by whoever picks
      # the session up. Observing on the way out of an interrupt would spend each
      # digest on a fire that a stopping task reaps before it can answer, which
      # would make exactly the content a torn turn commits the only content in
      # the session that can never be summarized. So the cancellation path
      # deliberately does NOT observe, and this seam stays where it is.
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
      # not a summary to skip. The map itself is built at the TOP of {#run} now,
      # because its duplicate-id refusal has to precede dispatch.
      def observe_all(names, blocks)
        blocks.each { |block| observe(block, names.fetch(block["tool_use_id"])) }
      end

      def refuse_foreign_answers(response, answers)
        return if answers.answers?(response)

        raise ForeignAnswers, "these answers were built for a different turn: #{answers.uses.map(&:id).inspect} " \
                              "against #{response.tool_uses.map(&:id).inspect}"
      end

      # NOT `to_h`, which is last-wins and would answer a lie: the first
      # block would pair to the second tool's name with nothing raised, in the
      # one method whose `fetch` was chosen for loudness.
      def names_by_id(uses)
        uses.each_with_object({}) do |tool_use, names|
          id = tool_use.id
          refuse_duplicate(names, id, tool_use.name)
          names[id] = tool_use.name
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
        uses.map(&:name).uniq
            .to_h { |name| [name, @handler.tool_named(name)&.parallel_safe? || false] }
      end

      # `chunk_while` is exactly this partition: a chunk extends only while
      # both neighbours are parallel-safe, so every unsafe tool -- adjacent to
      # nothing it may run beside -- falls out as its own singleton run, the
      # barrier {#run} dispatches alone. {#run} always passes the turn's one
      # precomputed map; the default only serves a direct diagnostic caller,
      # which -- like every path through here -- hands over
      # {Response::ToolUse} lenses, never raw block hashes.
      def contiguous_runs(uses, safety = safety_by_name(uses))
        uses.chunk_while { |left, right| safety.fetch(left.name) && safety.fetch(right.name) }
      end

      # The default, order-preserving map: each tool_use resolved before the next.
      # Load-bearing for tools that make no parallelism claim -- gate 2 is an
      # ordering over the RETURNED blocks, and a sequential map trivially honours
      # it. Every run that is not a multi-tool stretch of parallel_safe? tools
      # lands here.
      def sequential(uses, context, answers)
        uses.each { |tool_use| answer(tool_use, context, answers) }
      end

      # Fan the tool_uses out as sibling Async tasks, then wait for all of them.
      # Gate 2 is unmoved and now sits one level down: {Answers#blocks} restores
      # the schedule the model asked for by walking `uses`, so out-of-order
      # completion still lands in ONE user turn ordered by tool_use however the
      # tasks actually finished. A stop of the hosting task cancels the siblings
      # as one tree (structured cancellation); since T6 that no longer means an
      # interrupt mid-fan-out has nothing to commit -- whichever siblings had
      # already recorded their answer keep it, and the rest are answered as
      # cancelled. `Sync` joins the Agent's reactor when there is one and spins
      # one up otherwise, so a direct caller outside a reactor works too.
      def gather(uses, context, answers)
        Sync do |task|
          uses.map { |tool_use| task.async { answer(tool_use, context, answers) } }
              .each(&:wait)
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
        uses.size > 1 && uses.all? { |tool_use| safety.fetch(tool_use.name) }
      end

      # Gates 3 and 4 are constructor invariants of {Tool::ResultBlock.of}, which
      # states them. `to_h` hands the plain hash straight back, so delivery, the
      # commit, and the observer see what they always did.
      #
      # The dispatch is MARKED before the effect is built and the answer is
      # recorded the instant it exists, so an interrupt landing anywhere in
      # between finds the call marked-but-unanswered -- which is exactly the
      # state {Answers#notice} reads to tell "was running" from "never
      # dispatched".
      def answer(tool_use, context, answers)
        answers.dispatching(tool_use)
        answers.answered(tool_use, Tool::ResultBlock.of(dispatch(tool_use, context), tool_use_id: tool_use.id).to_h)
      end

      def dispatch(tool_use, context)
        effect = Effect::ToolCall.new(
          tool_use_id: tool_use.id,
          name: tool_use.name,
          # Gate 5: a parsed object, never a serialized JSON string. The Provider
          # guarantees this even on the streaming path, where the wire hands back
          # `input` as a raw String.
          input: tool_use.input
        )
        @middleware.call({ effect:, context: }, &@handler.to_app).result
      end
    end
  end
end
