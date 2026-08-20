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
    # It depends on three MESSAGES rather than on an includer's ivars --
    # `#resolved_endpoint`, `#queue_for_capacity?` and `#wait_journal` -- so a
    # provider that resolves its endpoint differently (Ollama borrows
    # {Ollama::Transport::DEFAULT_API_BASE}; Anthropic restates a vendored
    # literal it has no constant for) satisfies the same duck without this
    # knowing how.
    #
    # {Admission#enter} and {Admission#try_enter} are called directly rather than
    # asking the gate to choose between them, deliberately: those two are the
    # whole of its entry surface, and {Admission::Journal} wraps exactly them.
    # A third method here would be one more thing a decorator had to learn.
    #
    # == The journal is wrapped HERE, and that placement is the whole design
    #
    # {Admission::Journal} shipped written and spec'd and CONSTRUCTED NOWHERE,
    # and the reason it never found a home is a lifetime mismatch:
    # {Admission.for} memoises one gate per endpoint for the life of the
    # PROCESS, while a journal belongs to one SESSION. Wrapping inside
    # {Admission.build} would let whichever session resolved an endpoint first
    # own every later caller's records, so the decorator is applied per call,
    # here, where both halves are in scope. Two sessions sharing one memoised
    # gate then journal independently, and the gate never learns a journal
    # exists.
    module Admitted
      private

      # Runs `block` inside a slot on this provider's endpoint, journaling the
      # wait if there was one.
      #
      # A refusal RAISES rather than answering nil, because `#complete` owes its
      # caller a {Response} or an exception and there is no third answer. {Busy}
      # is a {Lain::Error}, so {Oracle::Eager}'s task-boundary rescue
      # (`oracle/eager.rb:78`) contains it into exactly the skipped summary open
      # decision 4 asks for: nothing held, nothing journaled, the digest spent.
      # That is also why the unwilling arm's own refusal below journals nothing:
      # it is reached through `#try_enter`, which never queued, and a skip is
      # not a wait.
      #
      # THE DECORATOR IS BUILT BEFORE THE BRANCH, DELIBERATELY -- do not hoist it
      # into the queueing arm. The eager arm therefore allocates a wrapper it can
      # never journal through, which is one small object per HTTP round trip and
      # is the price of the wrap staying per-call. Moving the construction to
      # where it is "needed" means moving it out of `#admitted`, and the only
      # place left is the memoised {Admission.for} -- which is the lifetime bug
      # this file's header exists to explain: a process-global gate would then
      # own the first session's journal forever.
      #
      # @return the block's value
      # @raise [Admission::Busy] when the endpoint is busy -- at the deadline for
      #   a caller that queues, immediately for one that does not
      def admitted(&block)
        gate = Admission::Journal.new(admission: Admission.for(endpoint: resolved_endpoint),
                                      journal: wait_journal)
        return gate.enter(&block) if queue_for_capacity?

        answer = gate.try_enter(&block)
        return answer unless answer.equal?(Admission::REFUSED)

        raise Admission::Busy, "#{resolved_endpoint} is busy: this caller does not queue for capacity"
      end
    end
  end
end
