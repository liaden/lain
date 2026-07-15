# frozen_string_literal: true

# Contracts is design-by-contract for tools: preconditions checked before
# #perform, postconditions after, a violated predicate RAISING (our bug) rather
# than returning an error Result (the world's failure). The motivating case is
# edit_file's read-before-write invariant; this pins the mechanism directly.
RSpec.describe Lain::Tool::Contracts do
  # A tool whose write must be preceded by a read this session -- the read-
  # before-write contract in miniature, checked against the threaded context.
  let(:write_tool_class) do
    Class.new(Lain::Tool) do
      def name = "guarded_write"
      def description = "writes only what was read"
      def input_schema = { type: :object, properties: { path: { type: :string } }, required: [:path] }

      requires("path was never read this session") { |input, context| context.read?(input["path"]) }
      ensures("result must be ok") { |_input, _context, result| result.ok? }

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

  describe "postconditions" do
    it "raises ContractViolation when the postcondition fails after #perform" do
      klass = Class.new(Lain::Tool) do
        def name = "bad_post"
        def input_schema = { type: :object, properties: {} }
        ensures("must be an error") { |_input, _context, result| result.error? }
        def perform(_input, _context) = Lain::Tool::Result.ok("fine")
      end
      expect { klass.new.call({}, nil) }
        .to raise_error(Lain::Tool::ContractViolation, /postcondition failed for bad_post/)
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
  end

  describe "declaration guard" do
    it "refuses a contract with no predicate block" do
      expect do
        Class.new(Lain::Tool) { requires("no block given") }
      end.to raise_error(ArgumentError, /a contract needs a predicate block/)
    end
  end
end
