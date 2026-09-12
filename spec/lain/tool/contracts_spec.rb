# frozen_string_literal: true

# Contracts is design-by-contract for tools: preconditions checked before
# #perform, a violated predicate RAISING (our bug) rather than returning an
# error Result (the world's failure). The motivating case is edit_file's
# read-before-write invariant; this pins the mechanism directly.
RSpec.describe Lain::Tool::Contracts do
  # A tool whose write must be preceded by a read this session -- the read-
  # before-write contract in miniature, checked against the threaded context.
  let(:write_tool_class) do
    Class.new(Lain::Tool) do
      def name = "guarded_write"
      def description = "writes only what was read"
      def input_schema = { type: :object, properties: { path: { type: :string } }, required: [:path] }

      requires("path was never read this session") { |input, context| context.read?(input["path"]) }

      def perform(input, _context) = Lain::Tool::Result.ok("wrote #{input["path"]}")
    end
  end

  let(:tool) { write_tool_class.new }
  let(:session) { Lain::Session.new }

  describe "read-before-write enforcement" do
    it "raises ContractViolation naming the precondition when the path was not read" do
      expect { tool.call({ "path" => "a.txt" }, session) }
        .to raise_error(Lain::Tool::ContractViolation, /precondition failed for guarded_write: path was never read/)
    end

    it "runs #perform once the read is recorded, satisfying the precondition" do
      session.record_read("a.txt")
      expect(tool.call({ "path" => "a.txt" }, session).content).to eq("wrote a.txt")
    end

    it "checks the precondition before #perform, never dispatching on a violation" do
      performed = false
      klass = Class.new(Lain::Tool) do
        define_method(:name) { "peek" }
        def input_schema = { type: :object, properties: {} }
        requires("always false") { |_input, _context| false }
        define_method(:perform) { |_input, _context| performed = true }
      end
      expect { klass.new.call({}, nil) }.to raise_error(Lain::Tool::ContractViolation)
      expect(performed).to be(false)
    end
  end

  describe "composition across the ancestry" do
    it "checks a base-class contract before the subclass's own" do
      order = []
      base = Class.new(Lain::Tool) do
        def input_schema = { type: :object, properties: {} }
        define_method(:name) { "base" }
        # `order << sym` returns the (truthy) array, so the precondition passes.
        requires("base first") { |_i, _c| order << :base }
      end
      sub = Class.new(base) do
        requires("sub second") { |_i, _c| order << :sub }
        def perform(_input, _context) = Lain::Tool::Result.ok("ok")
      end
      sub.new.call({}, nil)
      expect(order).to eq(%i[base sub])
    end

    # Composition is what stops a subclass SILENTLY dropping an invariant it
    # inherited: declaring nothing of its own is not a way out of read-before-
    # write, which is the whole reason contracts are collected along the
    # ancestry rather than read off the class.
    it "holds a subclass to an inherited contract it never restated" do
      sub = Class.new(write_tool_class)

      expect { sub.new.call({ "path" => "a.txt" }, session) }
        .to raise_error(Lain::Tool::ContractViolation, /precondition failed/)
    end
  end

  # Contracts are asked BEFORE the work and nowhere else. A tool that has run
  # already answered with a Result, and a Result says whether it failed -- so an
  # after-the-fact predicate had a whole vocabulary and no invariant to state.
  describe "the vocabulary" do
    it "declares what must hold before the work, and nothing about after" do
      expect(Lain::Tool).to respond_to(:requires)
      expect(Lain::Tool).not_to respond_to(:ensures)
      expect(Lain::Tool).not_to respond_to(:postconditions)
      expect(Lain::Tool).not_to respond_to(:own_postconditions)
    end
  end

  describe "declaration guard" do
    it "refuses a contract with no predicate block" do
      expect do
        Class.new(Lain::Tool) { requires("no block given") }
      end.to raise_error(ArgumentError, /a contract needs a predicate block/)
    end
  end

  # A contract's message could only ever be a constant, so `edit_file` refused a
  # real file by the placeholder word "path". {Lain::Tool::Bounds#message}
  # already interpolates the subject at call time; these give contracts the same
  # capability, and pin that a static message is untouched by it.
  describe "a message that names its subject" do
    let(:naming_tool_class) do
      Class.new(Lain::Tool) do
        def name = "naming"
        def description = "names what it refused"
        def input_schema = { type: :object, properties: { path: { type: :string } }, required: [:path] }

        requires("%<subject>s was never read this session",
                 subject: ->(input, _invocation) { "/abs/#{input["path"]}" }) { |_i, _c| false }

        def perform(_input, _context) = Lain::Tool::Result.ok("never reached")
      end
    end

    it "interpolates the real subject into the violation at call time" do
      expect { naming_tool_class.new.call({ "path" => "a.txt" }, nil) }
        .to raise_error(Lain::Tool::ContractViolation,
                        "precondition failed for naming: /abs/a.txt was never read this session")
    end

    it "resolves the subject as the TOOL, so a private resolver is in reach" do
      klass = Class.new(Lain::Tool) do
        def name = "resolver"
        def input_schema = { type: :object, properties: {} }
        requires("%<subject>s is refused", subject: ->(_i, _c) { resolved }) { |_i, _c| false }
        def perform(_input, _context) = Lain::Tool::Result.ok("never reached")

        private

        def resolved = "/from/the/tool"
      end

      expect { klass.new.call({}, nil) }
        .to raise_error(Lain::Tool::ContractViolation, %r{/from/the/tool is refused})
    end

    # Backward compatibility is what keeps this change small: `requires` has
    # callers beyond edit_file/write_file, and a static message must still read
    # as exactly itself. The `%` is the sharp end -- `format("100% of ...")`
    # reads `% o` as a conversion and RAISES, so routing every message through
    # `format` would turn an ordinary sentence into a crash.
    it "leaves a static message exactly as written, percent signs and all" do
      klass = Class.new(Lain::Tool) do
        def name = "static"
        def input_schema = { type: :object, properties: {} }
        requires("100% of the file must be read") { |_i, _c| false }
        def perform(_input, _context) = Lain::Tool::Result.ok("never reached")
      end

      expect { klass.new.call({}, nil) }
        .to raise_error(Lain::Tool::ContractViolation,
                        "precondition failed for static: 100% of the file must be read")
    end

    # Contracts are kept as data so they are inspectable, and tool_spec reads
    # `preconditions.map(&:message)`. A static contract keeps handing back the
    # String rather than a thunk.
    it "keeps a static contract's message inspectable as a String" do
      klass = Class.new(Lain::Tool) do
        def input_schema = { type: :object, properties: {} }
        requires("plain") { |_i, _c| true }
      end

      expect(klass.preconditions.map(&:message)).to eq(["plain"])
    end

    # A subject supplier whose sentence has nowhere to put it silently drops the
    # path -- the very defect this capability exists to fix, wearing a typo.
    it "refuses a subject supplier the message has no slot for" do
      expect do
        Class.new(Lain::Tool) do
          requires("no slot here", subject: ->(_i, _c) { "x" }) { |_i, _c| true }
        end
      end.to raise_error(ArgumentError, /slot/)
    end
  end

  # Every check below runs at CLASS-DEFINITION time, and that timing is the
  # point: the only code path that reads a message is the REFUSAL path, which a
  # green suite almost never walks and production walks constantly. A defect
  # parked there stays invisible until a model is already being refused.
  describe "the message and its supplier are checked at declaration" do
    # The likelier of the two mismatches, because it is what copying a working
    # declaration and dropping the keyword produces. Left unchecked, the model
    # reads "precondition failed for leaky: %<subject>s was never read this
    # session" -- a raw placeholder exactly where the file's name belongs, which
    # is the defect naming the subject exists to delete.
    it "refuses a slot with no supplier" do
      expect do
        Class.new(Lain::Tool) do
          requires("%<subject>s was never read this session") { |_i, _c| false }
        end
      end.to raise_error(ArgumentError, /needs a subject: supplier/)
    end

    # A slot's PRESENCE says nothing about whether the rest of the template
    # survives `format`. This one declares clean and dies at the first violation
    # with a TypeError -- a refusal turned into a crash.
    it "refuses a template format cannot render" do
      expect do
        Class.new(Lain::Tool) do
          requires("100% of %<subject>s must be read", subject: ->(_i, _c) { "x" }) { |_i, _c| false }
        end
      end.to raise_error(ArgumentError, /must survive format/)
    end

    it "refuses a template naming a slot nothing fills" do
      expect do
        Class.new(Lain::Tool) do
          requires("%<subject>s at %<line>d", subject: ->(_i, _c) { "x" }) { |_i, _c| false }
        end
      end.to raise_error(ArgumentError, /must survive format/)
    end

    # `&` accepts far more than a supplier can actually be: a Symbol converts
    # happily and then calls that method on the INPUT, so `subject: :upcase`
    # declares clean and dies on the refusal path with
    # "undefined method 'upcase' for an instance of Hash". Same
    # declares-clean/dies-in-production shape as the two above.
    it "refuses a supplier that is not callable" do
      expect do
        Class.new(Lain::Tool) do
          requires("%<subject>s was never read", subject: :upcase) { |_i, _c| false }
        end
      end.to raise_error(ArgumentError, /must respond to #call/)
    end

    # A lambda is arity-strict, so one written for a single argument dies at the
    # first violation with a bare "wrong number of arguments" in place of the
    # sentence the model was owed.
    it "refuses an arity-strict supplier that does not take (input, invocation)" do
      expect do
        Class.new(Lain::Tool) do
          requires("%<subject>s is refused", subject: ->(input) { input }) { |_i, _c| false }
        end
      end.to raise_error(ArgumentError, /takes \(input, invocation\)/)
    end

    # A plain proc is arity-tolerant by design, so it is left alone: a constant
    # subject wanting neither argument is a legitimate supplier.
    it "allows a tolerant proc supplier" do
      klass = Class.new(Lain::Tool) do
        def name = "tolerant"
        def input_schema = { type: :object, properties: {} }
        requires("%<subject>s is refused", subject: proc { "a constant subject" }) { |_i, _c| false }
        def perform(_input, _context) = Lain::Tool::Result.ok("never reached")
      end

      expect { klass.new.call({}, nil) }
        .to raise_error(Lain::Tool::ContractViolation,
                        "precondition failed for tolerant: a constant subject is refused")
    end
  end
end
