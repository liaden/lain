# frozen_string_literal: true

RSpec.describe Lain::Tool::Input do
  let(:shell_input) do
    Class.new(described_class) do
      field :command, :string, description: "Command to run", required: true
      field :timeout, :integer, description: "Seconds before the child is killed"
      field :shell, :string, description: "Which shell"

      validates :command, length: { maximum: 8192 }
      validates :timeout, numericality: { greater_than: 0, less_than_or_equal_to: 600 }, allow_nil: true
      validates :shell, inclusion: { in: %w[bash sh zsh] }, allow_nil: true
    end
  end

  # One declaration feeds both the wire schema and the local check, so they cannot
  # drift. Same reasoning as Canonical serving hashing and cache stability at once.
  describe ".to_json_schema" do
    subject(:schema) { shell_input.to_json_schema }

    it "is a closed object" do
      expect(schema["type"]).to eq("object")
      expect(schema["additionalProperties"]).to be(false)
    end

    it "lists only the required fields" do
      expect(schema["required"]).to eq(["command"])
    end

    it "carries the model-facing description, which is the lever on call accuracy" do
      expect(schema["properties"]["command"]["description"]).to eq("Command to run")
    end

    it "maps Ruby types to JSON types" do
      expect(schema["properties"]["timeout"]["type"]).to eq("integer")
      expect(schema["properties"]["command"]["type"]).to eq("string")
    end

    it "derives maxLength from a length validator" do
      expect(schema["properties"]["command"]["maxLength"]).to eq(8192)
    end

    it "derives bounds from a numericality validator" do
      expect(schema["properties"]["timeout"]).to include("maximum" => 600, "exclusiveMinimum" => 0)
    end

    it "derives an enum from an inclusion validator" do
      expect(schema["properties"]["shell"]["enum"]).to eq(%w[bash sh zsh])
    end
  end

  describe ".build" do
    it "coerces types, so 30 and \"30\" are the same integer" do
      expect(shell_input.build({ "command" => "ls", "timeout" => "30" }).timeout).to eq(30)
    end

    it "accepts Symbol keys as readily as String keys" do
      expect(shell_input.build({ command: "ls" }).command).to eq("ls")
    end

    # A tool call naming a field we do not have is a misunderstanding worth
    # surfacing, not something to silently drop.
    it "rejects an unknown key" do
      expect { shell_input.build({ "nope" => 1 }) }.to raise_error(Lain::Tool::InvalidInput)
    end

    it "exposes the checked fields as a Hash" do
      expect(shell_input.build({ "command" => "ls" }).to_h)
        .to eq({ "command" => "ls", "timeout" => nil, "shell" => nil })
    end
  end

  describe "validation" do
    it "reports every failure at once" do
      model = shell_input.build({ "command" => "", "timeout" => 9999 })
      model.valid?
      expect(model.errors.full_messages)
        .to contain_exactly("Command can't be blank", "Timeout must be less than or equal to 600")
    end

    # Input classes are frequently anonymous. ActiveModel::Naming raises without a
    # name -- and an error path that itself raises is worse than no error path.
    it "produces messages even for an anonymous class" do
      expect { shell_input.build({ "command" => "" }).tap(&:valid?).errors.full_messages }
        .not_to raise_error
    end
  end

  # `presence: true` rejects `false`, which is virtually never what "required"
  # means for a flag.
  describe "a required boolean" do
    let(:flag_input) do
      Class.new(described_class) { field :force, :boolean, description: "Overwrite", required: true }
    end

    it "accepts false" do
      expect(flag_input.build({ "force" => false })).to be_valid
    end

    it "rejects nil" do
      expect(flag_input.build({})).not_to be_valid
    end

    it "does not leak its presence check into the schema as an enum" do
      expect(flag_input.to_json_schema["properties"]["force"]).not_to have_key("enum")
    end
  end
end

RSpec.describe "a Tool declaring an input_model" do
  let(:tool_class) do
    input = Class.new(Lain::Tool::Input) do
      field :path, :string, description: "File to read", required: true
      field :limit, :integer, description: "Maximum lines"
    end

    Class.new(Lain::Tool) do
      input_model input
      def name = "read_file"
      def description = "Reads a file."
      def perform(checked, _context) = Lain::Tool::Result.ok("#{checked.path}:#{checked.limit.inspect}")
    end
  end

  subject(:tool) { tool_class.new }

  it "derives #input_schema from the model" do
    expect(tool.input_schema["properties"].keys).to eq(%w[path limit])
    expect(tool.input_schema["required"]).to eq(["path"])
  end

  it "hands #perform a coerced Input rather than a raw Hash" do
    expect(tool.call({ "path" => "a.rb", "limit" => "5" }).content).to eq("a.rb:5")
  end

  it "raises InvalidInput when the model rejects the call" do
    expect { tool.call({ "limit" => 5 }) }.to raise_error(Lain::Tool::InvalidInput, /can't be blank/)
  end

  # A tool with no input_model keeps the raw-Hash path, so nothing existing breaks.
  it "leaves raw-schema tools alone" do
    raw = Class.new(Lain::Tool) do
      def name = "nullary"
      def description = "Takes nothing."
      def perform(input, _context) = Lain::Tool::Result.ok(input.class.name)
    end
    expect(raw.new.call({}).content).to eq("Hash")
  end
end
