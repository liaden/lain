# frozen_string_literal: true

module Lain
  class Provider
    # Taking a round trip through the RESOLVED ENDPOINT's {Admission}, for a
    # provider that knows which endpoint it talks to.
    #
    # It encodes the split {Admission}'s header argues for: CAPACITY IS A
    # PROPERTY OF THE SERVER and lives in the gate, while WILLINGNESS TO WAIT IS
    # A PROPERTY OF THE CALLER and arrives as a constructor keyword. This module
    # is only the join.
    #
    # It depends on four MESSAGES rather than on an includer's ivars, so a
    # provider that resolves its endpoint differently satisfies the same duck
    # without this knowing how. {Admission#enter} and {Admission#try_enter} are
    # called directly rather than asking the gate to choose: those two are the
    # whole of its entry surface, and {Admission::Journal} wraps exactly them.
    #
    # == The journal is wrapped HERE, and that placement is the whole design
    #
    # A lifetime mismatch: {Admission.for} memoises one gate per endpoint for
    # the life of the PROCESS, while a journal belongs to one SESSION. Wrapping
    # inside {Admission.build} would let whichever session resolved an endpoint
    # first own every later caller's records, so the decorator is applied per
    # call, here, where both halves are in scope.
    module Admitted
      # {Provider#admission_endpoint}, answered from the includer's own
      # `resolved_endpoint` -- "the endpoint THIS provider will really talk to,
      # which is the only honest key". Published rather than that hook, because
      # the hook is how an includer resolves one and this is what the resolution
      # is FOR: {#admitted} keys the gate on this very reading, so a caller
      # deriving anything from where a run's models are served is holding the
      # string the gate holds, by construction rather than by coincidence.
      def admission_endpoint = resolved_endpoint

      private

      # What this provider knows its server's concurrent capacity to be, when
      # {Admission::Endpoint.local?} cannot work it out -- an Ollama Cloud plan
      # permits 1, 3 or 10 concurrent models, and none of that is inferable from
      # the address.
      #
      # nil is the default because most endpoints are classified correctly by
      # {Admission::Endpoint.local?}; only a provider that would otherwise be
      # misclassified overrides it. Asked per round trip, which costs nothing:
      # {Admission.for} pins the first declaration an endpoint sees.
      # @return [Integer, nil]
      def admission_width = nil

      # Runs `block` inside a slot on this provider's endpoint, journaling the
      # wait if there was one.
      #
      # A refusal RAISES rather than answering nil, because `#complete` owes its
      # caller a {Response} or an exception and there is no third answer. {Busy}
      # is a {Lain::Error}, so {Oracle::Eager}'s task-boundary rescue contains it
      # into a skipped summary. The unwilling arm journals nothing because it
      # reached `#try_enter`, which never queued, and a skip is not a wait.
      #
      # THE DECORATOR IS BUILT BEFORE THE BRANCH, DELIBERATELY -- do not hoist
      # it into the queueing arm. The eager arm therefore allocates a wrapper it
      # can never journal through, one small object per round trip, and that is
      # the price of the wrap staying per-call: the only place left to move the
      # construction to is the memoised {Admission.for}, which is the lifetime
      # bug this file's header exists to explain.
      #
      # @return the block's value
      # @raise [Admission::Busy] when the endpoint is busy -- at the deadline for
      #   a caller that queues, immediately for one that does not
      def admitted(&block)
        gate = Admission::Journal.new(admission: Admission.for(endpoint: admission_endpoint, width: admission_width),
                                      journal: wait_journal)
        return gate.enter(&block) if queue_for_capacity?

        answer = gate.try_enter(&block)
        return answer unless answer.equal?(Admission::REFUSED)

        raise Admission::Busy, "#{admission_endpoint} is busy: this caller does not queue for capacity"
      end
    end
  end
end
