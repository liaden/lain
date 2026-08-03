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

  # A rule that OWNS an inner chain: the nesting shape the chain has to compose
  # under, and the one a plain `nil` for "poisoned" quietly broke.
  class Delegating < Lain::Approval::Rule
    def initialize(inner)
      super()
      @inner = inner
    end

    def decide(call) = @inner.decide(call)
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

  # A tool with no {Tool::Input} declaration -- the precondition these examples
  # actually assert. It is declared HERE rather than borrowed from
  # `Lain::Tools::*` because a shipped tool is a moving target for this: this
  # spec used `TodoWrite` until T3 migrated it onto the field DSL, at which
  # point both examples failed over a fact about TodoWrite they never meant to
  # depend on. No shipped tool lacks an `input_model` any more (all 24 declare
  # one), so a local stand-in is the only honest subject as well as a stable one.
  #
  # The name is deliberately arbitrary: what the Undeclared message must prove
  # is that THIS tool's name travelled into it, and a name that restated the
  # concept would match its own regexp no matter which tool raised.
  let(:nameless_probe) do
    Class.new(Lain::Tool) do
      def name = "nameless_probe"
      def description = "declares no Tool::Input, so it falls back to Tool#input_schema's empty default"
    end.new
  end
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
      expect { Lain::Approval::Rule::Call.for(tool: nameless_probe, input: { "anything" => 1 }) }
        .to raise_error(Lain::Approval::Rule::Call::Undeclared, /nameless_probe/)
    end

    it "answers whether a tool can be described at all, so a caller need not rescue" do
      expect(Lain::Approval::Rule::Call.describable?(read_file)).to be(true)
      expect(Lain::Approval::Rule::Call.describable?(nameless_probe)).to be(false)
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
      answer = chain(RuleChainSpecSupport::Raiser.new, RuleChainSpecSupport::Allower.new).decide(call)

      expect(answer).to be_a(described_class::Poisoned)
      expect(answer).not_to be_allow
      expect(answer.decision).to be_nil
    end

    # The distinction the whole Poisoned value exists for: a caller must be able
    # to tell "nobody had an opinion" from "an allow was suppressed", and `nil`
    # for both is what let a nesting rule launder a fault.
    it "answers a poisoned value, never the same nothing an abstention answers" do
      abstained = chain(RuleChainSpecSupport::Silent.new).decide(call)
      poisoned = chain(RuleChainSpecSupport::Raiser.new).decide(call)

      expect(abstained).to be_nil
      expect(poisoned).not_to be_nil
      expect(poisoned).to be_faulted
      expect(poisoned.fault.rule).to eq("raiser")
    end

    it "leaves the deny side working, still attributed, and still says a rule broke" do
      answer = chain(RuleChainSpecSupport::Raiser.new, RuleChainSpecSupport::Denier.new).decide(call)

      expect(answer).to be_deny
      expect(answer).to be_faulted
      expect(answer.decision.rule).to eq("denier")
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
      expect(chain(RuleChainSpecSupport::Raiser.new).decide(call).decision).to be_nil
      expect(recorder.faults.size).to eq(1)
    end

    it "records nowhere at all when the chain was built with no recorder" do
      answer = described_class.new([RuleChainSpecSupport::Raiser.new]).decide(call)

      # Poisoning is the chain's own and does not depend on the recorder, which
      # is what keeps a Null-wired chain safe even while it is silent.
      expect(answer).to be_faulted
      expect(answer.decision).to be_nil
    end
  end

  # The card's illustration, and the reason a poisoned answer is a value rather
  # than a nil: a rule that OWNS an inner chain used to hand the outer chain the
  # inner's `nil`, which the outer read as an abstention and promoted the next
  # rule's allow over.
  describe "a rule that owns an inner chain" do
    def nested(inner_rules, *outer_rules)
      chain(RuleChainSpecSupport::Delegating.new(described_class.new(inner_rules, faults: recorder)), *outer_rules)
    end

    it "does not launder the inner chain's fault into an abstention" do
      answer = nested([RuleChainSpecSupport::Raiser.new, RuleChainSpecSupport::Allower.new],
                      RuleChainSpecSupport::Allower.new).decide(call)

      expect(answer).to be_a(described_class::Poisoned)
      expect(answer).not_to be_allow
      expect(answer.fault.rule).to eq("raiser")
    end

    it "propagates a clean inner decision untouched" do
      expect(nested([RuleChainSpecSupport::Denier.new]).decide(call)).to be_deny
    end

    it "reaches the outer rules when the inner chain abstains" do
      expect(nested([RuleChainSpecSupport::Silent.new], RuleChainSpecSupport::Allower.new).decide(call)).to be_allow
    end

    # ATTRIBUTION is what the unwrap actually buys, and it is the assertion that
    # tells the fix from its absence: without it a returned Poisoned becomes a
    # NotADecision fault OF THE DELEGATING RULE, which poisons too -- so the
    # outcome still fails closed and only the name is wrong. `raiser`, never
    # `delegating`.
    it "lets a deny past the inner fault decide, still saying WHICH rule broke" do
      answer = nested([RuleChainSpecSupport::Raiser.new], RuleChainSpecSupport::Denier.new).decide(call)

      expect(answer).to be_deny
      expect(answer).to be_faulted
      expect(answer.fault.rule).to eq("raiser")
      expect(answer.fault.error).to eq("RuleChainSpecSupport::Raiser::Boom")
    end
  end

  describe "a rule that answers something other than a decision" do
    it "is a fault, not a decision the caller discovers by crashing" do
      expect(chain(RuleChainSpecSupport::Booleanish.new).decide(call)).to be_faulted
      expect(recorder.faults.first.error).to eq("Lain::Approval::RuleChain::NotADecision")
    end
  end

  describe "nothing may take the chain down" do
    it "not a rule that does not implement the seam" do
      expect(described_class.new([Lain::Approval::Rule.new], faults: recorder).decide(call)).to be_faulted
      expect(recorder.faults.first.error).to eq("Lain::Approval::Rule::NotImplemented")
    end

    it "not a rule raising an anonymously-classed error, whose class name is nil" do
      nameless = Class.new(StandardError)
      rule = Class.new(RuleChainSpecSupport::Silent) { define_method(:decide) { |_c| raise nameless, "boom" } }
      stub_const("RuleChainSpecSupport::NamelessRaiser", rule)

      expect(chain(rule.new).decide(call)).to be_faulted
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

      expect(described_class.new([RuleChainSpecSupport::Raiser.new], faults: broken).decide(call)).to be_faulted
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
