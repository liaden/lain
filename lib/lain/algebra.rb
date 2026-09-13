# frozen_string_literal: true

module Lain
  # The vocabulary lain uses to say, in `lib/`, which of its operations are
  # which algebraic structures -- and which deliberately are not.
  #
  # == Why a declaration rather than a comment
  #
  # "Usage is a commutative monoid" used to be evidenced by a `#+` method, a
  # `ZERO` constant and an `include_examples` call in a spec. A declaration puts
  # the structure where the structure lives and makes the set of claims
  # *enumerable*, which is what lets one spec walk the registry and hold every
  # claim to its laws.
  #
  # == Why per-operation and not per-class
  #
  # {Timeline} has three meet-ish operations and only two of them are
  # semilattices: `#meet` and `#dominator_meet` obey the laws, while
  # `#causal_meets` does not -- a criss-cross fan-in leaves incomparable maximal
  # common ancestors, so there is no unique greatest lower bound. `include
  # MeetSemilattice` on the class would be a lie. For five of the six modules,
  # including one grants the *vocabulary* and asserts nothing: `is_a?` is NOT
  # the classification, the registry is. {Elementwise} is the exception.
  #
  # == Why every structure also has a refutation
  #
  # A negative that lives only in a code comment rots silently. So a refutation
  # is a first-class entry with a mandatory reason, in a form a spec can walk,
  # and an unexplained one is refused.
  #
  # == Why every verb asks the latch first
  #
  # Every verb opens with {Registry#refuse_sealed}, uniformly, so "a claim is a
  # load-time move" is one rule a reader checks by reading. {Elementwise} is the
  # one with something to lose -- it generates a method before it files -- but a
  # family of verbs where only some carry the guard invites the next verb to be
  # the one that forgets. ({Elementwise.not_elementwise} files nothing on any
  # registry: it always refuses, because a refutation of an operation the
  # includer also declares is a contradiction.)
  #
  # The modules are stateless -- class-level verbs and, for {Elementwise} and
  # {Pure}, instance behavior, never an ivar -- so including one cannot disturb
  # an includer's deep freeze or its Ractor shareability.
  module Algebra
    # The structures lain names, and the whole list. Fixed on purpose: group,
    # ring, functor and category are absent because nothing here consumes them,
    # and an unnamed structure fails loudly against this list rather than
    # quietly joining it -- the same shape as
    # {Isolation::Services::Builder::VERBS}.
    STRUCTURES = %i[monoid commutative_monoid meet_semilattice elementwise pure attenuation].freeze

    # A structure outside {STRUCTURES}. Named per the error-taxonomy
    # convention, beside the registry that raises it.
    class Unknown < Error; end

    # A structure claimed for an operation the class does not answer -- almost
    # always a typo, or a declaration written above the method it names.
    class Unanswered < Error; end

    # The same claim made twice, which would silently shadow the first.
    class Duplicate < Error; end

    # An identity handed over as a bare Proc or Method. See {Algebra.later}.
    class Unwrapped < Error; end

    # A generated operation that would overwrite one the class wrote itself.
    class Occupied < Error; end

    # A claim filed after the registry closed. Every claim lain makes is made
    # by a class body while `lib/` loads, so a later one is not a declaration
    # at all -- it is a runtime mutation of process-global state that a whole
    # suite reads. See {Registry#seal}.
    class Sealed < Error; end

    # A unit that cannot be named where its declaration is written, deferred to
    # first read.
    #
    # Laziness is unavoidable -- {Context::Combinator}'s unit is
    # {Context::Identity}, an INSTANCE built after the class body closes -- but
    # *inferring* it is not. Both duck tests fail on real units here:
    # `respond_to?(:call)` would invoke Context::Identity, which answers
    # `#call(messages)`, and an arity-0 rule would invoke a unit that
    # legitimately is a thunk while silently storing a mis-shaped
    # `->(x) { ... }` as the unit itself. An explicit wrapper is what lets a
    # bare Proc be refused outright.
    Later = Data.define(:block) do
      def call = block.call
    end

    # Wrap a unit that cannot be named yet:
    # `identity: Algebra.later { Context::Identity }`.
    def self.later(&block) = Later.new(block:)

    # Does `subject` answer `operation` at all? `method_defined?` covers public
    # and protected only, so private is asked separately: a per-element map or a
    # helper meet is legitimately private, and "does this class answer the
    # operation?" must not quietly become "is the operation public?".
    def self.answers?(subject, operation)
      subject.method_defined?(operation) || subject.private_method_defined?(operation)
    end

    # One structure on one operation of one class. Four fields are
    # structure-specific and nil everywhere else: what evidence a claim carries
    # depends on what it claims.
    #
    # * +identity+   the unit, for +:monoid+ and +:commutative_monoid+.
    # * +bottom+     a short PROSE description, for +:meet_semilattice+.
    # * +analysis+   the whole-span method an elementwise map is relative to.
    # * +dual+       the operation an +:attenuation+ states the same restriction
    #   through from the other side -- `except` to `only`.
    # * +implied_by+ the verb that filed this claim without the author writing
    #   it: `commutative_monoid` files a `:monoid` declaration too, and an error
    #   about that entry must never read as a line nobody typed.
    Declaration = Data.define(:subject, :operation, :structure, :identity_source, :bottom, :analysis,
                              :dual, :implied_by) do
      def initialize(identity_source: nil, bottom: nil, analysis: nil, dual: nil, implied_by: nil, **) = super

      # The unit, resolved on read. A lazy one is re-invoked every time -- a
      # frozen Data has nowhere to memoize -- so a walk should read it once per
      # declaration rather than once per property.
      def identity = identity_source.is_a?(Later) ? identity_source.call : identity_source

      # Not part of the surface: everything outside reads {#identity}, so no
      # consumer can accidentally hold the wrapper instead of the unit.
      private :identity_source
    end

    # The negative form: this operation is NOT that structure, and here is why.
    Refutation = Data.define(:subject, :operation, :structure, :reason) do
      # Nothing files a refutation implicitly, so both records answer the same
      # question and the error messages need no branch on record type.
      def implied_by = nil
    end

    # Every claim lain makes about its own algebra, in declaration order.
    #
    # Enumerable, and populated at load time by the declarations in `lib/`, so a
    # spec can walk it directly -- no ObjectSpace sweep, no constant walk. That
    # walk is the point: a marker nothing reads is decoration. Then CLOSED, by
    # {#seal}, because the process-wide one is a global a whole suite reads and
    # a claim filed after loading mutates it rather than describing `lib/`.
    class Registry
      include Enumerable

      def initialize
        @entries = []
      end

      def each(&block) = @entries.each(&block)

      def declarations = grep(Declaration)

      def refutations = grep(Refutation)

      # Every claim about one class, whichever structure and whichever sign.
      # Note that one `commutative_monoid` line answers with TWO declarations.
      def about(subject) = select { |entry| entry.subject == subject }

      def declares?(subject:, operation:, structure:)
        declarations.any? do |entry|
          entry.subject == subject && entry.operation == operation.to_sym && entry.structure == structure
        end
      end

      def declare(subject:, operation:, structure:, identity: nil, bottom: nil, analysis: nil, dual: nil,
                  implied_by: nil)
        refuse_sealed(subject:, operation:)
        entry = Declaration.new(subject:, operation: operation.to_sym, structure:, identity_source: identity,
                                bottom:, analysis:, dual: dual&.to_sym, implied_by:)
        refuse_unknown(entry)
        refuse_unwrapped(entry, identity)
        commit(entry)
      end

      def refute(subject:, operation:, structure:, reason:)
        refuse_sealed(subject:, operation:)
        entry = Refutation.new(subject:, operation: operation.to_sym, structure:, reason:)
        refuse_unknown(entry)
        refuse_unexplained(entry)
        commit(entry)
      end

      # Close the registry. `lain.rb` calls this on the process-wide one once
      # the last unit has loaded.
      #
      # The freeze IS the seal -- one state with one representation, so
      # {#sealed?} and `frozen?` cannot come to disagree. A bare `.freeze` also
      # reads as sealed, and there {#refuse_sealed} is the whole guarantee.
      #
      # Shallow on purpose: a sealed registry is as frozen as what it was
      # HANDED. Entries are frozen Data, but their fields are the caller's
      # objects -- identities, and the `bottom:`/`reason:` prose a report
      # prints. Every one in the tree is a frozen literal; freezing an object
      # the registry does not own would reach outside its own state.
      #
      # Idempotent, because sealing states a condition rather than making a
      # change.
      def seal
        @entries.freeze
        freeze
      end

      def sealed? = frozen?

      # Public, and asked by the declaration verbs BEFORE they touch their
      # includer: {Elementwise} generates the whole-span map and only then
      # files, so a refusal arriving from {#declare} alone would leave that
      # method behind on a class whose claim was refused.
      #
      # It takes a subject and an operation rather than an entry, unlike the
      # refusals below it, because a verb asks before there is an entry.
      def refuse_sealed(subject:, operation:)
        return unless sealed?

        raise Sealed, "#{subject} claims ##{operation} after the registry was sealed; every claim lain makes " \
                      "is filed by a class body while `lib/` loads, and the process-wide registry closes " \
                      "there -- pass a `registry:` of your own to declare anywhere else"
      end

      private

      def commit(entry)
        refuse_unanswered(entry)
        refuse_conflict(entry)
        @entries << entry
        entry
      end

      # First, always: the structure name says which vocabulary the rest of the
      # claim belongs to, so nothing else about the claim can be judged until it
      # is known.
      def refuse_unknown(entry)
        return if STRUCTURES.include?(entry.structure)

        raise Unknown, "unknown structure #{entry.structure.inspect} claimed by #{entry.subject}; " \
                       "known structures: #{STRUCTURES.join(", ")}"
      end

      # Proc and Method specifically, and NOT `respond_to?(:call)` -- a real unit
      # may be callable ({Context::Identity} answers `#call(messages)`), while a
      # code object is never one here. So the two shapes that mean "I meant this
      # lazily" are refused, and every domain value passes.
      def refuse_unwrapped(entry, identity)
        return unless identity.is_a?(Proc) || identity.is_a?(Method)

        raise Unwrapped, "#{entry.subject} passes a #{identity.class} as the identity of " \
                         "##{entry.operation}; laziness is spelled `Algebra.later { ... }`, so that a unit " \
                         "which is itself callable can still be passed directly"
      end

      def refuse_unanswered(entry)
        return if Algebra.answers?(entry.subject, entry.operation)

        raise Unanswered, "#{entry.subject} names ##{entry.operation} as a #{entry.structure}, but does not " \
                          "answer ##{entry.operation}; declare a structure after the method that carries it"
      end

      def refuse_unexplained(entry)
        return unless entry.reason.to_s.strip.empty?

        # A refutation with no stated reason, or a bottom with no stated shape. An
        # unexplained negative is worse than none: it tells a later reader that
        # somebody once knew something.
        raise Error, "#{entry.subject} refutes #{entry.structure} on ##{entry.operation} without saying " \
                     "why; an unexplained negative is worse than none"
      end

      # A second entry on the same (class, operation, structure) is always a
      # bug, but which bug depends on its sign: two declarations shadow each
      # other, while a declaration facing a refutation is the codebase asserting
      # a law and its negation at once. Both refuse; they differ in what they
      # are called, because the fix differs.
      def refuse_conflict(entry)
        clash = find { |existing| claim(existing) == claim(entry) }
        return if clash.nil?
        raise Duplicate, shadowed(clash, entry) if clash.instance_of?(entry.class)

        # One operation both declared and refuted for the same structure.
        raise Error, contradicted(clash, entry)
      end

      def shadowed(clash, entry)
        "#{entry.subject} claims #{entry.structure} on ##{entry.operation} twice " \
          "(#{origin(clash)}, then #{origin(entry)}); the second would silently shadow the first"
      end

      def contradicted(clash, entry)
        "#{entry.subject} both declares and refutes #{entry.structure} on ##{entry.operation} " \
          "(#{origin(clash)}, then #{origin(entry)}); one of the two is wrong"
      end

      # Names how a claim got filed, so an author who wrote `commutative_monoid`
      # once is never told they wrote `monoid` twice.
      def origin(entry) = entry.implied_by.nil? ? "written directly" : "filed implicitly by #{entry.implied_by}"

      def claim(entry) = [entry.subject, entry.operation, entry.structure]
    end

    # The process-wide registry the law walk enumerates. Module state,
    # deliberately and in exactly one place: declarations are made by class
    # bodies as they load, so there is nowhere earlier to hold them. Every verb
    # takes an injectable `registry:` so a spec can declare against a scratch
    # one -- an injected registry is nobody else's, so nothing seals it.
    def self.registry = @registry ||= Registry.new
  end
end

# After the module body: the property modules call Algebra.registry and raise
# the errors named above.
require_relative "algebra/monoid"
require_relative "algebra/commutative_monoid"
require_relative "algebra/meet_semilattice"
require_relative "algebra/elementwise"
require_relative "algebra/pure"
require_relative "algebra/attenuation"
