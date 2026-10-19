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
      # The worst density {Bounds::RESULT_BYTES} records, digit-heavy text, on
      # purpose: a bound that guesses wrong should withhold, not overfill.
      BYTES_PER_TOKEN = 1.31

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
        def self.for = self
        def self.call(blocks, _calls) = blocks
      end

      NONE = Unbounded

      # The window less the turn that made the calls, its reply and the
      # reserve for the next reply, in bytes.
      #
      # @return [RoundBudget]
      def self.window
        new(:window) do |window:, usage:, reserve:|
          room = window - usage.total_input_tokens - usage.output_tokens - reserve
          Limit.new(bytes: [(room * BYTES_PER_TOKEN).floor, 0].max, scope: "window #{window} tokens")
        end
      end

      # Twice the per-result ceiling, whatever the window.
      #
      # @return [RoundBudget]
      def self.static = new(:static) { |**| Limit.new(bytes: 2 * Bounds::RESULT_BYTES, scope: "static") }

      # @param basis [Symbol] the name the record gives this policy
      # @yieldparam window [Integer] the context window in tokens
      # @yieldparam usage [Usage] the turn that made the calls
      # @yieldparam reserve [Integer] the tokens held back for the next reply
      # @yieldreturn [Limit]
      def initialize(basis, &limit)
        @basis = -basis.to_s
        @limit = limit
        freeze
      end

      # The room is a block because only a real budget needs it, and working it
      # out can raise.
      #
      # @yieldreturn [Hash] `window:` in tokens, `usage:` of the turn that made
      #   the calls, `reserve:` in tokens held back for the next reply, and
      #   `head:`, that turn's digest, which the record names because a provider
      #   may reuse call ids round after round
      # @return [Round] this round's budget
      def for
        room = yield
        Round.new(@basis, @limit.call(**room.slice(:window, :usage, :reserve)), room[:head])
      end

      # One round's budget.
      class Round
        # @param basis [String] the policy's name
        # @param limit [Limit]
        # @param head [String, nil] the digest of the turn that made the calls
        def initialize(basis, limit, head)
          @basis = basis
          @limit = limit
          @head = head
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
          pass = Pass.new(@limit)
          bounded = blocks.zip(calls).map { |block, call| pass.answer(block, call) }
          yield pass.record(basis: @basis, head: @head) if block_given? && pass.bounded?
          bounded
        end
      end

      # One walk over a round's results. Mutable on purpose, and private to
      # {Round#call}: an accumulator, never shared past the walk.
      class Pass
        def initialize(limit)
          @limit = limit
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
          return deduplicate(block, call, @seen.fetch(digest)) if @seen.key?(digest) && shorter?(block, digest)
          return withhold(block, call) if !fits?(block) && call.rerunnable?

          @seen[digest] ||= call.id
          deliver(block, call)
        end

        def bounded? = @fates.values_at(:deduplicated, :withheld).any?(&:any?)

        def record(basis:, head:) = Telemetry::RoundBounded.new(head:, basis:, budget: @limit.bytes, **@fates)

        private

        # Once one result is withheld the round has reached its budget, so a
        # smaller one after it is withheld too, rather than delivered past it.
        def fits?(block) = !@reached && @spent + size(block) <= @limit.bytes

        def shorter?(block, digest) = reference(@seen.fetch(digest)).bytesize < size(block)

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
