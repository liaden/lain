# frozen_string_literal: true

module Lain
  class Tool
    # What one tool round's results may cost together: the sum {Bounds}' per
    # result ceilings leave open. The Agent holds one policy and asks it for a
    # budget every round, because the room left depends on the turn that made
    # the calls.
    #
    # The bound sits where results are produced because nothing later can
    # rescue the round: a handoff keeps the unanswered round whole, so every
    # `tool_use` keeps its `tool_result`, and a round larger than the window
    # stays larger than the window. Every call is still answered; only what the
    # answer says gets shorter.
    class RoundBudget
      # The second action a withheld result offers, for the tools that have a
      # narrower form of the same call.
      NARROWER = { "read_file" => "narrower with offset and limit" }.freeze
      private_constant :NARROWER

      # One call of the round: its id, and the tool that answered it.
      Call = Data.define(:id, :tool) do
        def rerunnable? = tool.rerunnable?
        def narrower = NARROWER.fetch(tool.name, "narrower")
      end

      # What a round may spend, and the words a refusal names it by.
      Limit = Data.define(:bytes, :scope)

      # No budget: every result delivered, nothing journaled, and the room never
      # asked for, so a window book that cannot name the model costs nothing.
      module Unbounded
        def self.for(**) = self
        def self.call(blocks, _calls) = blocks
      end

      NONE = Unbounded

      # A budget no round reaches, as a number so the record's budget stays an Integer.
      UNLIMITED = Limit.new(bytes: 2**62, scope: "unlimited")

      # The window less the turn that made the calls, its reply and the
      # reserve for the next reply, in bytes.
      #
      # @return [RoundBudget]
      def self.window
        new(:window) do |room|
          left = room.window - room.usage.total_input_tokens - room.usage.output_tokens -
                 ReplyReserve.tokens(window: room.window, ceiling: room.ceiling)
          Limit.new(bytes: [(left * Oracle::Handoff::BYTES_PER_TOKEN).floor, 0].max,
                    scope: "window #{room.window} tokens")
        end
      end

      # Twice the per-result ceiling, whatever the window.
      #
      # @return [RoundBudget]
      def self.static = new(:static) { |_room| Limit.new(bytes: 2 * Bounds::RESULT_BYTES, scope: "static") }

      # Dedup with no budget: the top of the budget order, short of the unbounded
      # policy, which also leaves repeats whole.
      #
      # @return [RoundBudget]
      def self.dedup_only = new(:dedup)

      # @param basis [Symbol] the name the record gives this policy
      # @param dedup [Boolean] whether a repeated result is answered by naming the first
      # @yieldparam room [Room]
      # @yieldreturn [Limit] without a block the budget is {UNLIMITED}
      def initialize(basis, dedup: true, &limit)
        @basis = -basis.to_s
        @dedup = dedup
        @limit = limit
        freeze
      end

      # @return [RoundBudget] the same budget, leaving repeated results whole
      def without_dedup = self.class.new(@basis, dedup: false, &@limit)

      # The room is a block because only a real budget needs it, and working it
      # out can raise (the window of an unnamed model); a policy with no budget
      # never asks, so the head comes apart from it.
      #
      # @param head [String, nil] the digest of the turn that made the calls
      # @yieldreturn [Room]
      # @return [Round] this round's budget
      def for(head:)
        return Round.new(@basis, UNLIMITED, head, dedup: @dedup) if @limit.nil?

        room = yield
        Round.new(@basis, @limit.call(room), head, dedup: @dedup)
      end

      # One round's budget.
      class Round
        # @param basis [String] the policy's name
        # @param limit [Limit]
        # @param head [String, nil] the digest of the turn that made the calls
        # @param dedup [Boolean]
        def initialize(basis, limit, head, dedup: true)
          @basis = basis
          @limit = limit
          @head = head
          @dedup = dedup
          freeze
        end

        # Walks the results in call order, never completion order, so the
        # delivered set is the same however the calls finished.
        #
        # @param blocks [Array<Hash>] the round's tool_result blocks, in call order
        # @param calls [Array<Call>] the calls they answer, in the same order
        # @yieldparam record [Telemetry::RoundBounded] given only when a result
        #   was withheld or deduplicated
        # @return [Array<Hash>] one block per call, in call order
        def call(blocks, calls)
          pass = Pass.new(@limit, dedup: @dedup)
          bounded = blocks.zip(calls).map { |block, call| pass.answer(block, call) }
          yield pass.record(basis: @basis, head: @head) if block_given? && pass.bounded?
          bounded
        end
      end

      # One walk over a round's results. Mutable on purpose, and private to
      # {Round#call}: an accumulator, never shared past the walk.
      class Pass
        def initialize(limit, dedup:)
          @limit = limit
          @dedup = dedup
          @spent = 0
          @reached = false
          @seen = {}
          @fates = { delivered: [], deduplicated: [], withheld: [] }
        end

        # An error result carries no content worth a budget's judgment and is
        # never matched as a duplicate, so its error mark always survives.
        def answer(block, call)
          return deliver(block, call) if block["is_error"]

          digest = Canonical.digest(block["content"])
          return deduplicate(block, call, @seen.fetch(digest)) if duplicate?(block, digest)
          return withhold(block, call) if !fits?(block) && call.rerunnable?

          @seen[digest] ||= call.id
          deliver(block, call)
        end

        def bounded? = @fates.values_at(:deduplicated, :withheld).any?(&:any?)

        def record(basis:, head:) = Telemetry::RoundBounded.new(head:, basis:, budget: @limit.bytes, **@fates)

        private

        # A mask numbers its slots per result, so equal masked bytes can hide different secrets.
        def duplicate?(block, digest) = @dedup && @seen.key?(digest) && !masked?(block["content"])

        def masked?(content)
          Sensitivity::Regions::PLACEHOLDER_SHAPE.match?(content.is_a?(String) ? content : Canonical.dump(content))
        end

        # Once one result is withheld the round has reached its budget, so a
        # smaller one after it is withheld too, rather than delivered past it.
        def fits?(block) = !@reached && @spent + size(block) <= @limit.bytes

        def reference(first) = "same result as call #{first}"

        def size(block)
          content = block["content"]
          content.is_a?(String) ? content.bytesize : Canonical.dump(content).bytesize
        end

        def deliver(block, call)
          @spent += size(block)
          @fates[:delivered] << call.id
          block
        end

        def deduplicate(block, call, first)
          @fates[:deduplicated] << call.id
          block.merge("content" => reference(first))
        end

        def withhold(block, call)
          @reached = true
          @fates[:withheld] << call.id
          block.merge("content" => refusal(call), "is_error" => true)
        end

        def refusal(call)
          actions = Bounds.offer(["re-request it in a later round", call.narrower])
          "not delivered: this round reached its #{@limit.bytes}-byte budget (#{@limit.scope}); " \
            "#{actions.join(", or ")}"
        end
      end
      private_constant :Pass
    end
  end
end
