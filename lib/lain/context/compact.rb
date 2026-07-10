# frozen_string_literal: true

require_relative "base"
require_relative "../canonical"

module Lain
  class Context
    # Summarizes the head of the message list once it crosses a token
    # threshold, keeping the trailing `keep_last` messages verbatim.
    #
    # Purity forbids calling a live model mid-#render -- that would make dry
    # replay nondeterministic and break the cache-purity constraint Context
    # itself depends on. So the summary is produced by an INJECTED, already
    # pure `summarizer` (a deterministic `#call(dropped_messages) -> String`)
    # rather than by Compact reaching out itself: the same dependency-
    # injection shape as Provider::Mock/Handler::Mock elsewhere in this
    # codebase, chosen because the spec needs it, not because the design
    # anticipated it.
    #
    # The token count is a proxy -- the canonical byte length of the
    # candidate-for-drop messages -- rather than a real tokenizer, which
    # would be one more dependency this pure combinator has no business
    # taking on. It is deterministic, which is the only property #call needs.
    class Compact < Base
      # @param threshold [Integer] byte-length proxy above which the head
      #   gets summarized
      # @param keep_last [Integer] trailing messages that stay verbatim
      # @param summarizer [#call(Array<Hash>) -> String] pure, deterministic
      def initialize(threshold:, keep_last:, summarizer:)
        super()
        @threshold = Integer(threshold)
        @keep_last = Integer(keep_last)
        @summarizer = summarizer
        freeze
      end

      def call(messages)
        return messages if messages.size <= @keep_last

        dropped = messages[0...-@keep_last]
        return messages if Canonical.dump(dropped).bytesize < @threshold

        tail = messages.last(@keep_last)
        summary_message = { "role" => "assistant",
                            "content" => [{ "type" => "text", "text" => @summarizer.call(dropped) }] }
        [summary_message] + tail
      end

      # Nothing. `#requires` is an ENFORCEMENT contract, not a comparison
      # label: Capability::Policy checks each declared capability against
      # `provider.supports?` and, under :strict, raises Provider::Unsupported;
      # under :degrade, journals a degradation. This implementation summarizes
      # entirely client-side via the injected summarizer, so it needs nothing
      # from the provider -- and declaring `:server_compaction` would be
      # actively wrong: on a provider that LACKS native compaction (exactly
      # when you reach for client-side Compact) :strict would raise for a
      # combinator that needs nothing, and :degrade would journal a FALSE
      # degradation. Which comparison arm this is belongs on a separate label,
      # never overloaded onto the enforcement contract.
      def requires
        [].freeze
      end
    end
  end
end
