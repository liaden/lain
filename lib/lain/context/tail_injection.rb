# frozen_string_literal: true

module Lain
  class Context
    # The shared body of the two combinators that inject blocks into the tail of
    # the last user message: {Recall} and {Reminder}. Both had built the same
    # `rest + [{ "role" => ..., "content" => last["content"] + blocks }]` by
    # hand -- the primitive-obsession duplication the review circled. Named once
    # here; a combinator that has already decided it wants to append (its own
    # guards passed) calls {#append_to_last}.
    #
    # Purity is structural: `messages[0..-2]` and `last["content"] + blocks`
    # both allocate fresh, so no input array or hash is mutated.
    module TailInjection
      private

      def append_to_last(messages, blocks)
        last = messages.last
        messages[0..-2] + [{ "role" => last["role"], "content" => last["content"] + blocks }]
      end
    end
  end
end
