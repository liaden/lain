# frozen_string_literal: true

require "tmpdir"

# The `[approval]` table: the answers a human chose to remember, read here
# and interpreted by {Lain::Approval::Remembered}. Its own collaborator for
# {Lain::Config::Epics}'s reason -- one class per table, knowing its keys,
# its allowed values and its errors.
RSpec.describe Lain::Config::Answers do
  it "treats an absent table as no remembered answers" do
    answers = described_class.from(nil, path: "/irrelevant")

    expect(answers).to eq(described_class.empty)
  end

  it "reads every remembered shape out of the table" do
    answers = described_class.from({ "allow" => [{ "tool" => "read_file", "input" => { "path" => "a.md" } }],
                                     "deny" => [{ "tool" => "write_file", "input" => { "path" => "b.md" } }],
                                     "deny_tool" => [{ "tool" => "bash" }] },
                                   path: "/irrelevant")

    expect(answers.allow.map { |row| row["tool"] }).to eq(["read_file"])
    expect(answers.deny.first["input"]).to eq({ "path" => "b.md" })
    expect(answers.deny_tools).to eq(["bash"])
  end

  it "refuses a table that is not a table, naming the file" do
    expect { described_class.from("yes please", path: "/p/.lain/config.toml") }
      .to raise_error(described_class::NotATable, %r{/p/\.lain/config\.toml})
  end

  it "refuses a key it does not know" do
    expect { described_class.from({ "alow" => [] }, path: "/irrelevant") }
      .to raise_error(described_class::UnknownKeys, /alow/)
  end

  # The three refusals below pin their message as a STRING, not a regex: this
  # table's messages name the key, the offending entry and the computed set of
  # offending fields, and a refactor is only behaviour-preserving if every one
  # of those survives byte for byte. A `/allow/` match would pass against a
  # message that had lost the shape it is telling the human to write.
  it "refuses an answer list that is not a list of tables" do
    expect { described_class.from({ "allow" => "read_file" }, path: "/irrelevant") }
      .to raise_error(described_class::NotAList,
                      "/irrelevant: [approval] allow is a list of tables ([[approval.allow]]), got String")
  end

  it "refuses an entry with no tool" do
    expect { described_class.from({ "allow" => [{ "input" => { "path" => "a.md" } }] }, path: "/irrelevant") }
      .to raise_error(described_class::MalformedEntry,
                      '/irrelevant: [[approval.allow]] needs a tool name: {"input" => {"path" => "a.md"}}')
  end

  it "refuses an entry whose input is not a table of scalars, naming the offending field" do
    expect do
      described_class.from({ "allow" => [{ "tool" => "read_file", "input" => { "path" => ["a"] } }] },
                           path: "/irrelevant")
    end
      .to raise_error(described_class::MalformedEntry,
                      '/irrelevant: [[approval.allow]] input "path" is not a scalar: ' \
                      '{"tool" => "read_file", "input" => {"path" => ["a"]}}')
  end

  # `[[approval.allow]] tool = "bash"` reads as "allow every bash call" and
  # means "allow the one bash call whose every field is unset", which is
  # nothing. Refusing it is the difference between a permission the human
  # thinks they granted and one they did.
  it "refuses a shaped entry with no input table" do
    expect { described_class.from({ "allow" => [{ "tool" => "bash" }] }, path: "/irrelevant") }
      .to raise_error(described_class::MalformedEntry, /input/)
  end

  # A tool-wide denial has no call shape by definition, so an `input` beside
  # it is a misunderstanding that would silently do nothing.
  it "refuses an input on a tool-wide denial" do
    expect do
      described_class.from({ "deny_tool" => [{ "tool" => "bash", "input" => { "command" => "ls" } }] },
                           path: "/irrelevant")
    end
      .to raise_error(described_class::MalformedEntry, /input/)
  end

  # A hollow entry -- `tool = ""` -- names no tool and can never match a
  # call, which is the one thing MalformedEntry exists to refuse.
  it "refuses an entry whose tool name is blank" do
    expect { described_class.from({ "deny_tool" => [{ "tool" => "  " }] }, path: "/irrelevant") }
      .to raise_error(described_class::MalformedEntry, /tool/)
  end

  # {Lain::Config::Epics::Gates}'s posture: the closed-set check belongs to
  # the VALUE, so a hand-built one cannot carry a shape `.from` would refuse.
  it "refuses a hand-built entry the parser would have refused" do
    expect { described_class.new(allow: [{ "tool" => 42 }]) }
      .to raise_error(described_class::MalformedEntry)
  end

  # The third member used to skip the constructor check entirely: `[42]`
  # stored `"42"`, a refusal for a tool that does not exist, while `.from`
  # refused the same value. One of the two was lying about the shape.
  it "refuses hand-built tool-wide denials the parser would have refused" do
    [42, nil, ["bash"], ""].each do |name|
      expect { described_class.new(deny_tools: [name]) }
        .to raise_error(described_class::MalformedEntry)
    end
  end

  # The class and message of whatever a block refuses with, so the parse and
  # the constructor can be compared as VALUES rather than each against its own
  # literal -- a literal per side is two copies of one rule again.
  def refusal
    yield
    nil
  rescue StandardError => e
    [e.class, e.message]
  end

  # The same lie the example above caught, one rule up: `.from` refused a
  # strength that was not a list by name, while the constructor let it reach
  # `map` -- dying as an unnamed NoMethodError for a String, and worse for a
  # Hash or an Enumerator, which `map` accepts and which then refused as a
  # malformed ENTRY quoting a destructured pair.
  #
  # Comparing the two sides pins them TO EACH OTHER: widening one to admit a
  # shape the other still refuses fails here, which is how they drifted apart
  # in the first place.
  it "refuses a hand-built strength exactly as the parser refuses the same shape" do
    { allow: "allow", deny: "deny", deny_tools: "deny_tool" }.each do |member, key|
      ["read_file", { "tool" => "read_file" }, [].each, nil, 42].each do |shape|
        parsed = refusal { described_class.from({ key => shape }, path: "/cfg.toml") }
        built = refusal { described_class.new(**{ member => shape }) }

        expect(parsed).to eq([described_class::NotAList, "/cfg.toml: [approval] #{key} is a list of tables " \
                                                         "([[approval.#{key}]]), got #{shape.class}"])
        expect(built).to eq([described_class::NotAList, parsed.last.delete_prefix("/cfg.toml: ")])
      end
    end
  end

  it "is deeply frozen, so it rides inside a Ractor-shareable Config" do
    answers = described_class.from({ "allow" => [{ "tool" => "read_file", "input" => { "path" => "a.md" } }] },
                                   path: "/irrelevant")

    expect(answers).to be_deeply_frozen
  end
end

# A second describe, because these examples reach `[approval]` the way a
# project does -- through Config.load, so `described_class` has to be
# Lain::Config, which is also the value they assert stays shareable.
RSpec.describe Lain::Config do
  describe "the [approval] table through Config.load" do
    it "is empty when the file has no approval table" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")

        expect(described_class.load(root:).approval).to eq(Lain::Config::Answers.empty)
      end
    end

    it "raises a named error carrying the path when the table is not a table" do
      Dir.mktmpdir do |root|
        write_config(root, "approval = \"yes please\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Answers::NotATable, /#{Regexp.escape(config_path(root))}/)
      end
    end

    it "reads the remembered answers alongside [epics]" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          home = "repo"

          [[approval.allow]]
          tool = "read_file"
          input = { path = "README.md" }
        TOML

        config = described_class.load(root:)

        expect(config.epics_home).to eq(:repo)
        expect(config.approval.allow.length).to eq(1)
      end
    end

    it "coerces a plain Hash handed to the constructor" do
      config = described_class.new(epics: Lain::Config::Epics.new(home: :xdg),
                                   approval: { "deny_tool" => [{ "tool" => "bash" }] })

      expect(config.approval.deny_tools).to eq(["bash"])
    end

    it "stays Ractor-shareable with remembered answers aboard" do
      config = described_class.new(epics: Lain::Config::Epics.new(home: :xdg),
                                   approval: { "deny_tool" => [{ "tool" => "bash" }] })

      expect(config).to be_deeply_frozen
    end
  end
end
