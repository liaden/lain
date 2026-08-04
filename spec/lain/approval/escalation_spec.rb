# frozen_string_literal: true

require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
#
# The rungs here are duck-typed on purpose -- the ladder depends on `#name` and
# `#call(effect, context) -> Ruling` and on nothing else -- so none of them
# inherits from anything in lib/.
module EscalationSpecSupport
  Ruling = Lain::Approval::Escalation::Ruling

  # A rung with one fixed answer, named at construction so a spec can read the
  # attribution back out of the journal.
  class Fixed
    attr_reader :name, :consulted

    def initialize(name, verdict)
      @name = name
      @verdict = verdict
      @consulted = 0
    end

    def call(_effect, _context)
      @consulted += 1
      Ruling.public_send(@verdict, rung: @name, because: "spec #{@verdict}s everything")
    end
  end

  # The rung that says nothing at all: the composability subject.
  class Silent < Fixed
    def initialize(name = "silent")
      super(name, :abstain)
    end
  end

  # A rung whose own machinery is broken. Being consulted must never read as an
  # approval, and it must never take the ladder down.
  class Broken
    class Boom < StandardError; end

    def name = "broken"
    def call(_effect, _context) = raise(Boom, "the rung itself is broken")
  end

  # Answers something that is not a Ruling: the total-predicate mistake.
  class Booleanish
    def name = "booleanish"
    def call(_effect, _context) = true
  end

  # Raises when consulted at all, loudly enough that the chain cannot swallow it.
  class Tripwire
    class Consulted < Exception; end # rubocop:disable Lint/InheritException

    def name = "tripwire"
    def call(_effect, _context) = raise(Consulted, "a rung past the deciding one was consulted")
  end

  # A rule that raises rather than deciding: the fault the ladder must not
  # launder into a plain abstention.
  class Raiser < Lain::Approval::Rule
    class Boom < StandardError; end

    def decide(_call) = raise(Boom, "the rule itself is broken")
  end

  class Allower < Lain::Approval::Rule
    def decide(call) = allow(call, because: "spec allows everything")
  end

  class Denier < Lain::Approval::Rule
    def decide(call) = deny(call, because: "spec denies everything")
  end

  # The card's literal illustration: a rule that OWNS an inner chain. The
  # laundering it can do is one level below the ladder, which is where the fix
  # has to live.
  class Delegating < Lain::Approval::Rule
    def initialize(inner)
      super()
      @inner = inner
    end

    def decide(call) = @inner.decide(call)
  end

  # Reads the input the way a real rule does, which is what detonates on the
  # values `Rule::Call.for` builds cleanly and cannot vouch for (a NUL byte, a
  # UTF-16LE String).
  class Reader < Lain::Approval::Rule
    def decide(call)
      allow(call, because: "read #{File.basename(call.input.command)}")
    end
  end

  # A queue-shaped rung stand-in: answers a fixed Boolean the way
  # {Lain::Approval::Queue#call} does, without parking a fiber.
  class Surface
    def initialize(answer) = @answer = answer
    def call(_effect, _context) = @answer
  end

  class Recorder
    attr_reader :faults

    def initialize = @faults = []
    def call(fault) = @faults << fault
  end

  # A journal whose every write fails: evidence about a turn must never cost
  # the turn.
  class DeadJournal
    def record(_entry) = raise(IOError, "the journal is gone")
  end
end

RSpec.describe Lain::Approval::Escalation do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:bash) { Lain::Tools::Bash.new }
  let(:tools) { Lain::Toolset.new([bash, Lain::Tools::ReadFile.new]) }
  let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "ls" }) }

  def ladder(*rungs) = described_class.new(rungs, journal:)

  def rulings = Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a

  def faults = Lain::Journal.records(journal_io.string.lines, type: "escalation_fault").to_a

  def rules_rung(*rules, faults: journal)
    described_class::Rules.new(rules:, tools:, faults: described_class::Faults.new(faults))
  end

  describe "the seam it presents" do
    it "answers a Boolean, so Effect::Handler::Gate's two-valued policy duck is unchanged" do
      expect(ladder(EscalationSpecSupport::Fixed.new("rule", :allow)).call(effect, nil)).to be(true)
      expect(ladder(EscalationSpecSupport::Fixed.new("rule", :deny)).call(effect, nil)).to be(false)
    end

    it "drops straight into a Gate as its policy" do
      live = Lain::Effect::Handler::Live.new(toolset: tools)
      gate = Lain::Effect::Handler::Gate.new(policy: ladder(EscalationSpecSupport::Fixed.new("rule", :deny)),
                                             inner: live)

      expect(gate.call(effect, nil)).to have_attributes(is_error: true, content: /denied/)
    end

    it "reads as the value it is: its rungs, in order" do
      built = ladder(EscalationSpecSupport::Silent.new, EscalationSpecSupport::Fixed.new("rule", :allow))

      expect(built).to be_a(Enumerable)
      expect(built.map(&:name)).to eq(%w[silent rule])
    end
  end

  # Scenario: a deterministic allow settles without reaching anything above it
  # Scenario: a deterministic deny settles without reaching anything above it
  # Scenario: an abstention parks for the surfaces above
  describe "where a call settles" do
    let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 0.05) }

    def over(rung) = ladder(rung, described_class::Surfaces.new(queue))

    it "settles a deterministic allow with no queue entry created" do
      expect(over(EscalationSpecSupport::Fixed.new("rules", :allow)).call(effect, nil)).to be(true)
      expect(queue.each.count).to eq(0)
    end

    it "settles a deterministic deny with no queue entry created" do
      expect(over(EscalationSpecSupport::Fixed.new("rules", :deny)).call(effect, nil)).to be(false)
      expect(queue.each.count).to eq(0)
    end

    it "parks an abstention on the approval queue exactly as it does today" do
      Sync do |task|
        parked = task.async { over(EscalationSpecSupport::Silent.new).call(effect, nil) }
        pending = task.with_timeout(1) { queue.dequeue }

        expect(pending.tool).to eq("bash")

        pending.approve(surface: "tty")

        expect(task.with_timeout(1) { parked.wait }).to be(true)
      end
    end

    # Scenario: the auto-approve layer only sees what the deterministic rung
    # abstained on.
    it "creates nothing for an auto-approve surface to adjudicate when the rung allowed" do
      spawn = ->(*) { raise "a role was spawned to adjudicate a call the rung had already settled" }
      surface = Lain::Approval::AutoSurface.new(role_spawn: spawn)

      over(EscalationSpecSupport::Fixed.new("rules", :allow)).call(effect, nil)

      expect { surface.sweep(queue) }.not_to raise_error
      expect(queue.each.count).to eq(0)
    end
  end

  # Scenario: the ladder remains fail-closed
  describe "fail-closed" do
    it "denies a call that reaches the timeout with no answer from any surface" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 0.01)

      Sync do
        expect(ladder(described_class::Surfaces.new(queue)).call(effect, nil)).to be(false)
      end
    end

    it "denies when every rung abstained, because an unanswered gate refuses" do
      expect(ladder(EscalationSpecSupport::Silent.new).call(effect, nil)).to be(false)
    end

    it "denies when it holds no rungs at all" do
      expect(ladder.call(effect, nil)).to be(false)
    end

    it "never reads a rung's own failure as an approval" do
      expect(ladder(EscalationSpecSupport::Broken.new, EscalationSpecSupport::Fixed.new("rule", :allow))
               .call(effect, nil)).to be(false)
    end

    it "never reads a rung answering something that is not a Ruling as an approval" do
      expect(ladder(EscalationSpecSupport::Booleanish.new).call(effect, nil)).to be(false)
    end
  end

  # Scenario: an abstaining rung does not change the outcome
  describe "composition" do
    def outcome(*rungs)
      built = ladder(*rungs)
      [built.call(effect, nil), Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a.last["rung"]]
    end

    it "is unchanged by an always-abstaining rung inserted anywhere" do
      deciding = EscalationSpecSupport::Fixed.new("rules", :deny)
      bare = outcome(deciding)

      journal_io.truncate(journal_io.rewind)
      expect(outcome(EscalationSpecSupport::Silent.new("first"), deciding)).to eq(bare)

      journal_io.truncate(journal_io.rewind)
      expect(outcome(deciding, EscalationSpecSupport::Silent.new("last"))).to eq(bare)
    end

    it "never consults a rung past the deciding one" do
      expect do
        ladder(EscalationSpecSupport::Fixed.new("rules", :deny), EscalationSpecSupport::Tripwire.new)
          .call(effect, nil)
      end.not_to raise_error
    end

    it "does reach a rung past an abstaining one" do
      expect { ladder(EscalationSpecSupport::Silent.new, EscalationSpecSupport::Tripwire.new).call(effect, nil) }
        .to raise_error(EscalationSpecSupport::Tripwire::Consulted)
    end
  end

  # Scenario: abstention is distinguished from denial by absence, not by falsiness
  describe "a Ruling" do
    it "recognises abstention by asking, never by !allow?" do
      abstained = described_class::Ruling.abstain(rung: "rules", because: "no opinion")
      denied = described_class::Ruling.deny(rung: "rules", because: "policy")

      expect([abstained, denied].map(&:allow?)).to eq([false, false])
      expect(abstained).to be_abstain
      expect(denied).not_to be_abstain
      expect(denied).to be_deny
      expect(abstained).not_to be_deny
    end

    it "refuses a verdict outside the closed set" do
      expect { described_class::Ruling.new(verdict: :maybe, rung: "rules", reason: "?") }
        .to raise_error(described_class::UnknownVerdict, /maybe/)
    end

    it "is a deeply frozen value, so it is safe to journal and share" do
      expect(described_class::Ruling.allow(rung: "rules", because: "ok")).to be_deeply_frozen
    end
  end

  # Scenario: every decision names the rung that made it
  describe "the journal" do
    it "names the rung on every record, for each rung that was consulted" do
      ladder(EscalationSpecSupport::Silent.new, EscalationSpecSupport::Fixed.new("rules", :deny)).call(effect, nil)

      expect(rulings.map { |record| record.values_at("rung", "verdict") })
        .to eq([%w[silent abstain], %w[rules deny]])
      expect(rulings.map { |record| record["tool"] }).to all(eq("bash"))
    end

    it "names the fail-closed bottom when nothing above it answered" do
      ladder(EscalationSpecSupport::Silent.new).call(effect, nil)

      expect(rulings.last).to include("rung" => "ladder", "verdict" => "deny")
    end

    it "does not cost the turn when the journal itself is gone" do
      built = described_class.new([EscalationSpecSupport::Fixed.new("rules", :deny)],
                                  journal: EscalationSpecSupport::DeadJournal.new)

      expect(built.call(effect, nil)).to be(false)
    end
  end

  # Scenario: a fault cannot be laundered into an abstention by a wrapping rung
  # Scenario: the ladder is wired with a real fault recorder, never the Null
  describe "a fault, which is not an abstention" do
    let(:laundering) { rules_rung(EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Allower.new) }

    it "refuses to promote a later allow over a rung that faulted" do
      built = ladder(laundering, EscalationSpecSupport::Fixed.new("surfaces", :allow))

      expect(built.call(effect, nil)).to be(false)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny")
      expect(rulings.last["reason"]).to include("suppressed")
    end

    it "reaches a journal-backed recorder, so the run is not silently lenient" do
      ladder(laundering).call(effect, nil)

      expect(faults.first).to include("rule" => "raiser", "tool" => "bash", "error" => "EscalationSpecSupport::Raiser::Boom")
    end

    it "attributes the fault to its own rung, distinctly from an abstention" do
      ladder(laundering).call(effect, nil)

      faulted = rulings.find { |record| record["faulted"] }

      expect(faulted).to include("rung" => "rules", "verdict" => "abstain")
    end

    it "names the faulting rung on the fail-closed denial when nothing answered" do
      ladder(laundering).call(effect, nil)

      expect(rulings.last).to include("rung" => "ladder", "verdict" => "deny", "faulted" => true)
      expect(rulings.last["reason"]).to include("rules")
    end

    it "still denies, and still attributes, when a rule denies after another faulted" do
      built = ladder(rules_rung(EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Denier.new))

      expect(built.call(effect, nil)).to be(false)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny")
    end

    it "leaves a clean abstention unpoisoned, so a later allow still wins" do
      built = ladder(rules_rung, EscalationSpecSupport::Fixed.new("surfaces", :allow))

      expect(built.call(effect, nil)).to be(true)
    end

    # B2. The card's own illustration, one level below the rung: a Rule that owns
    # an inner chain. Closing this at the rung only was not closing it.
    it "does not launder a fault through a rule that owns an inner chain" do
      inner = Lain::Approval::RuleChain.new([EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Allower.new])
      built = ladder(rules_rung(EscalationSpecSupport::Delegating.new(inner), EscalationSpecSupport::Allower.new))

      expect(built.call(effect, nil)).to be(false)
      expect(rulings.first).to include("rung" => "rules", "faulted" => true)
    end

    # S4. A deny reached after a fault is still a deny -- and the stream must say
    # a fault happened, or a reader sees a clean denial that was not one.
    it "marks a post-fault deny as faulted in the record" do
      ladder(rules_rung(EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Denier.new)).call(effect, nil)

      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny", "faulted" => true)
    end
  end

  # B1. Poison propagates across the DETERMINISTIC rungs and stops at the asking
  # rung. A human is not a later rule -- they are the authority the whole ladder
  # exists to escalate to, and suppressing their answer inverts it.
  describe "a fault, and who is entitled to answer over one" do
    def settled_by(rung, surface:, approve: true)
      queue = Lain::Approval::Queue.new(journal:, timeout: 1)
      built = ladder(rung, described_class::Surfaces.new(queue))
      answer = nil
      Sync do |task|
        asked = task.async { answer = built.call(effect, nil) }
        pending = task.with_timeout(1) { queue.dequeue }
        approve ? pending.approve(surface:) : pending.deny(surface:)
        task.with_timeout(1) { asked.wait }
      end
      answer
    end

    let(:faulting) { rules_rung(EscalationSpecSupport::Raiser.new) }

    it "honours a human surface's allow over a fault, rather than wedging the session" do
      expect(settled_by(faulting, surface: "tty")).to be(true)
    end

    it "records that allow as faulted, naming the rung that broke" do
      settled_by(faulting, surface: "tty")

      expect(rulings.last).to include("rung" => "surfaces", "verdict" => "allow", "faulted" => true)
      expect(rulings.last["reason"]).to include("rules")
    end

    it "keeps suppressing an auto-approver's allow, which IS a later automatic rung" do
      expect(settled_by(faulting, surface: Lain::Approval::AutoSurface::SURFACE)).to be(false)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny")
    end

    it "leaves a clean human allow unmarked" do
      expect(settled_by(EscalationSpecSupport::Silent.new, surface: "tty")).to be(true)
      expect(rulings.last).to include("rung" => "surfaces", "verdict" => "allow", "faulted" => false)
    end

    it "does not resurrect a human's denial into an approval" do
      expect(settled_by(faulting, surface: "tty", approve: false)).to be(false)
    end
  end

  # The MEASURED table in T21: Rule::Call.for is not total, and a rescue list is
  # not a substitute for a total classifier.
  describe "the rules rung, over inputs Rule::Call.for cannot vouch for" do
    def judged(input)
      built = ladder(rules_rung(EscalationSpecSupport::Reader.new))
      built.call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:), nil)
    end

    it "abstains on a blank required field, which raises Tool::InvalidInput" do
      expect(judged({ "command" => "  " })).to be(false)
      expect(rulings.first).to include("rung" => "rules", "verdict" => "abstain", "faulted" => false)
    end

    it "abstains on a tool this session does not hold" do
      built = ladder(rules_rung(EscalationSpecSupport::Allower.new))
      answer = built.call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "nope", input: {}), nil)

      expect(answer).to be(false)
      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
    end

    it "faults rather than abstaining on the ArgumentError invalid UTF-8 raises" do
      # A lone continuation byte: UTF-8-tagged and invalid, which is what makes
      # ActiveSupport's `String#blank?` raise ArgumentError out of Regexp#match?.
      expect(judged({ "command" => "ls \xC3" })).to be(false)
      expect(rulings.first).to include("rung" => "rules", "faulted" => true)
    end

    it "faults on the value that builds cleanly and detonates inside a rule" do
      expect(judged({ "command" => "ls\0" })).to be(false)
      expect(rulings.first).to include("rung" => "rules", "faulted" => true)
      expect(faults.first).to include("rule" => "reader")
    end
  end

  # T16's verdict is three-valued and its allow claims only "literal and fully
  # understood", never "safe".
  describe "the triage rung, over Shell::Verdict" do
    def triaged(command, capability_set: Lain::Shell::Verdict::AnyProgram.new)
      rung = described_class::Triage.new(verdict: Lain::Shell::Verdict.new(capability_set:))
      ladder(rung).call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                                   input: { "command" => command }), nil)
    end

    it "denies what the session's capability set excludes, which nothing enforced before" do
      excluded = Class.new { def permits?(program) = program != "curl" }.new

      expect(triaged("curl http://example.com", capability_set: excluded)).to be(false)
      expect(rulings.first).to include("rung" => "triage", "verdict" => "deny")
    end

    it "abstains on an allow, because 'literal and fully understood' is not 'safe'" do
      expect(rulings).to be_empty
      triaged("rm -rf /home/joel")

      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain")
    end

    it "abstains on an abstention, and says what the verdict doubted" do
      triaged("echo hi; rm -rf /tmp/x")

      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain")
      expect(rulings.first["reason"]).to include("not fully understood")
    end

    it "journals the claim on every record, so no reader mistakes it for a safety judgement" do
      triaged("ls -la")

      expect(rulings.first["reason"]).to include(Lain::Shell::Verdict::CLAIM)
    end

    it "abstains on a tool it does not judge" do
      rung = described_class::Triage.new
      answer = ladder(rung).call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file",
                                                            input: { "path" => "README.md" }), nil)

      expect(answer).to be(false)
      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
    end

    it "abstains when the command field is not a String at all" do
      expect(triaged(nil)).to be(false)
      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
    end
  end

  describe ".for, which is how a session wires it" do
    let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 0.05) }
    let(:built) { described_class.for(queue:, tools:, journal:, rules: [EscalationSpecSupport::Raiser.new]) }

    it "orders the rungs triage, rules, surfaces -- deterministic before the human" do
      expect(built.map(&:name)).to eq(%w[triage rules surfaces])
    end

    it "wires a real fault recorder, never RuleChain::Faults::Null" do
      built.call(effect, nil)

      expect(faults.first).to include("rule" => "raiser", "tool" => "bash", "tool_use_id" => "tu_1")
    end

    # B3/S2. The triage rung's DENY arm is unreachable as this repo wires it --
    # the default capability set permits every program and nothing in lib/ builds
    # a restricting one. This is the seam that makes it reachable, and this
    # example is the one that exercises the arm through the real construction
    # path rather than through a hand-assembled ladder no code produces.
    it "takes a triage rung, so a restricting capability set can reach the deny arm" do
      excluded = Class.new { def permits?(program) = program != "curl" }.new
      wired = described_class.for(queue:, tools:, journal:,
                                  triage: described_class::Triage.new(
                                    verdict: Lain::Shell::Verdict.new(capability_set: excluded)
                                  ))
      curl = Lain::Effect::ToolCall.new(tool_use_id: "tu_2", name: "bash", input: { "command" => "curl http://x" })

      expect(wired.call(curl, nil)).to be(false)
      expect(rulings.last).to include("rung" => "triage", "verdict" => "deny", "tool_use_id" => "tu_2")
    end
  end
end
