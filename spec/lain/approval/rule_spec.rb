# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module RuleSpecSupport
  # A verdict that answers one fixed Decision and counts how often it was
  # asked, so an example can tell "the Call read THIS object" from "the Call
  # parsed the command again somewhere of its own".
  class CountedVerdict
    attr_reader :asked, :commands

    def initialize(decision)
      @decision = decision
      @asked = 0
      @commands = []
    end

    def call(command)
      @asked += 1
      @commands << command
      @decision
    end
  end

  # A capability set that permits no program at all, so Shell::Verdict reaches
  # its `deny` arm -- the third absence, beside an abstention and a tool with
  # no parse to offer.
  class NothingPermitted
    def permits?(_program) = false
  end

  # A term no input of this tool's ever produced.
  FORGERY = Lain::Shell::Verdict::Decision.new(name: :allow, reason: "spec forges", term: [%w[curl http://evil]].freeze)

  # The design NOT taken: the term as a third `Data` member, derived inside
  # `initialize` behind the same input guard the real Call has. Kept as a
  # measurement rather than as prose in a comment, because what it does to a
  # forged term is the entire reason `Call#term` is a reader.
  Derived = Data.define(:tool, :input, :term)

  class Derived
    def initialize(tool:, input:, **)
      raise ArgumentError, "a Call carries a validated Tool::Input" unless input.is_a?(Lain::Tool::Input)

      super(tool:, input:, term: Lain::Shell::Verdict.new.call(input.command).term)
    end
  end
end

RSpec.describe Lain::Approval::Rule do
  let(:bash) { Lain::Tools::Bash.new }
  let(:read_file) { Lain::Tools::ReadFile.new }

  def call_for(tool, input) = described_class::Call.for(tool:, input:)

  # Scenario: a command tool's call carries the parsed term
  describe "the term a Call carries" do
    it "reports the parse of its own command, stage by stage" do
      expect(call_for(bash, { "command" => "cat README.md | head -20" }).term)
        .to eq([%w[cat README.md], %w[head -20]])
    end

    it "says a term is present, so a rule need not read presence off emptiness" do
      expect(call_for(bash, { "command" => "ls -la" })).to be_term
    end

    it "reads it off the tool's OWN verdict rather than one it built itself" do
      verdict = RuleSpecSupport::CountedVerdict.new(
        Lain::Shell::Verdict::Decision.new(name: :allow, reason: "spec", term: [%w[true]].freeze)
      )
      call = call_for(Lain::Tools::Bash.new(verdict:), { "command" => "ls -la" })

      expect(call.term).to eq([%w[true]])
      expect(verdict.asked).to eq(1)
      expect(verdict.commands).to eq(["ls -la"])
    end
  end

  # Scenario: a Call cannot be given a term at all
  #
  # The term is a function of BOTH members, so every example that closes one
  # keyword has a sibling closing the other. `#with(tool:)` is the one an
  # earlier draft of this file left open: it keeps a valid input and swaps the
  # verdict under it.
  describe "a term that was not derived" do
    let(:call) { call_for(bash, { "command" => "ls -la" }) }

    # A tool that answers a term its input never produced -- what a swapped
    # `tool:` would hand a rule.
    let(:liar) { Lain::Tools::Bash.new(verdict: RuleSpecSupport::CountedVerdict.new(RuleSpecSupport::FORGERY)) }

    it "refuses a term handed to #with" do
      expect { call.with(term: [%w[cat /home/u/.ssh/id_rsa]]) }
        .to raise_error(described_class::Call::Forged, /derived from the tool and input/)
    end

    it "refuses a tool handed to #with, which is the other half of the same forgery" do
      expect { call.with(tool: liar) }.to raise_error(described_class::Call::Forged)
    end

    it "refuses an input handed to #with, so no member is a door" do
      expect { call.with(input: Lain::Tools::Bash::Input.build({ "command" => "cat README.md" })) }
        .to raise_error(described_class::Call::Forged)
    end

    it "refuses #with even when it is handed nothing at all" do
      expect { call.with }.to raise_error(described_class::Call::Forged)
    end

    it "still reports the term of its own input after every attempt" do
      [-> { call.with(term: [%w[curl http://evil]]) }, -> { call.with(tool: liar) }, -> { call.with }]
        .each { |attempt| expect(&attempt).to raise_error(described_class::Call::Forged) }

      expect(call.term).to eq([%w[ls -la]])
    end

    it "closes Data::[], the second public constructor, against the same swap" do
      expect { described_class::Call[tool: liar, input: call.input] }
        .to raise_error(NoMethodError, /private method '\[\]'/)
    end

    it "would have been silently corrected, not refused, had the term been a derived member" do
      legit = RuleSpecSupport::Derived.new(tool: bash,
                                           input: Lain::Tools::Bash::Input.build({ "command" => "ls -la" }))

      expect(legit.with(term: [%w[cat /home/u/.ssh/id_rsa]]).term).to eq([%w[ls -la]])
    end
  end

  # Scenario: an abstention carries no term, visibly
  describe "a call the verdict abstained on" do
    it "carries an empty term" do
      expect(call_for(bash, { "command" => "git log --oneline -5" }).term).to be_empty
    end

    it "says so, so no rule can mistake absence for a term that was produced" do
      expect(call_for(bash, { "command" => "git log --oneline -5" })).not_to be_term
    end

    # #term? tests identity against the shipped Null, not emptiness, so this is
    # what it is actually asking.
    it "answers the one shipped NO_TERM object rather than an empty Array of its own" do
      expect(call_for(bash, { "command" => "git log --oneline -5" }).term)
        .to be(Lain::Shell::Verdict::NO_TERM)
    end

    # A deny, which is neither an allow nor an abstention: the arm differs and
    # the absence does not. #term? reads the term rather than the arm, so it
    # needs no third branch to get this right.
    it "does not call a denial's empty term present, though a denial is not an abstention" do
      denying = Lain::Shell::Verdict.new(capability_set: RuleSpecSupport::NothingPermitted.new)
      call = call_for(Lain::Tools::Bash.new(verdict: denying), { "command" => "ls -la" })

      expect(call.term).to be(Lain::Shell::Verdict::NO_TERM)
      expect(call).not_to be_term
    end
  end

  # The SECOND tool the ladder gates as a command tool. It shares
  # Tools::Bash::Input by identity and does run a command, but holds no
  # Shell::Verdict, so it has no term to offer and must not read as one.
  # Construction-only, so a nil client is the established idiom (see
  # spec/support/tool_registry.rb).
  describe "a command tool that offers no parse" do
    let(:core_exec) { Lain::Tools::CoreExec.new(client: nil) }

    it "is gated as a command tool the ladder consults" do
      expect(Lain::Approval::Escalation::Triage::COMMAND_TOOLS).to include(core_exec.name)
      expect(core_exec).to be_requires_approval
    end

    it "carries no term, on the same command bash would parse into one" do
      expect(call_for(core_exec, { "command" => "cat README.md | head -20" })).not_to be_term
    end

    it "answers the same absence a non-command tool does, by identity" do
      expect(call_for(core_exec, { "command" => "ls -la" }).term)
        .to be(Lain::Shell::Verdict::NO_TERM)
    end
  end

  # Scenario: a non-command tool is unaffected
  describe "a tool whose input is not a command" do
    it "carries an empty term" do
      expect(call_for(read_file, { "path" => "README.md" }).term).to be_empty
    end

    it "says no term is present rather than answering one nobody parsed" do
      expect(call_for(read_file, { "path" => "README.md" })).not_to be_term
    end

    it "is otherwise the Call it was: same members, same fields, still frozen" do
      call = call_for(read_file, { "path" => "README.md" })

      expect(call).to have_attributes(tool_name: "read_file", gated?: false, frozen?: true)
    end
  end

  # Scenario: the remembered rule is unchanged
  describe "what a remembered answer is keyed on" do
    let(:entry) { Lain::Approval::Remembered::Entry }

    it "holds exactly the two members that key is built from" do
      expect(described_class::Call.members).to eq(%i[tool input])
    end

    it "builds the byte-identical Entry a config row does" do
      expect(entry.for_call(call_for(bash, { "command" => "ls -la" })))
        .to eq(entry.from_table({ "tool" => "bash", "input" => { "command" => "ls -la" } }))
    end

    it "allows a remembered shape and says nothing about one differing in its arguments" do
      remembered = Lain::Approval::Remembered.new(allow: [{ "tool" => "bash",
                                                            "input" => { "command" => "ls -la" } }])

      expect(remembered.decide(call_for(bash, { "command" => "ls -la" }))).to be_allow
      expect(remembered.decide(call_for(bash, { "command" => "ls -lah" }))).to be_nil
    end
  end
end
