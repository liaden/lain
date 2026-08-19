# frozen_string_literal: true

module Lain
  class Provider
    # Taking a round trip through the RESOLVED ENDPOINT's {Admission}, for a
    # provider that knows which endpoint it talks to.
    #
    # It exists because two arms needed the identical eight lines, and the second
    # copy is where a policy starts to drift. The split it encodes is the one
    # {Admission}'s header argues for: CAPACITY IS A PROPERTY OF THE SERVER and
    # lives in the gate, while WILLINGNESS TO WAIT IS A PROPERTY OF THE CALLER
    # and arrives as a constructor keyword. This module is only the join.
    #
    # It depends on two MESSAGES rather than on an includer's ivars --
    # `#resolved_endpoint` and `#queue_for_capacity?` -- so a provider that
    # resolves its endpoint differently (Ollama borrows
    # {Ollama::Transport::DEFAULT_API_BASE}; Anthropic restates a vendored
    # literal it has no constant for) satisfies the same duck without this
    # knowing how.
    #
    # {Admission#enter} and {Admission#try_enter} are called directly rather than
    # asking the gate to choose between them, deliberately: those two are the
    # whole of its entry surface, and T3's journalling decorator wraps exactly
    # them. A third method here would be one more thing a decorator had to learn.
    module Admitted
      private

      # Runs `block` inside a slot on this provider's endpoint.
      #
      # A refusal RAISES rather than answering nil, because `#complete` owes its
      # caller a {Response} or an exception and there is no third answer. {Busy}
      # is a {Lain::Error}, so {Oracle::Eager}'s task-boundary rescue
      # (`oracle/eager.rb:78`) contains it into exactly the skipped summary open
      # decision 4 asks for: nothing held, nothing journaled, the digest spent.
      #
      # @return the block's value
      # @raise [Admission::Busy] when the endpoint is busy -- at the deadline for
      #   a caller that queues, immediately for one that does not
      def admitted(&block)
        gate = Admission.for(endpoint: resolved_endpoint)
        return gate.enter(&block) if queue_for_capacity?

        answer = gate.try_enter(&block)
        return answer unless answer.equal?(Admission::REFUSED)

        raise Admission::Busy, "#{resolved_endpoint} is busy: this caller does not queue for capacity"
      end
    end
  end
end
