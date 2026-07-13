# frozen_string_literal: true

RSpec.describe Lain::Tool do
  # A minimal concrete tool. Its schema requires a string `text`; `#perform`
  # echoes it. Reused across examples that need a working tool.
  let(:echo_class) do
    Class.new(described_class) do
      def name = "echo"
      def description = "echoes the given text"
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [:text] }
      def perform(input, _context) = Lain::Tool::Result.ok(input[:text])
    end
  end

  let(:echo) { echo_class.new }

  describe Lain::Tool::Result do
    it "is a frozen value with equal-by-content semantics" do
      a = described_class.ok("hi")
      b = described_class.ok("hi")
      expect(a).to be_frozen
      expect(a).to eq(b)
    end

    it "makes success and failure explicit rather than inferred" do
      expect(described_class.ok("done")).to have_attributes(is_error: false, ok?: true, error?: false)
      expect(described_class.error("boom")).to have_attributes(is_error: true, ok?: false, error?: true)
    end

    it "coerces a truthy is_error to a strict Boolean" do
      # Downstream compares `is_error == true`; a truthy-but-not-true value there
      # would be a silent miss.
      expect(described_class.new(content: "x", is_error: "yes").is_error).to be(true)
    end

    it "accepts a String or an Array of content blocks, nothing else" do
      expect(described_class.ok("s").content).to eq("s")
      expect(described_class.ok([{ "type" => "text" }]).content).to eq([{ "type" => "text" }])
      expect { described_class.ok(42) }.to raise_error(Lain::Tool::InvalidResult, /String or an Array/)
    end
  end

  describe "the abstract surface" do
    it "requires a name and description" do
      bare = Class.new(described_class).new
      expect { bare.name }.to raise_error(Lain::Tool::NotImplemented, /#name/)
      expect { bare.description }.to raise_error(Lain::Tool::NotImplemented, /#description/)
    end

    it "defaults to a no-argument object schema" do
      nullary = Class.new(described_class) do
        def name = "ping"
        def description = "no args"
        def perform(_input, _context) = Lain::Tool::Result.ok("pong")
      end.new
      expect(nullary.input_schema).to eq(type: :object, properties: {}, required: [])
    end

    it "is strict by default and not parallel-safe by default" do
      expect(echo.strict?).to be(true)
      expect(echo.parallel_safe?).to be(false)
    end

    it "raises if a concrete tool forgot to define #perform" do
      forgetful = Class.new(described_class) do
        def name = "x"
        def description = "y"
      end.new
      expect { forgetful.call({}) }.to raise_error(Lain::Tool::NotImplemented, /#perform/)
    end

    it "rejects a #perform that returns something other than a Result" do
      wrong = Class.new(described_class) do
        def name = "x"
        def description = "y"
        def perform(_input, _context) = "not a result"
      end.new
      expect { wrong.call({}) }.to raise_error(Lain::Tool::InvalidResult, /must return a Tool::Result/)
    end
  end

  describe "#to_schema" do
    it "emits a stable, fully-populated provider-neutral schema" do
      expect(echo.to_schema).to eq(
        "name" => "echo",
        "description" => "echoes the given text",
        "input_schema" => { type: :object, properties: { text: { type: :string } }, required: [:text] },
        "strict" => true
      )
    end
  end

  describe "input validation" do
    it "passes valid input straight through to #perform" do
      expect(echo.call(text: "hello")).to eq(Lain::Tool::Result.ok("hello"))
    end

    it "rejects a missing required key" do
      expect { echo.call({}) }.to raise_error(Lain::Tool::InvalidInput, /text is required/)
    end

    it "rejects a wrong scalar type" do
      expect { echo.call(text: 5) }.to raise_error(Lain::Tool::InvalidInput, /text must be string/)
    end

    it "accepts Symbol- or String-keyed input against a Symbol-keyed schema" do
      # Anthropic parses tool input with symbolize_names: true, but the validator
      # must not care which spelling arrives.
      validated = Class.new(described_class) do
        def name = "v"
        def description = "d"
        def input_schema = { type: :object, properties: { text: { type: :string } }, required: [:text] }
        def perform(_input, _context) = Lain::Tool::Result.ok("validated")
      end.new
      expect(validated.call("text" => "s")).to eq(Lain::Tool::Result.ok("validated"))
    end

    it "distinguishes integer from number, and validates nested objects" do
      nested = Class.new(described_class) do
        def name = "n"
        def description = "d"

        def input_schema
          { type: :object,
            properties: { meta: { type: :object, properties: { count: { type: :integer } }, required: [:count] } },
            required: [:meta] }
        end

        def perform(_input, _context) = Lain::Tool::Result.ok("ok")
      end.new

      expect { nested.call(meta: { count: 1.5 }) }.to raise_error(Lain::Tool::InvalidInput, /count must be integer/)
      expect(nested.call(meta: { count: 3 })).to be_ok
    end

    it "validates array items" do
      lists = Class.new(described_class) do
        def name = "l"
        def description = "d"
        def input_schema = { type: :object, properties: { xs: { type: :array, items: { type: :string } } } }
        def perform(_input, _context) = Lain::Tool::Result.ok("ok")
      end.new
      expect { lists.call(xs: ["a", 2]) }.to raise_error(Lain::Tool::InvalidInput, /xs\[1\] must be string/)
    end
  end

  describe "design-by-contract" do
    # The plan's motivating case: edit_file may only run against a file already
    # read this session -- an invariant bash structurally cannot enforce.
    let(:edit_class) do
      Class.new(described_class) do
        def name = "edit_file"
        def description = "edits a file"
        def input_schema = { type: :object, properties: { path: { type: :string } }, required: [:path] }
        requires("file was read this session") { |input, context| context.fetch(:read).include?(input[:path]) }
        def perform(input, _context) = Lain::Tool::Result.ok("edited #{input[:path]}")
      end
    end

    it "raises ContractViolation when a precondition fails, before #perform runs" do
      expect { edit_class.new.call({ path: "a.rb" }, { read: [] }) }
        .to raise_error(Lain::Tool::ContractViolation, /precondition failed for edit_file: file was read/)
    end

    it "runs normally once the precondition holds" do
      expect(edit_class.new.call({ path: "a.rb" }, { read: ["a.rb"] }))
        .to eq(Lain::Tool::Result.ok("edited a.rb"))
    end

    it "checks postconditions against the produced result" do
      guarded = Class.new(described_class) do
        def name = "g"
        def description = "d"
        ensures("never reports an error") { |_input, _context, result| result.ok? }
        def perform(_input, _context) = Lain::Tool::Result.error("i failed")
      end.new
      expect { guarded.call({}) }.to raise_error(Lain::Tool::ContractViolation, /postcondition failed/)
    end

    it "accumulates inherited contracts rather than overwriting them" do
      base = Class.new(described_class) do
        def name = "base"
        def description = "d"
        requires("base holds") { |_input, context| context[:base] }
        def perform(_input, _context) = Lain::Tool::Result.ok("ok")
      end
      derived = Class.new(base) do
        requires("derived holds") { |_input, context| context[:derived] }
      end

      expect(derived.preconditions.map(&:message)).to eq(["base holds", "derived holds"])
      expect { derived.new.call({}, { base: false, derived: true }) }
        .to raise_error(Lain::Tool::ContractViolation, /base holds/)
    end
  end
end
