# frozen_string_literal: true

module Lain
  class Context
    # Redacts a failed tool_use's `input` once it ages out of the trailing
    # `turns:` window, while leaving its answering tool_result (the error text a
    # later turn may still need to reason about) untouched. A large failed input
    # -- the retry that never needed to be replayed -- is the token cost this
    # earns back.
    #
    # Two phases, like {DedupeToolCalls}: an ANALYSIS of the whole list (a
    # failure is recorded on the ANSWERING tool_result, so which ids failed can
    # only be read off the whole list), then a map over messages against that
    # fixed analysis. Unlike DedupeToolCalls the second phase is NOT elementwise
    # even relative to the analysis, which the refutation at the bottom of this
    # body states. Nothing here may be re-expressed in terms of tool_use ids to
    # dodge that -- {Grader::ToolCallIndex} treats a repeated id as a wire
    # anomaly to tolerate, never as impossible, and an id-keyed rewrite of this
    # class silently redacts protected content when one shows up.
    class PurgeFailedInputs < Combinator
      include Declarative

      # `turns` is a window WIDTH. A negative value would flip the slicing math
      # -- `messages.last(-1)` raises, but the boundary arithmetic upstream
      # hands back a boundary larger than `messages.size` first, purging turns
      # the caller meant to protect as "recent". Fail loudly at construction.
      declare do
        attribute :turns
        validates :turns, numericality: { greater_than_or_equal_to: 0, message: "must not be negative, got %<value>s" }
      end

      def initialize(turns:, protected_patterns: ProtectedPatterns::NONE)
        self.class.check!(turns:)

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
      # without running it. It answers every failed id, not every id this run
      # will redact: the window is positional and belongs to #call.
      #
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

      # Answers the message itself when nothing changed, so "untouched" is
      # observable as object identity.
      def without_failed_input(message, failed_ids)
        return message unless redactable?(message)

        content = message["content"].map { |block| purge_block(block, failed_ids) }
        content == message["content"] ? message : message.merge("content" => content)
      end

      # A tool_result's message (role "user") is exempt, which is precisely how
      # the error text stays put while the input it answers gets redacted.
      #
      # Protection is checked ONCE per message, against the CONTAINING MESSAGE's
      # dump -- the granularity {Prune} and {Compact} use -- rather than
      # per-block: a protected span anywhere in the message exempts every
      # tool_use it carries. Asked HERE, beside the message it judges, so a
      # message's fate never depends on another message.
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
      # to refute an includer. Below #call, because a refutation is checked
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
