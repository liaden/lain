# frozen_string_literal: true

module Lain
  class Agent
    # What a run reports THROUGH, as one value: the journal, the three
    # middleware phases, the tool observer, the transition listener, and the
    # per-turn Context source.
    #
    # Those seven travelled as seven keywords plus three Hash reifications above
    # them, each poking at the Hash by key. A Hash three objects reach into by
    # key is the state of an object nobody has named; named, those pokes become
    # readers and {Data#with}.
    #
    # It is NOT the `Wiring` value {Agent#initialize} considered and rejected:
    # that would have grouped the collaborators the loop DRIVES, a different set
    # answering "what does this run talk to".
    #
    # Frozen (it is a Data), which is the mechanical statement that a run's
    # observability cannot be re-wired mid-run. NOT deeply frozen, and it must
    # not pretend to be: a journal is a live sink and {Middleware::Stack} is
    # deliberately mutable, because ordering is Rack's footgun and the order has
    # to stay adjustable. So `Ractor.shareable?` is false here BY CONSTRUCTION
    # -- unlike {Event}, whose deep freeze is a spec'd invariant -- and for the
    # same reason equality is member identity: two separately built defaults are
    # not `==`, because their stacks are not.
    #
    # That is safe because none of this crosses a Ractor and none of it reaches
    # {Canonical}: one value belongs to one Agent for that Agent's life, an
    # Agent is driven from one fiber reactor, and nothing here is ever an
    # argument to a digest ({Arm::Instrument} carries the same caveat). A
    # Ractor-parallel loop would have to make the journal and the stacks
    # shareable first, and that is the change that would revisit this comment.
    Instrumentation = Data.define(:journal, :model_middleware, :tool_middleware, :turn_middleware,
                                  :tool_observer, :transition_listener, :pipeline_source) do
      # Every member's Null, named once, here -- so nothing downstream ever
      # writes `if journal`. The three stacks are built PER VALUE rather than
      # shared from a constant: one shared mutable stack would let a `#use` on
      # one Agent's phase reach every other Agent's.
      def initialize(journal: Channel::Null.instance,
                     model_middleware: Middleware::Stack.new,
                     tool_middleware: Middleware::Stack.new,
                     turn_middleware: Middleware::Stack.new,
                     tool_observer: ToolRunner::Observer::Null.new,
                     transition_listener: TransitionListener::Null,
                     pipeline_source: PipelineSource::Null)
        refuse_explicit_nil(journal:, model_middleware:, tool_middleware:, turn_middleware:,
                            tool_observer:, transition_listener:, pipeline_source:)
        Middleware.settles!(turn_middleware)
        super
      end
    end

    class Instrumentation
      # Reopened rather than continued inside the `Data.define` block: constants
      # and nested classes declared in that block are lexically scoped to the
      # enclosing module, not to the Data class (see Request::SYSTEM_PREFIX).
      BOTH_STYLES = "instrumentation: was passed together with %<legacy>s, which is what it CARRIES -- two " \
                    "answers to one wiring question. Pass the value or the individual keywords, not both."
      private_constant :BOTH_STYLES

      UNKNOWN = "unknown wiring keyword: %<unknown>s. The instrumentation keywords are %<members>s. The " \
                "remaining wiring keywords are %<collaborators>s, and they are named on Agent#initialize " \
                "itself rather than resolved here."
      private_constant :UNKNOWN

      NO_VALUE = "instrumentation: was given as nil. Omit the keyword to take the all-Null default; nil is not " \
                 "an instrumentation, and reading it as one would hide the mistake."
      private_constant :NO_VALUE

      EXPLICIT_NIL = "%<members>s was given as nil. Omit the keyword to take the Null default; nil is not a " \
                     "reporting destination, and reading it as one would hide the mistake."
      private_constant :EXPLICIT_NIL

      # The keyword form of a list of members, so a refusal reads as something a
      # caller can paste back into the call that caused it.
      def self.labelled(keywords) = keywords.map { |keyword| "#{keyword}:" }.join(", ")

      # {Agent}'s two construction styles, reconciled once: a caller hands one
      # of these over WHOLE, or writes the individual keywords and gets one
      # built. Saying both is refused rather than merged, because a merge would
      # have to pick a winner for the member both name, and quietly picking is
      # how a bench arm measures a run nobody configured.
      #
      # The rule is FLAT -- any legacy keyword beside a handed-over value is a
      # clash -- because the value carries all seven members and a Data cannot
      # say which of them a caller actually wrote.
      #
      # @param instrumentation [Instrumentation, Agent::OMITTED] what the caller
      #   wrote, or the marker meaning they wrote nothing
      # @param legacy [Hash] the individual keywords they wrote instead
      def self.resolve(instrumentation, legacy)
        refuse_unknown(legacy.keys)
        return new(**legacy) if OMITTED.equal?(instrumentation)
        raise ArgumentError, NO_VALUE if instrumentation.nil?
        raise ArgumentError, format(BOTH_STYLES, legacy: labelled(legacy.keys)) if legacy.any?

        instrumentation
      end

      # The vocabulary refusal, and the FIRST question asked -- a typo makes
      # every later one meaningless. It is asked here rather than left to
      # `Data`'s own `unknown keyword:` because {Agent} names its collaborator
      # keywords on the signature and sweeps everything else into this resolver:
      # Ruby's bare message would report `providr:` unknown without ever naming
      # `provider:`. That also makes this the ONLY vocabulary an `Agent.new` can
      # trip, which is why {.collaborator_keywords} names the half this resolver
      # does not own -- a second list behind the collaborator keywords would be
      # unreachable.
      def self.refuse_unknown(keywords)
        unknown = keywords - members
        return if unknown.empty?

        raise ArgumentError, format(UNKNOWN, unknown: labelled(unknown), members: labelled(members),
                                             collaborators: labelled(collaborator_keywords))
      end

      # The wiring keywords this resolver does NOT own. Subtracted rather than
      # listed, so a keyword can never appear in both halves of the message.
      def self.collaborator_keywords
        (INGREDIENTS.keys + KEYWORDS) - members
      end

      private

      # An explicit nil is a caller mistake, not a request for the default: the
      # way to take a default is to OMIT the keyword. Loud, because every silent
      # reading is worse -- `pipeline_source: nil` used to be accepted here and
      # crash on the first render, and `journal: nil` would discard the
      # experiment record a caller thought they had asked for.
      def refuse_explicit_nil(members)
        nils = members.select { |_member, value| value.nil? }.keys
        return if nils.empty?

        raise ArgumentError, format(EXPLICIT_NIL, members: Instrumentation.labelled(nils))
      end
    end
  end
end
