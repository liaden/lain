# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
#
# None of these override #name: the derivation IS the design ("the deciding
# rule's identity travels with the decision"), and a hand-typed name that
# happened to match would leave this file green with Rule#name deleted.
module RuleChainSpecSupport
  # A rule with nothing to say about anything: the partial-function case the
  # whole chain exists for.
  class Silent < Lain::Approval::Rule
    def decide(_call) = nil
  end

  # Allows anything, and remembers the subject it was handed so a spec can
  # witness what a rule actually sees.
  class Allower < Lain::Approval::Rule
    attr_reader :subjects

    def initialize
      super
      @subjects = []
    end

    def decide(call)
      @subjects << call.input
      allow(call, because: "spec allows everything")
    end
  end

  # Denies anything.
  class Denier < Lain::Approval::Rule
    def decide(call) = deny(call, because: "spec denies everything")
  end

  # The rule that has no opinion about read_file specifically, so the chain
  # must consult the next one.
  class BashOnly < Lain::Approval::Rule
    def decide(call)
      deny(call, because: "bash is denied") if call.tool_name == "bash"
    end
  end

  # A rule that raises rather than deciding.
  class Raiser < Lain::Approval::Rule
    class Boom < StandardError; end

    def decide(_call) = raise(Boom, "the rule itself is broken")
  end

  # Names itself once and refuses afterwards: the fault path must not have to
  # ask a rule anything it can fail at a second time.
  class LateNamer < Lain::Approval::Rule
    class Boom < StandardError; end

    def initialize
      super
      @named = false
    end

    def name
      raise Lain::Approval::Rule::NotImplemented, "asked for a name twice" if @named

      @named = true
      super
    end

    def decide(_call) = raise(Boom, "broken after naming")
  end

  # The mistake a rule author from a total-predicate world makes.
  class Booleanish < Lain::Approval::Rule
    def decide(_call) = true # rubocop:disable Naming/PredicateMethod
  end

  # Raises something the chain does not rescue, so being consulted at all is
  # loud rather than quietly becoming a Fault.
  class Tripwire < Lain::Approval::Rule
    class Consulted < Exception; end # rubocop:disable Lint/InheritException

    def decide(_call) = raise(Consulted, "a rule past the deciding one was consulted")
  end

  # A fault recorder: the seam a chain reports a broken rule through.
  class Recorder
    attr_reader :faults

    def initialize = @faults = []

    def call(fault) = @faults << fault
  end
end

RSpec.describe Lain::Approval::RuleChain do
  let(:read_file) { Lain::Tools::ReadFile.new }
  let(:bash) { Lain::Tools::Bash.new }
  let(:call) { Lain::Approval::Rule::Call.for(tool: read_file, input: { "path" => "README.md" }) }
  let(:gated_call) { Lain::Approval::Rule::Call.for(tool: bash, input: { "command" => "ls" }) }
  let(:recorder) { RuleChainSpecSupport::Recorder.new }

  def chain(*rules) = described_class.new(rules, faults: recorder)

  describe "the lookup chain" do
    it "consults the next rule when the first has nothing to say about the call" do
      decision = chain(RuleChainSpecSupport::BashOnly.new, RuleChainSpecSupport::Allower.new).decide(call)

      expect(decision.rule).to eq("allower")
      expect(decision).to be_allow
    end

    it "lets the first decisive rule win" do
      decision = chain(RuleChainSpecSupport::Allower.new, RuleChainSpecSupport::Denier.new).decide(call)

      expect(decision).to be_allow
      expect(decision.rule).to eq("allower")
    end

    it "never consults a rule past the deciding one" do
      expect { chain(RuleChainSpecSupport::Denier.new, RuleChainSpecSupport::Tripwire.new).decide(call) }
        .not_to raise_error
    end

    it "does reach a rule past an abstaining one" do
      expect { chain(RuleChainSpecSupport::Silent.new, RuleChainSpecSupport::Tripwire.new).decide(call) }
        .to raise_error(RuleChainSpecSupport::Tripwire::Consulted)
    end

    it "returns no decision when no rule has an opinion, so the caller escalates" do
      expect(chain(RuleChainSpecSupport::Silent.new, RuleChainSpecSupport::Silent.new).decide(call)).to be_nil
    end

    it "returns no decision when it holds no rules at all" do
      expect(described_class.new.decide(call)).to be_nil
    end

    it "iterates its rules in order, so a chain can be read and compared" do
      built = chain(RuleChainSpecSupport::Silent.new, RuleChainSpecSupport::Denier.new)

      expect(built).to be_a(Enumerable)
      expect(built.map(&:name)).to eq(%w[silent denier])
    end

    it "answers an Enumerator when asked to iterate without a block" do
      expect(chain(RuleChainSpecSupport::Silent.new).each).to be_a(Enumerator)
    end
  end

  describe "a decision" do
    it "names the rule that made it, derived from the rule's own class" do
      decision = chain(RuleChainSpecSupport::Denier.new).decide(call)

      expect(decision).to be_deny
      expect(decision.rule).to eq("denier")
      expect(decision.reason).to eq("spec denies everything")
    end

    it "names a multi-word rule in snake_case, like a journal discriminator" do
      expect(chain(RuleChainSpecSupport::BashOnly.new).decide(gated_call).rule).to eq("bash_only")
    end

    it "names the tool and the tier the call was decided at" do
      decision = chain(RuleChainSpecSupport::Denier.new).decide(gated_call)

      expect(decision.tool).to eq("bash")
      expect(decision.gated).to be(true)
      expect(chain(RuleChainSpecSupport::Denier.new).decide(call).gated).to be(false)
    end

    it "is a deeply frozen value, so it is safe to journal and share" do
      decision = chain(RuleChainSpecSupport::Denier.new).decide(call)

      expect(Ractor.shareable?(decision)).to be(true)
    end

    it "refuses a verdict outside the closed set" do
      expect { Lain::Approval::Rule::Decision.new(verdict: :maybe, rule: "r", tool: "t", gated: false, reason: "") }
        .to raise_error(Lain::Approval::Rule::UnknownVerdict, /maybe/)
    end
  end

  describe "what a rule is handed" do
    it "is the validated input object, not the raw hash" do
      allower = RuleChainSpecSupport::Allower.new
      chain(allower).decide(call)
      subject = allower.subjects.first

      expect(subject).to be_a(Lain::Tool::Input)
      expect(subject.path).to eq("README.md")
    end

    it "cannot be built around a raw Hash or a bare String through ANY door" do
      shadow = { "path" => "/etc/shadow" }

      expect { Lain::Approval::Rule::Call.new(tool: read_file, input: shadow) }
        .to raise_error(NoMethodError, /private method 'new'/)
      expect { Lain::Approval::Rule::Call[tool: read_file, input: shadow] }
        .to raise_error(Lain::Approval::Rule::Call::NotValidated, /Hash/)
      expect { Lain::Approval::Rule::Call[tool: bash, input: "rm -rf /"] }
        .to raise_error(Lain::Approval::Rule::Call::NotValidated, /String/)
      expect { call.with(input: shadow) }
        .to raise_error(Lain::Approval::Rule::Call::NotValidated, /Hash/)
      expect { call.with(input: "rm -rf /") }
        .to raise_error(Lain::Approval::Rule::Call::NotValidated, /String/)
    end

    it "keeps Data's own derivation working for a validated input" do
      expect(call.with(tool: bash).tool_name).to eq("bash")
    end

    it "refuses to build a call whose input does not validate" do
      expect { Lain::Approval::Rule::Call.for(tool: read_file, input: {}) }
        .to raise_error(Lain::Tool::InvalidInput, /read_file: Path can't be blank/)
    end

    it "refuses to build a call for a tool that declares no input model" do
      expect { Lain::Approval::Rule::Call.for(tool: Lain::Tools::TodoWrite.new, input: { "todos" => [] }) }
        .to raise_error(Lain::Approval::Rule::Call::Undeclared, /todo_write/)
    end

    it "answers whether a tool can be described at all, so a caller need not rescue" do
      expect(Lain::Approval::Rule::Call.describable?(read_file)).to be(true)
      expect(Lain::Approval::Rule::Call.describable?(Lain::Tools::TodoWrite.new)).to be(false)
    end

    it "refuses a subject that is not a Call, rather than passing it to a rule" do
      expect { chain(RuleChainSpecSupport::Allower.new).decide("rm -rf /") }
        .to raise_error(described_class::NotACall, /String/)
    end
  end

  describe "a rule that raises" do
    it "is skipped, and the chain continues to the next rule" do
      allower = RuleChainSpecSupport::Allower.new
      chain(RuleChainSpecSupport::Raiser.new, allower).decide(call)

      expect(allower.subjects.size).to eq(1)
    end

    it "poisons the allow side: an allow reached over a fault becomes an escalation" do
      expect(chain(RuleChainSpecSupport::Raiser.new, RuleChainSpecSupport::Allower.new).decide(call)).to be_nil
    end

    it "leaves the deny side working, still attributed" do
      decision = chain(RuleChainSpecSupport::Raiser.new, RuleChainSpecSupport::Denier.new).decide(call)

      expect(decision).to be_deny
      expect(decision.rule).to eq("denier")
    end

    it "leaves a clean chain untouched" do
      expect(chain(RuleChainSpecSupport::Allower.new).decide(call)).to be_allow
    end

    it "has its failure recorded, naming the rule, the tool and the error" do
      chain(RuleChainSpecSupport::Raiser.new, RuleChainSpecSupport::Allower.new).decide(call)
      fault = recorder.faults.first

      expect(fault.rule).to eq("raiser")
      expect(fault.tool).to eq("read_file")
      expect(fault.error).to eq("RuleChainSpecSupport::Raiser::Boom")
      expect(fault.message).to eq("the rule itself is broken")
      expect(Ractor.shareable?(fault)).to be(true)
    end

    it "leaves no decision behind when it was the only rule" do
      expect(chain(RuleChainSpecSupport::Raiser.new).decide(call)).to be_nil
      expect(recorder.faults.size).to eq(1)
    end

    it "records nowhere at all when the chain was built with no recorder" do
      expect(described_class.new([RuleChainSpecSupport::Raiser.new]).decide(call)).to be_nil
    end
  end

  describe "a rule that answers something other than a decision" do
    it "is a fault, not a decision the caller discovers by crashing" do
      expect(chain(RuleChainSpecSupport::Booleanish.new).decide(call)).to be_nil
      expect(recorder.faults.first.error).to eq("Lain::Approval::RuleChain::NotADecision")
    end
  end

  describe "nothing may take the chain down" do
    it "not a rule that does not implement the seam" do
      expect(described_class.new([Lain::Approval::Rule.new], faults: recorder).decide(call)).to be_nil
      expect(recorder.faults.first.error).to eq("Lain::Approval::Rule::NotImplemented")
    end

    it "not a rule raising an anonymously-classed error, whose class name is nil" do
      nameless = Class.new(StandardError)
      rule = Class.new(RuleChainSpecSupport::Silent) { define_method(:decide) { |_c| raise nameless, "boom" } }
      stub_const("RuleChainSpecSupport::NamelessRaiser", rule)

      expect(chain(rule.new).decide(call)).to be_nil
      expect(recorder.faults.first.error).to include("Class")
    end

    it "not a rule that names itself at wiring and refuses at decide time" do
      chain(RuleChainSpecSupport::LateNamer.new).decide(call)

      expect(recorder.faults.first.rule).to eq("late_namer")
      expect(recorder.faults.first.error).to eq("RuleChainSpecSupport::LateNamer::Boom")
    end

    it "not a recorder that raises on its way to a full disk" do
      broken = Object.new
      def broken.call(_fault) = raise("the journal is broken")

      expect(described_class.new([RuleChainSpecSupport::Raiser.new], faults: broken).decide(call)).to be_nil
    end

    it "and an unattributable rule cannot get into a chain in the first place" do
      anonymous = Class.new(Lain::Approval::Rule) { def decide(call) = allow(call, because: "anonymous") }

      expect { chain(anonymous.new) }.to raise_error(Lain::Approval::Rule::NotImplemented, /anonymous rule/)
    end
  end

  describe "a rule asked directly" do
    it "fails loudly when it does not implement the seam" do
      expect { Lain::Approval::Rule.new.decide(call) }
        .to raise_error(Lain::Approval::Rule::NotImplemented, /decide/)
    end
  end
end
