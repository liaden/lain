# frozen_string_literal: true

require "async"

module Lain
  class Agent
    # Turns an assistant turn's tool_use blocks into the tool_result blocks that
    # answer them.
    #
    # Split out of the Agent because it answers a different question: the Agent
    # decides *when* to run tools, this decides *how* -- building the Effect,
    # threading it through the tool middleware, and shaping the outcome into wire
    # blocks. Correctness gates 3, 4 and 5 all live in that shaping. Gate 2 stays
    # with the Agent, because "all results in ONE user turn" is a statement about
    # the Timeline, not about any individual tool.
    class ToolRunner
      # Two tool_uses in one turn sharing an id. Gate 4 pairs each tool_result to
      # the tool_use it answers BY that id, and a Hash built from them silently
      # keeps the LAST -- which would label the first result with the second
      # tool's name. Loud, at the first place the ambiguity is observable.
      class DuplicateToolUse < Error; end

      # The post-dispatch observers a {ToolRunner} accepts: one message,
      # `#observe(tool_result_block, tool_name)`, sent once per completed result.
      # Deliberately narrow, so nothing about oracles or summaries leaks into the
      # dispatcher. The name is a second argument because it is NOT on the block:
      # {#result_block} emits the four keys gate 4 pins, and that block is the
      # `tool_result` the provider receives.
      #
      # {Compaction::SummaryObserver} is the mount production uses.
      module Observer
        # Observes nothing, so a ToolRunner built without one behaves exactly as
        # it did before the seam existed.
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
      # defines no `eql?`, so two calls sharing one id hold separate slots rather
      # than collapsing into one. That ambiguity is {#names_by_id}'s to refuse,
      # and {#run} asks for the names BEFORE it dispatches so a duplicate id
      # cannot reach a commit down the cancellation path, where the observer that
      # used to raise never runs.
      #
      # Mutable on purpose, and the one mutable thing here: an accumulator, not a
      # value. Nothing it holds is shared past the turn.
      class Answers
        # The half of the notice BOTH repairs state, REFERENCED and never copied:
        # {CLI::Resume::Cancellation} mints the same block when a torn session is
        # loaded, and two shapes for one fact is how two repairs of one defect
        # come to disagree.
        #
        # Resolved through a method and not a constant because `lain.rb` loads
        # `agent` before `cli`, so the constant does not exist yet while this
        # class body runs. That inversion is a LAYERING DEBT named here rather
        # than hidden: the shared half belongs in a neutral home
        # (`lib/lain/tool/cancellation.rb`), which is the recommendation on record.
        def self.no_result = CLI::Resume::Cancellation::NO_RESULT

        # Frozen, because an interpolated literal is mutable even under
        # `frozen_string_literal` and this String is read straight into a
        # deeply-frozen record. Composed per call rather than memoized: a memo
        # would be class-level mutable state, and only a torn turn ever asks.
        #
        # It claims what the tear genuinely knows and no more -- {#dispatching}
        # was never marked, so no effect was ever built for this call.
        def self.never_dispatched
          "#{no_result} The run was interrupted before this call was dispatched, " \
          "so the tool did not run and had no effects.".freeze
        end

        # "May be" and not "were": {#dispatching} marks the call BEFORE the
        # effect is built, so this over-claims in the safe direction, and the
        # sentence tells the model to check rather than to assume either way.
        def self.was_running
          "#{no_result} The run was interrupted while this call was running, " \
          "so its effects may be partly applied -- check before assuming they happened.".freeze
        end

        # A stranded call {Tool::ResultBlock}'s gate 4 refuses to build a result
        # for, because it names no usable id. Translated rather than left as the
        # builder's ArgumentError: a raw ArgumentError escaping a repair leaves
        # its caller holding neither the repair nor the failure it was handling,
        # and here that caller is unwinding from an interrupt it still has to
        # re-raise. Named to match {CLI::Resume::Cancellation::Unpairable}, the
        # same refusal on the load side.
        class Unpairable < Error; end

        # @param response [Lain::Response]
        def self.for(response) = new(response.tool_uses)

        # The turn's calls in wire order -- the SAME lenses {#blocks} keys by,
        # which is why {#run} reads them from here instead of asking the Response
        # a second time (`#tool_uses` mints a fresh lens per call).
        attr_reader :uses

        def initialize(uses)
          @uses = uses.to_a.freeze
          @blocks = {}
          @dispatched = {}
        end

        def dispatching(tool_use) = @dispatched[tool_use] = true

        def answered(tool_use, block) = @blocks[tool_use] = block

        # @return [Array<Hash>] one tool_result block per call, in wire order:
        #   the tool's own output where it returned, a cancellation notice where
        #   it did not. Gate 2's ordering, restored from `uses` rather than from
        #   completion order.
        def blocks = @uses.map { |tool_use| @blocks.fetch(tool_use) { cancellation(tool_use) } }

        # @return [Boolean] whether any call went unanswered -- false for a turn
        #   torn AFTER every tool returned, which commits real results and is not
        #   a cancellation at all.
        def cancelled? = unanswered.any?

        # The three id lists {Telemetry::ToolCancelled} carries, from ONE walk.
        # Answered together because they are one partition of one list, and
        # asking separately walked it four times on the path that is already
        # unwinding.
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
      # because the harvest becomes the committed turn's `causal_parents:`, so an
      # {Agent} handed a runner it did not build has to check that the two are
      # looking at the same set ({.refuse_foreign_toolset}).
      attr_reader :toolset

      # Readable for `toolset`'s reason: what a runner was wired to is not
      # private business when the Agent did not build it.
      attr_reader :handler, :middleware, :observer

      # The digest gate, asked of a runner an {Agent} was HANDED rather than
      # built. It belongs here, where a toolset means something: {#delivery}
      # harvests answered questions from THIS object's toolset and the {Agent}
      # commits them as the turn's `causal_parents:`, which are Merkle digest
      # input -- so a runner looking at a different capability set writes a
      # DIFFERENT Timeline for the same conversation, and because `Canonical`
      # bytes serve turn hashing and prompt-cache stability both, the symptom is
      # an unexplained cache miss and never an error.
      #
      # Identity, not equality, is the honest test: the harvest drains
      # per-INSTANCE state (`take_answered_questions` empties its queue), so two
      # equal toolsets holding different tool objects would harvest from the
      # wrong ones.
      #
      # @param runner [ToolRunner] the handed-over runner, or any stand-in for one
      # @param toolset [Lain::Toolset] the Agent's own capability set
      # @raise [ArgumentError] if the two disagree, or if the runner cannot say
      def self.refuse_foreign_toolset(runner, toolset:)
        refuse_mute_runner(runner)
        return if runner.toolset.equal?(toolset)

        raise ArgumentError, "tool_runner: was built over a different Toolset than toolset:. The runner harvests " \
                             "answered questions from its own toolset and the Agent commits them as the turn's " \
                             "causal_parents, so two sets means two digests for one conversation. Build it as " \
                             "ToolRunner.new(handler:, toolset:) with that same Toolset, or omit tool_runner:."
      end

      # The gate above sends one message, so a runner that cannot answer it is
      # refused by name. This seam exists for duck-typed runners, and a bare
      # NoMethodError would be the one crash among refusals that all say what to
      # do.
      def self.refuse_mute_runner(runner)
        return if runner.respond_to?(:toolset)

        raise ArgumentError, "tool_runner: does not answer #toolset, so there is no way to check that it harvests " \
                             "from the same capabilities the model is shown. A stand-in for #{ToolRunner} has to " \
                             "expose the toolset its answered-question harvest reads."
      end
      private_class_method :refuse_mute_runner

      # `toolset:` is what a call's name resolves against -- ONCE per call, in
      # {#dispatch} -- and what {#answered_questions} harvests from. `handler`
      # interprets the tool that resolution found; it holds no toolset itself.
      def initialize(handler:, middleware: Middleware::Stack.new, toolset: Toolset.new,
                     observer: Observer::Null.new)
        @handler = handler
        @middleware = middleware
        @toolset = toolset
        @observer = observer
      end

      # Barrier semantics: the turn splits into maximal CONTIGUOUS runs of
      # parallel-safe tools; each safe run gathers concurrently, and each unsafe
      # tool is a barrier that runs alone. Execution order therefore never
      # diverges from wire order. The rejected alternative -- gather the safe
      # SUBSET first, the unsafe remainder after -- reorders execution against
      # the wire order the model saw: a silent causal lie the moment an unsafe
      # tool writes what a later safe tool reads.
      #
      # `answers:` is where the turn's blocks accumulate; the {Agent} passes its
      # own because a caller that will have to answer an INTERRUPT needs the
      # partial results to outlive the unwind ({Answers}).
      #
      # The names are resolved BEFORE dispatch: two calls sharing an id is gate
      # 4's ambiguity, and refusing it here means it can never reach a Timeline
      # commit down the cancellation path, where the observation that used to
      # raise never runs. No tool runs either, which is the better refusal.
      #
      # @return [Array<Hash>] one tool_result block per tool_use, in wire order
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

      # One user-turn delivery: the tool_result blocks PLUS the causal edges the
      # Agent's commit cites -- the consumption edge that retires an answered
      # question from {Event::Projection#pending}("human") (the full rule lives
      # on {Tools::AskHuman#take_answered_questions}). The tools run FIRST, since
      # only a completed dispatch makes the hand-over readable. Toolsets with
      # nothing to hand over yield `causal_parents: []`, so ordinary turns'
      # recorded digests do not move.
      #
      # @return [Hash] {Timeline#commit} kwargs: `content:`, `causal_parents:`
      def delivery(response, context:, answers: Answers.for(response))
        content = run(response, context:, answers:)
        { content:, causal_parents: answered_questions }
      end

      # {#delivery}'s value for a turn the run was INTERRUPTED in the middle of.
      # No `meta:`, for the reason the load-side repair carries none -- one turn
      # mixes a real result with cancelled ones, so the fact lives per block, and
      # a meta added later moves the digest.
      #
      # **It harvests**, and the choice is not free: `answered_questions` clears
      # each tool as it reads it, so harvesting twice loses the second read's
      # edges and never harvesting leaves an answer delivered with no consumption
      # edge at all. Exactly one harvest happens per turn, because the two paths
      # are exclusive -- {#delivery} computes `content` FIRST, so a raise out of
      # {#run} means it never reached its own harvest. And it belongs HERE rather
      # than being skipped, because the blocks being committed include any
      # `ask_human` that COMPLETED before the tear: that block is the answer's
      # delivery into the conversation, so this is the turn whose `causal_parents`
      # retire the question. Skipping it would leave the answer in the record with
      # nothing citing it, and let some later, unrelated turn claim the edge.
      #
      # A stop cannot land mid-harvest: `take_answered_questions` is pure Ruby
      # with no suspension point, and structured cancellation only lands at one.
      #
      # @param answers [Answers] the turn's partial answers
      # @return [Hash] {Timeline#commit} kwargs: `content:`, `causal_parents:`
      def cancelled_delivery(answers)
        { content: answers.blocks, causal_parents: answered_questions }
      end

      private

      # The observation seam, deliberately HERE and not inside {#gather}. An
      # observer may spawn work on the ambient reactor -- an eager summary is the
      # motivating case -- and {Oracle::Eager#fire} consumes its digest BEFORE it
      # spawns, so any fire that is later reaped burns that content's key for the
      # whole session. #gather is where reaping happens on both paths: with no
      # ambient reactor its `Sync` builds and closes one of its own, and on the
      # live path an interrupt mid-fan-out unwinds the run's reactor, whose close
      # terminates transients outright. Called from {#run} once every run has
      # gathered, the observation instead inherits the CALLER's reactor -- the
      # agent loop's, which outlives the turn -- and degrades to #fire's clean
      # no-op where the caller has none.
      #
      # **An interrupt never reaches here, and that is the point rather than an
      # accident.** A stopped turn commits the results already earned plus a
      # cancellation for each call that has none, and those committed digests
      # were never offered to an observer, so {Oracle::Eager#fire} never consumed
      # them and every one is still summarizable by whoever picks the session up.
      # Observing on the way out of an interrupt would spend each digest on a
      # fire that a stopping task reaps before it can answer, making exactly the
      # content a torn turn commits the only content in the session that can
      # never be summarized.
      #
      # Pairs each block back to the tool_use it answers, because the NAME the
      # observer needs is on the tool_use and not on the block gate 4 pins. Keyed
      # by `tool_use_id` rather than by position, and `fetch`ed: an unpaired
      # block would be a dispatcher bug, not a summary to skip.
      def observe_all(names, blocks)
        blocks.each { |block| observe(block, names.fetch(block["tool_use_id"])) }
      end

      def refuse_foreign_answers(response, answers)
        return if answers.answers?(response)

        # {Answers} handed to {#run} that were built for a DIFFERENT turn. Once
        # `answers:` is written, `response` serves only as the default's source, so
        # a mismatched pair would answer one turn's calls with another's ids and
        # commit it. Internal-only today ({Agent::ToolDelivery} builds both from
        # one response, one line apart), which is exactly when a silent version is
        # cheapest to prevent.
        raise Error, "these answers were built for a different turn: #{answers.uses.map(&:id).inspect} " \
                     "against #{response.tool_uses.map(&:id).inspect}"
      end

      # NOT `to_h`, which is last-wins and would answer a lie: the first block
      # would pair to the second tool's name with nothing raised, in the one
      # method whose `fetch` was chosen for loudness.
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

      # Observation is a side channel, so a broken observer costs the turn
      # nothing -- the same containment {Oracle::Eager} gives a failed fire. That
      # it is also SILENT is a named debt: a ToolRunner holds no journal and
      # nothing outside the frontend may write to $stderr, so today there is
      # nowhere for the failure to go. Give this object a journal and this rescue
      # should record instead of swallow. `Async::Stop` is not a StandardError,
      # so a stop still cancels the tree.
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

      # The safety decision's single owner: one toolset lookup per distinct
      # tool name per turn, consulted via `fetch` (so an unlisted name fails
      # loudly) by BOTH {#contiguous_runs} and {#gatherable?} -- no second
      # derivation that could disagree with the partition and downgrade a safe
      # run to sequential. A name the set does not hold resolves to
      # {Toolset::Unheld}, never parallel-safe. Per-TURN on purpose, never
      # per-runner: deferred disclosure can add tools mid-session, so a name's
      # answer is only stable within one turn.
      #
      # @return [Hash{String => Boolean}]
      def safety_by_name(uses)
        uses.map(&:name).uniq.to_h { |name| [name, resolved(name).parallel_safe?] }
      end

      # `chunk_while` is exactly this partition: a chunk extends only while both
      # neighbours are parallel-safe, so every unsafe tool falls out as its own
      # singleton run -- the barrier {#run} dispatches alone. The default only
      # serves a direct diagnostic caller, which -- like every path through here
      # -- hands over {Response::ToolUse} lenses, never raw block hashes.
      def contiguous_runs(uses, safety = safety_by_name(uses))
        uses.chunk_while { |left, right| safety.fetch(left.name) && safety.fetch(right.name) }
      end

      # Load-bearing for tools that make no parallelism claim: gate 2 is an
      # ordering over the RETURNED blocks, and a sequential map trivially honours
      # it. Every run that is not a multi-tool stretch of parallel_safe? tools
      # lands here.
      def sequential(uses, context, answers)
        uses.each { |tool_use| answer(tool_use, context, answers) }
      end

      # Gate 2 is unmoved and sits one level down: {Answers#blocks} restores the
      # schedule the model asked for by walking `uses`, so out-of-order
      # completion still lands in ONE user turn ordered by tool_use. A stop of
      # the hosting task cancels the siblings as one tree (structured
      # cancellation); whichever siblings had already recorded their answer keep
      # it, and the rest are answered as cancelled. `Sync` joins the Agent's
      # reactor when there is one and spins one up otherwise, so a direct caller
      # outside a reactor works too.
      def gather(uses, context, answers)
        Sync do |task|
          uses.map { |tool_use| task.async { answer(tool_use, context, answers) } }
              .each(&:wait)
        end
      end

      # Concurrency is opted into per tool AND only within one contiguous run of
      # them, so a tool that made no parallelism claim is never dispatched
      # alongside another. The `all?` reads the SAME {#safety_by_name} map the
      # partition chunked by, so the two can never disagree.
      def gatherable?(uses, safety)
        uses.size > 1 && uses.all? { |tool_use| safety.fetch(tool_use.name) }
      end

      # Gates 3 and 4 are constructor invariants of {Tool::ResultBlock.of}, which
      # states them. `to_h` hands the plain hash straight back, so delivery, the
      # commit and the observer see what they always did.
      #
      # The dispatch is MARKED before the effect is built and the answer recorded
      # the instant it exists, so an interrupt landing anywhere in between finds
      # the call marked-but-unanswered -- exactly the state {Answers#notice}
      # reads to tell "was running" from "never dispatched".
      def answer(tool_use, context, answers)
        answers.dispatching(tool_use)
        answers.answered(tool_use, Tool::ResultBlock.of(dispatch(tool_use, context), tool_use_id: tool_use.id).to_h)
      end

      # The tool is resolved HERE and rides the env as `tool:`, so every layer
      # that judges the call reads the object the interpreter would run. That
      # holds by POSITION, not by construction: a layer sitting between the
      # gate and the interpreter could rewrite `:effect` or `:tool` after
      # approval, so the gate must be the last layer before the interpreter.
      #
      # This is also the one place the stack meets its interpreter -- the
      # innermost app writes the handler's answer to `:result`, which the
      # layers on the way out can observe.
      def dispatch(tool_use, context)
        effect = Effect::ToolCall.new(
          tool_use_id: tool_use.id,
          name: tool_use.name,
          # Gate 5: a parsed object, never a serialized JSON string. The Provider
          # guarantees this even on the streaming path, where the wire hands back
          # `input` as a raw String.
          input: tool_use.input
        )
        @middleware.call({ effect:, context:, tool: resolved(effect.name) }) do |env|
          env.merge(result: interpreted(effect.name, env))
        end.result
      end

      # Approval can take as long as a human takes, and a `/mode` flip in that
      # window may withdraw the capability being asked about. So the set is
      # read once more at the interpreter end, and the call reaches the handler
      # only if the name still resolves to the VERY object the stack judged;
      # otherwise it is refused exactly as a name the set never held. The same
      # identity test refuses a `:tool` some layer swapped in, since the name
      # is the call's own and not the env's.
      #
      # A name held at neither read is unchanged too, and goes to the handler:
      # `Live` refuses it by that same sentence, and a `Mock` answers it canned.
      # "Held at neither" means the env still carries the {Toolset::Unheld}
      # VALUE for this name -- equal by name, since each read mints its own --
      # and not merely some object that answers `held?` false.
      def interpreted(name, env)
        return @handler.call(env) if unchanged?(resolved(name), env.fetch(:tool))

        Toolset::Unheld.new(name).call(nil)
      end

      def unchanged?(fresh, judged) = fresh.equal?(judged) || (!fresh.held? && fresh == judged)

      # One read of the set, so a live toolset moving under a `/mode` flip
      # cannot answer "held" to one question and raise on the next.
      def resolved(name)
        @toolset.fetch(name)
      rescue Toolset::UnknownTool
        Toolset::Unheld.new(name)
      end
    end
  end
end
