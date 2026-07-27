# frozen_string_literal: true

RSpec.describe Lain::Algebra do
  # Every toy declares into a SCRATCH registry rather than the process-wide
  # one. Lain's real declarations live in `Algebra.registry`, and the law walk
  # (algebra_laws_spec.rb) runs a property-test group over everything it finds
  # there -- a class invented three lines above an expectation must never turn
  # up in that walk. The injectable `registry:` keyword is what makes that
  # separation possible without the spec reaching into module state.
  let(:registry) { Lain::Algebra::Registry.new }

  describe "the process-wide registry" do
    it "is one Registry, memoized, so a declaration made at load time is still there at run time" do
      expect(described_class.registry).to be_a(Lain::Algebra::Registry).and be(described_class.registry)
    end

    it "is enumerable without ObjectSpace or a constant walk" do
      expect(registry).to be_a(Enumerable)
    end
  end

  describe "a declaration" do
    it "names the declaring class, the operation, and its identity" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        monoid on: :merge, identity: 0, registry: scratch
      end

      declaration = scratch.declarations.first
      expect([declaration.subject, declaration.operation, declaration.structure, declaration.identity])
        .to eq([klass, :merge, :monoid, 0])
    end

    # Every commutative monoid is a monoid, and the registry says so outright
    # rather than making a walk over it know which structures contain which:
    # `#+` is then held to identity, associativity AND commutativity.
    it "records a commutative monoid as both structures" do
      scratch = registry
      Class.new do
        include Lain::Algebra::CommutativeMonoid

        def +(other) = other
        commutative_monoid on: :+, identity: 0, registry: scratch
      end

      expect(scratch.declarations.map(&:structure)).to eq(%i[monoid commutative_monoid])
    end

    it "marks the implicit filing as implied, and the explicit one as not" do
      scratch = registry
      Class.new do
        include Lain::Algebra::CommutativeMonoid

        def +(other) = other
        commutative_monoid on: :+, identity: 0, registry: scratch
      end

      expect(scratch.declarations.map(&:implied_by)).to eq([:commutative_monoid, nil])
    end

    it "returns what it declared, so the declaration is inspectable where it is made" do
      scratch = registry
      declared = nil
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        declared = monoid on: :merge, identity: 0, registry: scratch
      end

      expect(declared).to be_a(Lain::Algebra::Declaration)
    end

    # A String and a Symbol naming the same method are the same claim, so they
    # must collide rather than filing two entries a walk would run twice.
    it "coerces the operation to a Symbol" do
      scratch = registry
      scratch.declare(subject: String, operation: "+", structure: :monoid, identity: "")

      expect(scratch.declarations.first.operation).to be(:+)
      expect { scratch.declare(subject: String, operation: :+, structure: :monoid, identity: "") }
        .to raise_error(Lain::Algebra::Duplicate)
    end
  end

  # An identity that cannot be named where the declaration is written is
  # wrapped in `Algebra.later`. Nothing is inferred from a value's shape.
  describe "a lazy identity" do
    it "resolves the block on demand, because the unit may not exist when the declaration runs" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        monoid on: :merge, identity: Lain::Algebra.later { :computed_later }, registry: scratch
      end

      expect(scratch.declarations.first.identity).to be(:computed_later)
    end

    # Context::Identity -- the unit of the Context::Combinator monoid -- is
    # itself a Combinator answering `#call(messages)`. Nothing may infer
    # laziness from callability, or the unit gets invoked instead of returned.
    it "hands back a callable identity untouched rather than invoking it" do
      unit = Class.new { def call(messages) = messages }.new
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        monoid on: :merge, identity: unit, registry: scratch
      end

      expect(scratch.declarations.first.identity).to be(unit)
    end

    # The whole point of the wrapper: a unit that legitimately IS a zero-arity
    # callable survives, where arity-sniffing would have invoked it.
    it "hands back a zero-arity callable unit untouched" do
      thunk = -> { :i_am_the_unit }
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        monoid on: :merge, identity: Lain::Algebra.later { thunk }, registry: scratch
      end

      expect(scratch.declarations.first.identity).to be(thunk)
    end

    it "refuses a bare Proc, naming the wrapper" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          def merge(other) = other
          monoid on: :merge, identity: -> { :computed_later }, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unwrapped, /Algebra\.later/)
    end

    # The mis-shaped laziness an arity rule would have stored silently.
    it "refuses a Proc whatever its arity, so typo'd laziness cannot be stored as a value" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          def merge(other) = other
          monoid on: :merge, identity: ->(_x) { :computed_later }, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unwrapped)
    end

    it "refuses a Method object for the same reason" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          def merge(other) = other
          monoid on: :merge, identity: Lain::Usage.method(:zero), registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unwrapped)
    end

    it "re-invokes the block on every read, so a walk reads it once per declaration" do
      calls = 0
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        monoid on: :merge, identity: Lain::Algebra.later { calls += 1 }, registry: scratch
      end
      declaration = scratch.declarations.first
      3.times { declaration.identity }

      expect(calls).to eq(3)
    end

    it "keeps the unresolved source off the public surface" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        monoid on: :merge, identity: 0, registry: scratch
      end

      expect(scratch.declarations.first).not_to respond_to(:identity_source)
    end
  end

  describe "a meet semilattice's bottom" do
    # Prose, not a value. `Algebra.later { Timeline.empty }` mints a fresh Store
    # on every read, so `t.meet(entry.bottom)` would raise CrossStore -- a
    # bottom is relative to a store and there is no one value to record. A
    # String says what it is and cannot be wired in wrongly.
    it "is a short description a reader can use and a consumer cannot" do
      scratch = registry
      Class.new do
        include Lain::Algebra::MeetSemilattice

        def meet(other) = other
        meet_semilattice on: :meet, bottom: "the empty Timeline, per store", registry: scratch
      end

      declaration = scratch.declarations.first
      expect(declaration.bottom).to eq("the empty Timeline, per store")
      expect(declaration.identity).to be_nil
    end

    it "is refused when blank" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::MeetSemilattice

          def meet(other) = other
          meet_semilattice on: :meet, bottom: "  ", registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unexplained, /meet/)
    end

    it "is refused when a value is passed instead of prose" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::MeetSemilattice

          def meet(other) = other
          meet_semilattice on: :meet, bottom: Lain::Timeline.empty, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unexplained, /description/)
    end
  end

  describe "a refutation" do
    it "names the class, the operation, and the stated reason" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::MeetSemilattice

        def causal_meets(other) = [other]
        not_a_meet_semilattice on: :causal_meets,
                               because: "a criss-cross fan-in leaves incomparable maximal common ancestors",
                               registry: scratch
      end

      refutation = scratch.refutations.first
      expect([refutation.subject, refutation.operation, refutation.structure]).to eq([klass, :causal_meets,
                                                                                      :meet_semilattice])
      expect(refutation.reason).to match(/incomparable maximal common ancestors/)
    end

    it "is refused when no reason is stated, because an unexplained negative is worse than none" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          def merge(other) = other
          not_a_monoid on: :merge, because: "   ", registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unexplained, /merge/)
    end

    it "keeps refutations out of the declarations" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        not_a_monoid on: :merge, because: "the operation loses the left operand", registry: scratch
      end

      expect(scratch.declarations).to be_empty
    end

    # Middleware's real shape: a monoid whose order is load-bearing.
    it "lets commutativity be refuted while monoid-ness is declared" do
      scratch = registry
      Class.new do
        include Lain::Algebra::CommutativeMonoid

        def call(other) = other
        monoid on: :call, identity: 0, registry: scratch
        not_a_commutative_monoid on: :call, because: "middleware order is load-bearing", registry: scratch
      end

      expect([scratch.declarations.size, scratch.refutations.size]).to eq([1, 1])
    end
  end

  describe "two operations on one class" do
    it "are declared independently, each with its own bottom" do
      scratch = registry
      Class.new do
        include Lain::Algebra::MeetSemilattice

        def meet(other) = other
        def dominator_meet(other) = other
        meet_semilattice on: :meet, bottom: "the empty Timeline, per store", registry: scratch
        meet_semilattice on: :dominator_meet, bottom: "the empty Timeline, all the way up", registry: scratch
      end

      expect(scratch.declarations.map { |entry| [entry.operation, entry.bottom] })
        .to eq([[:meet, "the empty Timeline, per store"],
                [:dominator_meet, "the empty Timeline, all the way up"]])
    end

    it "let one operation be declared while another is refuted" do
      scratch = registry
      Class.new do
        include Lain::Algebra::MeetSemilattice

        def meet(other) = other
        def causal_meets(other) = [other]
        meet_semilattice on: :meet, bottom: "the empty Timeline, per store", registry: scratch
        not_a_meet_semilattice on: :causal_meets, because: "no unique greatest lower bound", registry: scratch
      end

      expect([scratch.declarations.size, scratch.refutations.size]).to eq([1, 1])
    end
  end

  describe "an operation the class does not answer" do
    it "is refused at load, naming the class and the missing operation" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          monoid on: :merge, identity: 0, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unanswered, /merge/)
    end

    it "is refused for a refutation too" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          not_a_monoid on: :merge, because: "it drops the left operand", registry: scratch
        end
      end.to raise_error(Lain::Algebra::Unanswered, /merge/)
    end

    it "accepts a private operation, which is answered even though it is not public" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid

        def merge(other) = other
        private :merge
        monoid on: :merge, identity: 0, registry: scratch
      end

      expect(scratch.declarations.size).to eq(1)
    end
  end

  describe "a contradiction" do
    it "refuses an operation that is both declared and refuted, naming both" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          def merge(other) = other
          monoid on: :merge, identity: 0, registry: scratch
          not_a_monoid on: :merge, because: "it drops the left operand", registry: scratch
        end
      end.to raise_error(Lain::Algebra::Contradiction, /merge/)
    end

    it "refuses in the other order too" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          def merge(other) = other
          not_a_monoid on: :merge, because: "it drops the left operand", registry: scratch
          monoid on: :merge, identity: 0, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Contradiction, /merge/)
    end

    it "leaves a different structure on the same operation alone" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Monoid
        include Lain::Algebra::MeetSemilattice

        def merge(other) = other
        monoid on: :merge, identity: 0, registry: scratch
        not_a_meet_semilattice on: :merge, because: "merge has no order to be a greatest lower bound in",
                               registry: scratch
      end

      expect([scratch.declarations.size, scratch.refutations.size]).to eq([1, 1])
    end

    # An author who never typed `monoid` must not be told they contradicted a
    # line they did not write.
    it "names the implicit filing when a commutative monoid collides with a refutation" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::CommutativeMonoid

          def call(other) = other
          not_a_monoid on: :call, because: "it loses the left operand", registry: scratch
          commutative_monoid on: :call, identity: 0, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Contradiction, /implicitly by commutative_monoid/)
    end
  end

  describe "a repeated declaration" do
    it "is refused, because a second one would silently shadow the first" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::Monoid

          def merge(other) = other
          monoid on: :merge, identity: 0, registry: scratch
          monoid on: :merge, identity: 1, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Duplicate, /merge/)
    end

    # An author who wrote `monoid` once must not be told they wrote it twice.
    it "names the implicit filing when a commutative monoid collides with a plain one" do
      scratch = registry
      expect do
        Class.new do
          include Lain::Algebra::CommutativeMonoid

          def +(other) = other
          commutative_monoid on: :+, identity: 0, registry: scratch
          monoid on: :+, identity: 0, registry: scratch
        end
      end.to raise_error(Lain::Algebra::Duplicate, /implicitly by commutative_monoid/)
    end
  end

  describe "an unknown structure" do
    it "is refused, naming the structures that are known" do
      expect { registry.declare(subject: String, operation: :+, structure: :ring) }
        .to raise_error(Lain::Algebra::Unknown, /monoid/)
    end

    # The structure name says which vocabulary the rest of the claim belongs
    # to, so nothing else about the claim can be judged until it is known.
    it "is refused ahead of a blank reason" do
      expect { registry.refute(subject: String, operation: :+, structure: :ring, reason: "  ") }
        .to raise_error(Lain::Algebra::Unknown)
    end
  end

  describe "including a property module" do
    it "disturbs neither deep freeze nor Ractor shareability" do
      value = Class.new do
        include Lain::Algebra::Monoid
        include Lain::Algebra::CommutativeMonoid
        include Lain::Algebra::MeetSemilattice
        include Lain::Algebra::Elementwise
        include Lain::Algebra::Pure

        def initialize = freeze
      end.new

      expect(value).to be_deeply_frozen
      expect(value).to be_ractor_shareable
    end

    # For four of the five, the module is a vocabulary and nothing more: a
    # class may include it and file no claim at all, so `is_a?` says only that
    # the verbs were granted. The registry is the classification.
    it "grants a vocabulary without asserting anything, for every module but Elementwise" do
      klass = Class.new { include Lain::Algebra::Monoid }

      expect(klass.new).to be_a(Lain::Algebra::Monoid)
      expect(described_class.registry.about(klass)).to be_empty
    end
  end

  describe Lain::Algebra::Elementwise do
    it "supplies the whole-span map from the per-element one" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Elementwise

        def twice(element) = [element, element]
        elementwise on: :call, each: :twice, registry: scratch
      end

      expect(klass.new.call([1, 2])).to eq([1, 1, 2, 2])
    end

    # DedupeToolCalls#without_stale drops the WHOLE message when its content
    # empties, so the per-element map is M -> [M] and not M -> M.
    it "lets a per-element result be empty, which drops the element" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Elementwise

        def keep_odd(element) = element.odd? ? [element] : []
        elementwise on: :call, each: :keep_odd, registry: scratch
      end

      expect(klass.new.call([1, 2, 3])).to eq([1, 3])
    end

    # DedupeToolCalls and PurgeFailedInputs are elementwise only RELATIVE to a
    # whole-span analysis: both read the entire list (stale ids, failed ids)
    # before mapping one element.
    it "maps each element against a whole-span analysis when one is given" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Elementwise

        def repeated(elements) = elements.tally.select { |_element, count| count > 1 }.keys
        def unless_repeated(element, repeated) = repeated.include?(element) ? [] : [element]
        elementwise on: :call, each: :unless_repeated, given: :repeated, registry: scratch
      end

      expect(klass.new.call([1, 2, 2, 3])).to eq([1, 3])
    end

    it "records the analysis, so 'elementwise given my analysis' is discoverable" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Elementwise

        def repeated(elements) = elements
        def unless_repeated(element, _repeated) = [element]
        elementwise on: :call, each: :unless_repeated, given: :repeated, registry: scratch
      end

      declaration = scratch.declarations.first
      expect([declaration.structure, declaration.operation, declaration.analysis])
        .to eq(%i[elementwise call repeated])
    end

    it "records no analysis when the map is unconditional" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Elementwise

        def twice(element) = [element]
        elementwise on: :call, each: :twice, registry: scratch
      end

      expect(scratch.declarations.first.analysis).to be_nil
    end

    it "reaches a private per-element method, which is where such a helper belongs" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Elementwise

        def twice(element) = [element, element]
        private :twice
        elementwise on: :call, each: :twice, registry: scratch
      end

      expect(klass.new.call([1])).to eq([1, 1])
    end

    describe "checked at load, like every other structure" do
      it "refuses a per-element method the class does not answer" do
        scratch = registry
        expect do
          Class.new do
            include Lain::Algebra::Elementwise

            elementwise on: :call, each: :wthout_stale, registry: scratch
          end
        end.to raise_error(Lain::Algebra::Unanswered, /wthout_stale/)
      end

      it "refuses an analysis method the class does not answer" do
        scratch = registry
        expect do
          Class.new do
            include Lain::Algebra::Elementwise

            def keep(element, _ids) = [element]
            def stale_ids(elements) = elements
            elementwise on: :call, each: :keep, given: :stale_idz, registry: scratch
          end
        end.to raise_error(Lain::Algebra::Unanswered, /stale_idz/)
      end

      it "files nothing and defines nothing when it refuses" do
        scratch = registry
        klass = Class.new { include Lain::Algebra::Elementwise }
        expect { klass.elementwise on: :call, each: :nonexistent_helper, registry: scratch }
          .to raise_error(Lain::Algebra::Unanswered)

        expect(scratch.declarations).to be_empty
        expect(klass.new).not_to respond_to(:call)
      end
    end

    describe "an operation the class already defines itself" do
      # A4's exact path: DedupeToolCalls has its own #call, and generating over
      # it would delete a working implementation with no warning.
      it "is refused rather than silently replaced" do
        scratch = registry
        expect do
          Class.new do
            include Lain::Algebra::Elementwise

            def call(span) = span.map { |element| element * 100 }
            def twice(element) = [element, element]
            elementwise on: :call, each: :twice, registry: scratch
          end
        end.to raise_error(Lain::Algebra::Occupied, /call/)
      end

      it "is refused for a private definition too" do
        scratch = registry
        expect do
          Class.new do
            include Lain::Algebra::Elementwise

            def call(span) = span
            private :call
            def twice(element) = [element]
            elementwise on: :call, each: :twice, registry: scratch
          end
        end.to raise_error(Lain::Algebra::Occupied)
      end

      # The other half stays true: overriding an INHERITED method is ordinary
      # subclassing, and Context::Combinator#call is inherited by every
      # combinator that will carry this declaration.
      it "silently overrides an inherited one" do
        scratch = registry
        base = Class.new { def call(span) = span }
        klass = Class.new(base) do
          include Lain::Algebra::Elementwise

          def twice(element) = [element, element]
          elementwise on: :call, each: :twice, registry: scratch
        end

        expect(klass.new.call([1])).to eq([1, 1])
      end
    end

    describe "the generated method" do
      # Pinned so A4 meets this here rather than inside a combinator: the
      # generated method takes exactly one positional argument and no block.
      it "takes one argument and no keywords" do
        scratch = registry
        klass = Class.new do
          include Lain::Algebra::Elementwise

          def twice(element) = [element]
          elementwise on: :call, each: :twice, registry: scratch
        end

        expect { klass.new.call([1], mode: :x) }.to raise_error(ArgumentError)
      end

      it "swallows a block rather than forwarding it" do
        scratch = registry
        klass = Class.new do
          include Lain::Algebra::Elementwise

          def twice(element) = [element]
          elementwise on: :call, each: :twice, registry: scratch
        end

        expect(klass.new.call([1]) { raise "forwarded" }).to eq([1])
      end
    end

    # The plan's ruling: Elementwise is STRUCTURAL. The generated method IS the
    # concatenation, so an includer cannot be non-elementwise through that door
    # and `is_a?(Elementwise)` is the classification -- there is no separate
    # label to drift from it. Refuting is therefore an absence, not a verb.
    it "refuses a refutation from an includer, because is_a? already says otherwise" do
      expect do
        Class.new do
          include Lain::Algebra::Elementwise

          def call(messages) = messages
          not_elementwise on: :call, because: "a summary of a span is not a map over it"
        end
      end.to raise_error(Lain::Algebra::Contradiction, /is_a\?/)
    end

    it "leaves the registry as the door for a class that wants the negative recorded" do
      scratch = registry
      klass = Class.new { def call(messages) = messages }
      scratch.refute(subject: klass, operation: :call, structure: :elementwise,
                     reason: "a summary of a span is not a map over it")

      expect(scratch.refutations.first.structure).to be(:elementwise)
      expect(klass.new).not_to be_a(Lain::Algebra::Elementwise)
    end
  end

  describe Lain::Algebra::Pure do
    # One notion, not two: `pure on:` classifies an operation and `#pure?`
    # answers for an operation, so a class with a pure #call and an impure
    # #reload gives two different answers rather than one wrong one.
    it "answers for the operation that was claimed, and only that one" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Pure

        def initialize = freeze
        def call(path) = path
        def reload(path) = File.read(path)
        pure on: :call, registry: scratch
        not_pure on: :reload, because: "it reads the filesystem", registry: scratch
      end
      value = klass.new

      expect(value.pure?(:call, registry: scratch)).to be(true)
      expect(value.pure?(:reload, registry: scratch)).to be(false)
    end

    it "holds no collaborators, constructs with no arguments, and is shareable" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Pure

        def initialize = freeze
        def call(messages) = messages
        pure on: :call, registry: scratch
      end
      value = klass.new

      expect(value.pure?(:call, registry: scratch)).to be(true)
      expect(value).to be_ractor_shareable
    end

    # The base Context::Combinator does not freeze and its subclasses do, so
    # this is the line a downstream compaction Strategy has to meet.
    it "refuses the claim for an unfrozen includer" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Pure

        def call(messages) = messages
        pure on: :call, registry: scratch
      end

      expect(klass.new.pure?(:call, registry: scratch)).to be(false)
    end

    it "refuses the claim for an includer holding a mutable collaborator" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Pure

        def initialize(collaborator)
          @collaborator = collaborator
          freeze
        end

        def call(messages) = @collaborator.call(messages)
        pure on: :call, registry: scratch
      end

      expect(klass.new(->(messages) { messages }).pure?(:call, registry: scratch)).to be(false)
    end

    # Shareability, not "no ivars", is the repo's mechanical statement of "no
    # reachable mutable state" -- a frozen collaborator graph cannot change
    # between calls, which is exactly what re-derivation needs.
    it "allows a deeply frozen collaborator" do
      scratch = registry
      klass = Class.new do
        include Lain::Algebra::Pure

        def initialize
          @name = "x"
          freeze
        end

        def call(messages) = messages
        pure on: :call, registry: scratch
      end

      expect(klass.new.pure?(:call, registry: scratch)).to be(true)
    end

    it "refuses the claim for an operation nobody declared" do
      klass = Class.new do
        include Lain::Algebra::Pure

        def initialize = freeze
        def call(messages) = messages
      end

      expect(klass.new.pure?(:call)).to be(false)
    end

    it "carries a refutation form of its own" do
      scratch = registry
      Class.new do
        include Lain::Algebra::Pure

        def call(messages) = messages
        not_pure on: :call, because: "it reads the Journal to re-derive", registry: scratch
      end

      expect(scratch.refutations.first.structure).to be(:pure)
    end
  end
end
