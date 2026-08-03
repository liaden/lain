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

    # A single rich structural assertion, left deliberately un-split, to show
    # what a failure here looks like now that spec/support/super_diff.rb is
    # wired in. Pre-super_diff, RSpec's stock differ pretty-prints both sides
    # as Hash#inspect STRINGS and diffs those strings char-by-char, so one
    # wrong leaf (say, "maxLength" flipping from 8192 to 100) smears colour
    # across the whole multi-line block. super_diff walks the actual Hash
    # instead and shows only the divergent leaf, e.g.:
    #
    #   {
    #     "type" => "object",
    #     "properties" => {
    #       "command" => {
    #         "type" => "string",
    #         "description" => "Command to run",
    # -       "maxLength" => 8192
    # +       "maxLength" => 100
    #       },
    #       "timeout" => { ... },
    #       "shell" => { ... }
    #     },
    #     "required" => ["command"],
    #     "additionalProperties" => false
    #   }
    #
    # -- exactly the shape a Response content block (also a nested,
    # String-keyed Hash) needs when a spec pins it whole rather than piecemeal.
    it "matches the whole schema shape in one structural assertion" do
      expect(schema).to eq(
        "type" => "object",
        "properties" => {
          "command" => { "type" => "string", "description" => "Command to run", "maxLength" => 8192 },
          "timeout" => {
            "type" => "integer",
            "description" => "Seconds before the child is killed",
            "maximum" => 600,
            "exclusiveMinimum" => 0
          },
          "shell" => { "type" => "string", "description" => "Which shell", "enum" => %w[bash sh zsh] }
        },
        "required" => ["command"],
        "additionalProperties" => false
      )
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

  # shoulda-matchers (spec/support/shoulda_matchers.rb, :rspec + :active_model
  # only) pins the SAME `validates` lines above against its own vocabulary
  # instead of round-tripping through #valid?/#errors -- a handful, to show
  # the payoff without duplicating every case in "validation" above. `type:
  # :model` is what shoulda's RSpec integration keys its `config.include` on
  # (no Rails auto-tagging here, so it has to be explicit); it is only
  # metadata, not a Rails dependency. Delete a `validates` line above and the
  # matching example here goes red with a shoulda-authored message naming
  # exactly what could not be proved.
  #
  # `timeout`'s numericality validator is deliberately NOT converted:
  # `validate_numericality_of` probes with a non-numeric String ("abcd") and
  # expects an "is not a number" error, but ActiveModel::Attributes coerces
  # that String to an Integer (0) before validation ever runs -- coercion the
  # matcher doesn't know about. The manual "reports every failure at once"
  # example above is the honest way to pin that one.
  describe "validations, pinned via shoulda-matchers", type: :model do
    subject { shell_input.new(command: "ls") }

    it { is_expected.to validate_presence_of(:command) }
    it { is_expected.to validate_length_of(:command).is_at_most(8192) }
    it { is_expected.to validate_inclusion_of(:shell).in_array(%w[bash sh zsh]).allow_nil }
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

# An array field is the shape a tool needs when one call carries a LIST --
# `ask_human`'s questions, `todo_write`'s todos. Before this, such a tool
# hand-wrote its JSON Schema and re-did its own validation, and the two drifted.
RSpec.describe "an Input declaring array fields" do
  let(:tag_input) do
    Class.new(Lain::Tool::Input) do
      field :tags, :array, of: :string, description: "Labels to attach"
    end
  end

  let(:person_input) do
    Class.new(Lain::Tool::Input) do
      field :people, :array, description: "Everyone involved" do
        field :name, :string, description: "Their name", required: true
        field :nickname, :string, description: "What they go by"
      end
    end
  end

  let(:tag_values) { %w[a b] }

  let(:enumerated_list) do
    values = tag_values
    Class.new(Lain::Tool::Input) do
      field :tags, :array, of: :string, description: "Labels"
      validates :tags, inclusion: { in: values }
    end
  end

  describe "an array of scalars" do
    subject(:property) { tag_input.to_json_schema["properties"]["tags"] }

    it "is a typed array" do
      expect(property).to eq("type" => "array", "description" => "Labels to attach",
                             "items" => { "type" => "string" })
    end

    it "coerces each element" do
      numbers = Class.new(Lain::Tool::Input) { field :ports, :array, of: :integer, description: "Ports" }
      expect(numbers.build({ "ports" => ["80", 443] }).ports).to eq([80, 443])
    end

    # `Integer("0x1f")` is 31 where ActiveModel casts it to 0. A gate built on
    # Kernel::Integer would admit the element and then store a different number
    # than the one it checked, which is the defect it exists to prevent.
    it "refuses a Ruby integer literal the cast would not agree with" do
      numbers = Class.new(Lain::Tool::Input) { field :ports, :array, of: :integer, description: "Ports" }
      expect { numbers.build({ "ports" => ["0x1f"] }) }
        .to raise_error(Lain::Tool::InvalidInput, /ports\[0\]/)
      expect { numbers.build({ "ports" => ["0b11"] }) }
        .to raise_error(Lain::Tool::InvalidInput, /ports\[0\]/)
    end
  end

  describe "an array of objects" do
    subject(:items) { person_input.to_json_schema["properties"]["people"]["items"] }

    it "is a closed object naming every member, each with its own description" do
      expect(items).to eq(
        "type" => "object",
        "properties" => {
          "name" => { "type" => "string", "description" => "Their name" },
          "nickname" => { "type" => "string", "description" => "What they go by" }
        },
        "required" => ["name"],
        "additionalProperties" => false
      )
    end

    it "keeps member declaration order" do
      expect(items["properties"].keys).to eq(%w[name nickname])
    end

    # The same guarantee `field :timeout, :integer` gives at the top level:
    # 30 and "30" are the same integer, however deep they arrive.
    it "coerces member values rather than passing them through raw" do
      aged = Class.new(Lain::Tool::Input) do
        field :people, :array, description: "Everyone" do
          field :age, :integer, description: "Years"
        end
      end
      expect(aged.build({ "people" => [{ "age" => "30" }] }).people.first.age).to eq(30)
    end

    it "exposes elements by message, not by key spelling" do
      built = person_input.build({ "people" => [{ "name" => "Lain" }, { name: "Alice", nickname: "Al" }] })
      expect(built.people.map(&:name)).to eq(%w[Lain Alice])
    end

    it "carries an element member's enum into the items schema" do
      graded = Class.new(Lain::Tool::Input) do
        field :people, :array, description: "Everyone" do
          field :rank, :string, description: "Their rank"
          validates :rank, inclusion: { in: %w[junior senior] }, allow_nil: true
        end
      end
      expect(graded.to_json_schema["properties"]["people"]["items"]["properties"]["rank"]["enum"])
        .to eq(%w[junior senior])
    end
  end

  describe "a malformed element" do
    it "is refused by field name and index, so the model can fix the right one" do
      expect { person_input.build({ "people" => [{ "name" => "Lain" }, { "nickname" => "Al" }] }) }
        .to raise_error(Lain::Tool::InvalidInput, /people\[1\].*[Nn]ame/)
    end

    it "is refused when an element names a member we do not have" do
      expect { person_input.build({ "people" => [{ "name" => "Lain", "age" => 14 }] }) }
        .to raise_error(Lain::Tool::InvalidInput, /people\[0\]/)
    end

    it "is refused when the field is not a list at all" do
      expect { person_input.build({ "people" => { "name" => "Lain" } }) }
        .to raise_error(Lain::Tool::InvalidInput, /people/)
    end

    # An absent array stays absent: it is `required`'s job to complain, not
    # the caster's, and `[]` would satisfy a blank_ok presence check.
    it "leaves an omitted array nil" do
      expect(person_input.build({}).people).to be_nil
    end
  end

  describe "a required array" do
    let(:required_input) do
      Class.new(Lain::Tool::Input) do
        field :people, :array, description: "Everyone", required: true do
          field :name, :string, description: "Their name", required: true
        end
      end
    end

    it "lists the field as required in the schema" do
      expect(required_input.to_json_schema["required"]).to eq(["people"])
    end

    it "rejects an omitted list" do
      expect(required_input.build({})).not_to be_valid
    end

    it "accepts a populated list" do
      expect(required_input.build({ "people" => [{ "name" => "Lain" }] })).to be_valid
    end

    # `presence: true` is right here: a required list with nothing in it is the
    # model forgetting to fill it in.
    it "rejects an empty list" do
      expect(required_input.build({ "people" => [] })).not_to be_valid
    end
  end

  # Clearing the list -- "everything is done" -- is a real call `todo_write`
  # answers today, so the DSL it migrates onto has to admit `[]`. ActiveModel
  # cannot express that with `exclusion: { in: [nil] }`: Clusivity special-cases
  # an Array value and tests it ELEMENT-WISE, and `[].all?` is vacuously true,
  # so the empty list gets reported "can't be nil".
  describe "a required array declared blank_ok" do
    let(:clearable) do
      Class.new(Lain::Tool::Input) do
        field :todos, :array, of: :string, description: "The whole list", required: true, blank_ok: true
      end
    end

    it "admits the empty list" do
      expect(clearable.build({ "todos" => [] })).to be_valid
    end

    it "still refuses an omitted list" do
      expect(clearable.build({})).not_to be_valid
    end

    it "says the list is missing rather than that an empty list is nil" do
      model = clearable.build({})
      model.valid?
      expect(model.errors.full_messages).to eq(["Todos can't be nil"])
    end

    it "keeps the field in the schema's required list" do
      expect(clearable.to_json_schema["required"]).to eq(["todos"])
    end

    # The same carve-out at the top level, which is what blank_ok was built for.
    it "still admits an empty String on a scalar field" do
      writer = Class.new(Lain::Tool::Input) do
        field :content, :string, description: "File body", required: true, blank_ok: true
      end
      expect(writer.build({ "content" => "" })).to be_valid
    end
  end

  # One declaration meaning two different things is the drift this class exists
  # to prevent -- and a constraint written for a scalar says something else, or
  # nothing at all, about a list.
  describe "a constraint on an array field" do
    it "counts elements with minItems/maxItems, because elements are what ActiveModel counts" do
      klass = Class.new(Lain::Tool::Input) do
        field :xs, :array, of: :string, description: "Some"
        validates :xs, length: { minimum: 1, maximum: 3 }
      end
      property = klass.to_json_schema["properties"]["xs"]
      expect(property).to include("minItems" => 1, "maxItems" => 3)
      expect(property.keys & %w[minLength maxLength]).to be_empty
    end

    # Clusivity walks an Array value element by element, so `["a"]` passes the
    # local check. An enum on the array itself would tell the model the whole
    # list must EQUAL "a" -- one declaration, two contradictory meanings.
    it "puts an inclusion enum inside items, where the validator actually looks" do
      property = enumerated_list.to_json_schema["properties"]["tags"]
      expect(property["items"]["enum"]).to eq(%w[a b])
      expect(property).not_to have_key("enum")
    end

    it "agrees with the local check it emitted" do
      expect(enumerated_list.build({ "tags" => ["a"] })).to be_valid
    end

    # ActiveModel applies both of these to the Array ITSELF -- matching a
    # regexp against `["a"].to_s` -- so neither `items` nor the array level
    # would mean what the local check does. Refusing beats emitting a lie.
    it "refuses a pattern, which has no array form" do
      klass = Class.new(Lain::Tool::Input) do
        field :xs, :array, of: :string, description: "Some"
        validates :xs, format: { with: /\A\w+\z/ }
      end
      expect { klass.to_json_schema }.to raise_error(ArgumentError, /xs/)
    end

    it "refuses numeric bounds, which have no array form" do
      klass = Class.new(Lain::Tool::Input) do
        field :xs, :array, of: :integer, description: "Some"
        validates :xs, numericality: { greater_than: 0 }
      end
      expect { klass.to_json_schema }.to raise_error(ArgumentError, /xs/)
    end
  end

  # `items` names one JSON type. ActiveModel's cast is forgiving by design --
  # at the top level "30" and 30 are one integer, which is the point -- but
  # inside a list the same forgiveness turns "abc" into 0 and {} into nil, and
  # a nil lands in an array whose schema promised the model integers.
  describe "a scalar element" do
    let(:ports) do
      Class.new(Lain::Tool::Input) { field :ports, :array, of: :integer, description: "Ports" }
    end

    let(:flags) do
      Class.new(Lain::Tool::Input) { field :flags, :array, of: :boolean, description: "Flags" }
    end

    it "refuses a word where items says integer" do
      expect { ports.build({ "ports" => [80, "abc"] }) }
        .to raise_error(Lain::Tool::InvalidInput, /ports\[1\].*integer/)
    end

    it "refuses an object where items says integer, rather than casting it to nil" do
      expect { ports.build({ "ports" => [{}] }) }
        .to raise_error(Lain::Tool::InvalidInput, /ports\[0\]/)
    end

    it "refuses nil inside the list" do
      expect { ports.build({ "ports" => [nil] }) }.to raise_error(Lain::Tool::InvalidInput, /ports\[0\]/)
    end

    it "refuses a word that is not a boolean" do
      expect { flags.build({ "flags" => ["maybe"] }) }
        .to raise_error(Lain::Tool::InvalidInput, /flags\[0\].*boolean/)
    end

    it "still admits a boolean" do
      expect(flags.build({ "flags" => [true, false] }).flags).to eq([true, false])
    end

    # A cast can fail in ways ActiveModel never wraps -- `Object#to_f` is a
    # NoMethodError -- and the model must not be handed Ruby internals with no
    # field name and no index.
    it "labels a failure that is not an InvalidInput" do
      raw = Object.new
      def raw.to_s = raise("exploding element")

      expect { ports.build({ "ports" => [raw] }) }
        .to raise_error(Lain::Tool::InvalidInput, /ports\[0\].*exploding element/)
    end

    it "refuses an element type that has no shape of its own" do
      expect { Class.new(Lain::Tool::Input) { field :xs, :array, of: :array, description: "Nested" } }
        .to raise_error(ArgumentError, /of: :array/)
    end
  end

  # A declaration saying two contradictory things is a mistake at the one moment
  # it is cheap to catch, and `field` already refuses every other one.
  describe "a contradictory declaration" do
    it "refuses `of:` and a block together" do
      expect do
        Class.new(Lain::Tool::Input) do
          field :xs, :array, of: :string, description: "Some" do
            field :n, :integer, description: "N"
          end
        end
      end.to raise_error(ArgumentError, /xs/)
    end

    it "refuses a positional type that contradicts an element declaration" do
      expect { Class.new(Lain::Tool::Input) { field :xs, :integer, of: :string, description: "Some" } }
        .to raise_error(ArgumentError, /:array/)
    end

    it "refuses an :array with no element shape" do
      expect { Class.new(Lain::Tool::Input) { field :xs, :array, description: "Some" } }
        .to raise_error(ArgumentError, /xs/)
    end
  end

  it "names an inline element class after the field it declares, not by heap address" do
    expect { person_input.build({ "people" => [{ "name" => "Lain", "age" => 14 }] }) }
      .to raise_error(Lain::Tool::InvalidInput, /people\[0\].*people/)
  end

  # The Journal is NDJSON and is the experiment record. An Input reaching
  # `to_json` renders as a heap address and SUCCEEDS, which is worse than
  # failing: a syntactically valid line nobody can read back.
  describe "#to_h" do
    subject(:built) { person_input.build({ "people" => [{ "name" => "Lain", "nickname" => "L" }] }) }

    it "is plain data all the way down" do
      expect(built.to_h).to eq("people" => [{ "name" => "Lain", "nickname" => "L" }])
    end

    it "survives canonicalization" do
      expect(Lain::Canonical.dump(built.to_h)).to include("Lain")
    end

    it "round-trips through JSON as data, not as an object-inspect string" do
      expect(JSON.parse(built.to_h.to_json)).to eq("people" => [{ "name" => "Lain", "nickname" => "L" }])
    end

    # The reader still hands back the element itself: `item.name` is the message
    # a #perform should depend on, not a key spelling.
    it "leaves the attribute reader answering messages" do
      expect(built.people.first.name).to eq("Lain")
    end
  end

  describe "the emitted schema" do
    it "does not alias the caller's enum, which would let a tool poison its own constant" do
      emitted = enumerated_list.to_json_schema["properties"]["tags"]["items"]["enum"]
      expect(emitted).to eq(tag_values).and(be_frozen)
      expect(emitted).not_to equal(tag_values)
    end

    it "does not let a subclass mutate its parent's field meta" do
      parent = Class.new(Lain::Tool::Input) { field :n, :integer, description: "Original" }
      child = Class.new(parent)
      child.fields["n"][:description] = "MUTATED"
      expect(parent.to_json_schema["properties"]["n"]["description"]).to eq("Original")
    end

    # `field`'s machinery is not the DSL a tool author writes.
    it "keeps its element machinery private" do
      expect { Lain::Tool::Input::Element }.to raise_error(NameError, /private constant/)
    end
  end

  # {Lain::Canonical} refuses exactly this rather than letting the last spelling
  # win, and calls it genuinely ambiguous. So does the door.
  describe "a key given twice, as both a String and a Symbol" do
    it "is refused at the top level" do
      expect { tag_input.build({ "tags" => ["a"], tags: ["b"] }) }
        .to raise_error(Lain::Tool::InvalidInput, /tags/)
    end

    it "is refused inside an element" do
      expect { person_input.build({ "people" => [{ "name" => "a", name: "b" }] }) }
        .to raise_error(Lain::Tool::InvalidInput, /people\[0\].*name/)
    end
  end

  # T3 migrates TodoWrite onto this DSL, and the tools block is the
  # prompt-cache prefix: the emitted bytes must be identical or every cached
  # prefix in the bench breaks.
  describe "the declaration T3 migrates TodoWrite onto" do
    subject(:declared) do
      statuses = Lain::Tools::TodoWrite::STATUSES
      Class.new(Lain::Tool::Input) do
        field :todos, :array, required: true, blank_ok: true,
                              description: "The complete replacement todo list, in the order it should be shown." do
          field :content, :string, description: "What the todo is.", required: true
          field :status, :string, description: "One of pending, in_progress, completed.", required: true
          validates :status, inclusion: { in: statuses }
        end
      end
    end

    it "reproduces the hand-written schema byte for byte, key order included" do
      expect(declared.to_json_schema.to_json).to eq(Lain::Tools::TodoWrite.new.input_schema.to_json)
    end

    # Schema equality is not behavioural equality, and this is the case that
    # separates them: clearing the list succeeds today, and must still succeed
    # after the migration.
    it "admits the empty list, which is how a run clears its todos" do
      expect(declared.build({ "todos" => [] })).to be_valid
    end

    it "admits a populated list" do
      built = declared.build({ "todos" => [{ "content" => "x", "status" => "pending" }] })
      expect(built).to be_valid
      expect(built.todos.first.content).to eq("x")
    end

    it "refuses a status the enum does not name, by index" do
      expect { declared.build({ "todos" => [{ "content" => "x", "status" => "nearly" }] }) }
        .to raise_error(Lain::Tool::InvalidInput, /todos\[0\].*[Ss]tatus/)
    end
  end
end

RSpec.describe "a Tool declaring an input_model" do
  subject(:tool) { tool_class.new }

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

  # `Input.build` RAISES for a failure with no per-attribute home -- a malformed
  # element, since only the raw input knows its index -- so it bypasses the
  # `valid?` path that carries the tool name. Without this the element case is the
  # one failure a human sees unattributed.
  # `blank_ok:` carves an exception out of the presence check `required:` installs.
  # Without `required:` there is no check to carve, so the declaration says a thing
  # it cannot mean -- refused at the one moment it is cheap, as the other
  # contradictory declarations are.
  it "refuses blank_ok without required, rather than silently installing nothing" do
    expect { Class.new(Lain::Tool::Input) { field :xs, :string, description: "X", blank_ok: true } }
      .to raise_error(ArgumentError, /blank_ok/)
  end

  it "names the tool when an element is refused" do
    element_tool = Class.new(Lain::Tool) do
      input_model(Class.new(Lain::Tool::Input) do
        field :people, :array, description: "Everyone involved" do
          field :name, :string, description: "Their name", required: true
        end
      end)
      def name = "roster"
      def description = "Records a roster."
      def perform(checked, _context) = Lain::Tool::Result.ok(checked.people.length.to_s)
    end

    expect { element_tool.new.call({ "people" => [{}] }) }
      .to raise_error(Lain::Tool::InvalidInput, /invalid input for roster:/)
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
