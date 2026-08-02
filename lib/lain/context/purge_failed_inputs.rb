# frozen_string_literal: true

module Lain
  class Context
    # Reopens the combinators' shared carrier namespace (see prune.rb) to
    # hold PurgeFailedInputs's construction contract beside the class it
    # guards.
    module Guards
      # `turns` is a window WIDTH, consumed as `messages.first(boundary)` /
      # `messages.last(turns)`. A negative value would silently flip that
      # slicing math -- `messages.last(-1)` raises, but the boundary
      # arithmetic upstream would first hand back a boundary larger than
      # `messages.size`, purging turns the caller meant to protect as
      # "recent." Fail loudly at construction instead, matching
      # Guards::Prune's and Guards::CacheBreakpoints's house style.
      class PurgeFailedInputs < Guard
        attribute :turns
        validates :turns, numericality: { greater_than_or_equal_to: 0, message: "must not be negative, got %<value>s" }
      end
    end

    # Redacts a failed tool_use's `input` once it ages out of the trailing
    # `turns:` window, while leaving its answering tool_result (the error
    # text a later turn may still need to reason about) untouched. A large
    # failed input -- the retry that never needed to be replayed -- is
    # exactly the token cost this earns back; the same slicing idiom
    # {Compact} uses (`messages.first(boundary)` / `messages.last(turns)`)
    # keeps "recent" a plain positional window rather than a second concept.
    #
    # `#requires` is the inherited {Combinator} default: this is a pure
    # rewrite of tool_use blocks already in the message list, so it needs
    # nothing from the Provider.
    #
    # Two phases, like {DedupeToolCalls}: an ANALYSIS of the whole list (which
    # tool_use ids failed -- a failure is recorded on the ANSWERING tool_result,
    # so it can only be read off the whole list), then a map over messages
    # against that fixed analysis. Unlike DedupeToolCalls the second phase is
    # NOT elementwise, not even relative to the analysis, and the class files
    # that refutation at the bottom of this body rather than leaving it to a
    # reader to notice. The window is why: `turns:` is a POSITION, so two
    # messages that are `==` receive different images inside a single call when
    # one sits either side of the boundary. An elementwise map is a function of
    # (message, analysis), and a function cannot answer two things for one
    # argument. Nothing here may be re-expressed in terms of tool_use ids to
    # dodge that -- {Grader::ToolCallIndex} treats a repeated id as a wire
    # anomaly to tolerate, never as impossible, and an id-keyed rewrite of this
    # class silently redacts protected content when one shows up.
    class PurgeFailedInputs < Combinator
      def initialize(turns:, protected_patterns: ProtectedPatterns::NONE)
        Guards::PurgeFailedInputs.check!(turns:)

        super()
        @turns = Integer(turns)
        @protected_patterns = protected_patterns
        freeze
      end

      def call(messages)
        return messages if messages.size <= @turns

        boundary = messages.size - @turns
        failed_ids = failed_tool_use_ids(messages)
        aged = messages.first(boundary).map { |message| without_failed_input(message, failed_ids) }
        aged + messages.last(@turns)
      end

      # The analysis, public so a caller can ask what this run would act on
      # without running it. A tool_use's failure is recorded on its ANSWERING
      # tool_result, so the failed set is derived from the whole list -- a
      # tool_use aging out of the window does not imply its tool_result did too.
      #
      # It answers every failed id, not every id this run will redact: the
      # window is positional and so belongs to #call, not here.
      # The `type` test is a raw key read and stays one: {Tool::ResultBlock.wrap}
      # accepts any Hash and checks no type, so a block must be KNOWN a
      # tool_result before it is lensed. Every read AFTER that test goes through
      # the lens, where a tool_result missing `is_error` or `tool_use_id` raises
      # instead of reading as "did not fail" or as a nil identifier.
      def failed_tool_use_ids(messages)
        messages.flat_map { |message| message["content"] }
                .select { |block| block["type"] == "tool_result" }
                .map { |block| Tool::ResultBlock.wrap(block) }
                .select(&:error?)
                .map(&:tool_use_id)
      end

      private

      # The second phase, per message and against the fixed analysis: every
      # aged message has exactly one image, which is what would let a caller
      # journal what was redacted and why. Answers the message itself when
      # nothing changed, so "untouched" is observable as object identity.
      def without_failed_input(message, failed_ids)
        return message unless redactable?(message)

        content = message["content"].map { |block| purge_block(block, failed_ids) }
        content == message["content"] ? message : message.merge("content" => content)
      end

      # Only assistant messages carry tool_use blocks; a tool_result's
      # message (role "user") is exempt, which is precisely how the error text
      # stays put while the input it answers gets redacted.
      #
      # Protection is checked ONCE per message, against the CONTAINING
      # MESSAGE's dump -- the same granularity {Prune} and {Compact} use --
      # rather than per-block: a protected span anywhere in the message
      # (a sibling text block, not just the tool_use's own input) exempts
      # every tool_use the message carries. Asked HERE, beside the message it
      # judges, so a message's fate never depends on another message.
      def redactable?(message)
        message["role"] == "assistant" && !@protected_patterns.protects?(Canonical.dump(message))
      end

      # The redacted image is built from the BLOCK, never from the lens: the
      # lens is a view, and `merge` on it would answer something no longer a
      # Hash where {Canonical} has been promised one.
      def purge_block(block, failed_ids)
        return block unless block["type"] == "tool_use"

        redact = failed_ids.include?(Response::ToolUse.wrap(block).id)
        redact ? block.merge("input" => {}) : block
      end

      # Filed directly rather than through {Algebra::Elementwise}, which refuses
      # to refute an includer -- for a structural property the absence of the
      # module IS the negative, and this is the escape hatch its own doc names
      # for recording one anyway. Below #call, because a refutation is checked
      # against the operation it names exactly like a declaration is.
      Algebra.registry.refute(
        subject: self, operation: :call, structure: :elementwise,
        reason: "the trailing turns: window is positional -- two messages that are == take different " \
                "images inside one call when the boundary falls between them, so no (message, analysis) " \
                "function reproduces #call"
      )
    end
  end
end
