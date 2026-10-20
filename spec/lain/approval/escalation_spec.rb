# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
#
# The rungs here are duck-typed on purpose -- the ladder depends on `#name` and
# `#call(effect, context) -> Ruling` and on nothing else -- so none of them
# inherits from anything in lib/.
module EscalationSpecSupport
  Ruling = Lain::Approval::Escalation::Ruling

  # A rule with no opinion that says why, and one with neither.
  class Explaining < Lain::Approval::Rule
    def decide(_call) = nil
    def why_not(_call) = "cat resolved to /repo/bin/cat (project)"
  end

  class Mute < Lain::Approval::Rule
    def decide(_call) = nil
  end

  # Abstains, and raises when asked why.
  class BrokenExplainer < Lain::Approval::Rule
    def decide(_call) = nil
    def why_not(_call) = raise("broken")
  end

  # The mistake a rule author from a total-predicate world makes.
  class TrueRule < Lain::Approval::Rule
    def decide(_call) = true # rubocop:disable Naming/PredicateMethod
  end

  # Names itself once and refuses afterwards: the fault path must not ask a
  # rule anything it can fail at a second time.
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

  # A recorder on its way to a full disk.
  class RaisingRecorder
    def call(_fault, **) = raise(IOError, "the journal is broken")
  end

  # A rung handing up its own ladder's outcome, which decided nothing.
  class Undecided
    def name = "undecided"
    def call(_effect, _context) = Lain::Approval::Escalation::Rules.ladder([Explaining.new]).call(nil)
  end

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

  # A rule that OWNS an inner ladder and hands its raw outcome up, so the
  # rules ladder's edge poisons it as if its rungs were written flat.
  class Delegating < Lain::Approval::Rule
    def initialize(inner)
      super()
      @inner = inner
    end

    def decide(call) = @inner.call(call)
  end

  # Reads the input the way a real rule does, which is what detonates on the
  # values `Rule::Call.for` builds cleanly and cannot vouch for (a NUL byte, a
  # UTF-16LE String).
  class Reader < Lain::Approval::Rule
    def decide(call)
      allow(call, because: "read #{File.basename(call.input.command)}")
    end
  end

  # Keeps the subject the rung built, so an example can read what a real rule
  # would have been shown. Abstains, because the question is what reached the
  # rule and not what it decided.
  class Capturing < Lain::Approval::Rule
    attr_reader :seen

    def decide(call)
      @seen = call
      nil
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
    def <<(_entry) = raise(IOError, "the journal is gone")
  end

  # A real {Lain::Sensitivity} with every path it was asked about written down,
  # so an example can tell "the check ran and found nothing" from "no check ran
  # at all" -- which is the whole of the unparseable-command scenario.
  class Watched
    def initialize(sensitivity, paths)
      @sensitivity = sensitivity
      @paths = paths
    end

    def classify(path)
      @paths << path
      @sensitivity.classify(path)
    end
  end

  # The REAL factory a session's wiring hands the triage rung
  # ({Lain::CLI::Wiring::BoardBuild::Classifiers}), with every cwd and every
  # path it was asked about written down. Wrapped rather than reimplemented:
  # a second copy of a security-relevant TOTAL factory is one that can drift,
  # and these twenty examples would then be exercising the copy while a live
  # session ran on the other.
  class Classifiers
    attr_reader :cwds, :paths

    def initialize(home:, base:, rules: Lain::Sensitivity::Rules.empty)
      @factory = Lain::CLI::Wiring::BoardBuild::Classifiers.new(home:, cwd: base, rules:)
      @cwds = []
      @paths = []
    end

    def call(cwd)
      @cwds << cwd
      Watched.new(@factory.call(cwd), @paths)
    end
  end
end

RSpec.describe Lain::Approval::Escalation do
  def asked_as(name) = Lain::Approval::PolicySwitch::Requested.new(nil, name)

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:bash) { Lain::Tools::Bash.new }
  let(:tools) { Lain::Toolset.new([bash, Lain::Tools::ReadFile.new]) }
  let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "ls" }) }

  def ladder(*rungs) = described_class.new(rungs, journal:)

  def rulings = journal_records(journal_io, "escalation")

  def faults = journal_records(journal_io, "escalation_fault")

  def rules_rung(*rules, faults: journal)
    described_class::Rules.new(rules:, tools:, faults: described_class::Faults.new(faults))
  end

  describe "the seam it presents" do
    it "answers a Boolean, so Middleware::Gate's two-valued policy duck is unchanged" do
      expect(ladder(EscalationSpecSupport::Fixed.new("rule", :allow)).call(effect, nil)).to be(true)
      expect(ladder(EscalationSpecSupport::Fixed.new("rule", :deny)).call(effect, nil)).to be(false)
    end

    it "drops straight into a Gate as its policy" do
      gate = Lain::Middleware::Gate.new(policy: ladder(EscalationSpecSupport::Fixed.new("rule", :deny)))

      expect(dispatch_call(effect.name, effect.input, toolset: tools, layers: [gate]))
        .to have_attributes(is_error: true, content: /denied/)
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

    describe "a note an abstaining rung leaves for the human" do
      let(:note) { "cat resolved to /repo/bin/cat (project)" }
      let(:noting) do
        Class.new do
          def initialize(note) = @note = note
          def name = "noting"

          def call(_effect, _context)
            Lain::Approval::Escalation::Ruling.abstain(rung: name, because: "x", note: @note)
          end
        end.new(note)
      end

      def parked_notes(rung)
        Sync do |task|
          parked = task.async { over(rung).call(effect, nil) }
          pending = task.with_timeout(1) { queue.dequeue }
          pending.approve(surface: "tty")
          parked.wait
          pending.notes
        end
      end

      it "reaches the parked call" do
        expect(parked_notes(noting)).to eq([note])
      end

      it "reaches the approval_pending record" do
        parked_notes(noting)

        expect(Lain::Journal.records(journal_io.string.lines, type: "approval_pending").sole["notes"]).to eq([note])
      end

      it "gathers the notes of every abstaining rung, in order" do
        other = Class.new(noting.class) { def name = "again" }.new("second")
        parked = Sync do |task|
          wait = task.async { ladder(noting, other, described_class::Surfaces.new(queue)).call(effect, nil) }
          task.with_timeout(1) { queue.dequeue }.tap { _1.approve(surface: "tty") }.tap { wait.wait }
        end

        expect(parked.notes).to eq([note, "second"])
      end

      it "leaves a park with no note carrying none, and journals no notes key" do
        expect(parked_notes(EscalationSpecSupport::Silent.new)).to eq([])
        expect(Lain::Journal.records(journal_io.string.lines, type: "approval_pending").sole).not_to have_key("notes")
      end

      it "never reaches the model's refusal text" do
        ruling = Sync { over(noting).rule(effect, nil) }

        expect([ruling.told, ruling.said, ruling.reason].join).not_to include(note)
      end

      it "is journaled on the rung's ruling only when present" do
        over(noting).call(effect, nil)
        record = rulings.find { _1["rung"] == "noting" }

        expect(record["note"]).to eq(note)
        expect(rulings.reject { _1["rung"] == "noting" }).to all(satisfy { !_1.key?("note") })
      end
    end

    describe "Noted" do
      it "adds its note to the wrapped context's, and delegates the rest" do
        inner = Lain::Approval::Escalation::Noted.new(Struct.new(:requester).new("r"), "one")
        outer = Lain::Approval::Escalation::Noted.new(inner, "two")

        expect(outer.parked_because).to eq(%w[one two])
        expect(outer.requester).to eq("r")
      end
    end

    # The surfaces rung's ruling and the queue's decision are two records of one
    # call, and the call's id is what joins them: a person's allow honoured over
    # a fault is read off the pair.
    it "joins the queue's decision to the ladder's ruling by the call's id" do
      Sync do |task|
        parked = task.async { over(EscalationSpecSupport::Silent.new).call(effect, nil) }
        task.with_timeout(1) { queue.dequeue }.approve(surface: "tty")
        parked.wait
      end

      decision = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").first
      surfaced = rulings.find { |record| record["rung"] == described_class::Surfaces::NAME }
      expect(decision.fetch("tool_use_id")).to eq("tu_1")
      expect(surfaced.fetch("tool_use_id")).to eq(decision.fetch("tool_use_id"))
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
      [built.call(effect, nil), journal_records(journal_io, "escalation").last["rung"]]
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
  # `ask` and `auto` share every rung but the bottom one, so the session's own
  # refusals decide under both.
  describe "the two approval levels' ladders" do
    let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 0.05) }
    let(:classifiers) { EscalationSpecSupport::Classifiers.new(home: "/home/tester", base: "/srv/project") }

    def automatic(rules: [], triage: described_class::Triage.new)
      described_class.bypass(tools:, journal:, rules:, triage:)
    end

    it "labels the asking ladder ask, over the queue" do
      built = described_class.for(queue:, tools:, journal:)

      expect([built.label, built.map(&:name)]).to eq(["ask", %w[triage rules surfaces]])
    end

    it "labels the automatic ladder bypass, with the remainder where the queue would be" do
      expect([automatic.label, automatic.map(&:name)]).to eq(["bypass", %w[triage rules bypass]])
    end

    it "approves a call no rung above decided, attributed to the remainder" do
      expect(automatic.call(effect, nil)).to be(true)
      expect(rulings.last).to include("rung" => "bypass", "verdict" => "allow", "authority" => "automatic")
    end

    it "lets a triage deny decide under bypass" do
      read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                        input: { "command" => "cat /home/tester/.ssh/id_ed25519" })

      expect(automatic(triage: described_class::Triage.new(sensitivity: classifiers)).call(read, nil)).to be(false)
      expect(rulings.last).to include("rung" => "triage", "verdict" => "deny", "final" => true)
    end

    # Scenario: A shell read of the shadow file is refused under bypass
    it "denies a shell read of the shadow file as final under bypass, where nothing else refuses" do
      read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "cat /etc/shadow" })

      expect(automatic(triage: described_class::Triage.new(sensitivity: classifiers)).call(read, nil)).to be(false)
      expect(rulings.last).to include("rung" => "triage", "verdict" => "deny", "final" => true)
      expect(rulings.last["reason"]).to include('"/etc/shadow" is a system account or privilege file')
    end

    it "lets a rule deny decide under bypass" do
      expect(automatic(rules: [EscalationSpecSupport::Denier.new]).call(effect, nil)).to be(false)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny")
    end

    # The remainder is a machine, so an allow it reaches over a broken rule is
    # suppressed like any other automatic allow.
    it "suppresses its allow over a faulted rule, so a broken rule is never a free pass" do
      expect(automatic(rules: [EscalationSpecSupport::Raiser.new]).call(effect, nil)).to be(false)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny")
      expect(rulings.last["reason"]).to include(described_class::LAUNDERED)
    end
  end

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
        .to raise_error(Lain::Error, /unknown verdict :maybe; expected one of/)
    end

    it "is a deeply frozen value, so it is safe to journal and share" do
      expect(described_class::Ruling.allow(rung: "rules", because: "ok")).to be_deeply_frozen
      expect(described_class::Ruling.deny(rung: "triage", because: "no", final: true)).to be_deeply_frozen
    end

    it "is not final unless the rung that built it says so" do
      expect(described_class::Ruling.deny(rung: "triage", because: "no")).not_to be_final
      expect(described_class::Ruling.deny(rung: "triage", because: "no", final: true)).to be_final
    end

    # Which sentence the model read is a treatment variable, and the rung alone
    # cannot say it: a suppressed allow is journaled under the rung that
    # faulted, exactly as that rung's own final deny is.
    it "carries final on the journal record, and leaves the model's clause off it" do
      record = described_class::Ruling.deny(rung: "triage", because: "no", final: true, told: "the clause").record

      expect(record.keys).to eq(%w[verdict rung reason faulted authority final])
      expect(record["final"]).to be(true)
    end

    it "tells the model its reason unless the rung that built it names a narrower clause" do
      expect(described_class::Ruling.deny(rung: "rules", because: "the whole reason").told).to eq("the whole reason")
      expect(described_class::Ruling.deny(rung: "rules", because: "the whole reason", told: "a clause").told)
        .to eq("a clause")
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

    it "names the requester a child's context carries, on a rung's final deny and on the bottom" do
      child = asked_as("researcher")

      ladder(EscalationSpecSupport::Fixed.new("triage", :deny)).call(effect, child)
      ladder(EscalationSpecSupport::Silent.new).call(effect, child)

      expect(rulings.map { |record| record["requester"] }).to all(eq("researcher"))
    end

    it "names the main agent when the context names nobody" do
      ladder(EscalationSpecSupport::Fixed.new("triage", :deny)).call(effect, nil)

      expect(rulings.sole).to include("requester" => "agent")
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

    # The illustrating case, one level below the rung: a Rule that owns
    # an inner chain. Closing this at the rung only was not closing it.
    it "does not launder a fault through a rule that owns an inner chain" do
      inner = described_class::Rules.ladder([EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Allower.new])
      built = ladder(rules_rung(EscalationSpecSupport::Delegating.new(inner), EscalationSpecSupport::Allower.new))

      expect(built.call(effect, nil)).to be(false)
      expect(rulings.first).to include("rung" => "rules", "faulted" => true)
    end

    # A deny reached after a fault is still a deny -- and the stream must say
    # a fault happened, or a reader sees a clean denial that was not one.
    it "settles a post-fault deny as faulted" do
      built = ladder(rules_rung(EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Denier.new))

      ruling = built.rule(effect, nil)

      expect([ruling.deny?, ruling.fault?]).to eq([true, true])
    end

    it "reads a rung's own ladder that decided nothing as an abstention, keeping its reason as the note" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)

      ladder(EscalationSpecSupport::Undecided.new, described_class::Surfaces.new(queue)).call(effect, nil)

      expect(rulings.first).to include("rung" => "undecided", "verdict" => "abstain", "faulted" => false,
                                       "note" => "cat resolved to /repo/bin/cat (project)")
    end

    it "marks a post-fault deny as faulted in the record" do
      ladder(rules_rung(EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Denier.new)).call(effect, nil)

      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny", "faulted" => true)
    end
  end

  # Poison propagates across the DETERMINISTIC rungs and stops at the asking
  # rung. A human is not a later rule -- they are the authority the whole ladder
  # exists to escalate to, and suppressing their answer inverts it.
  describe "a fault, and who is entitled to answer over one" do
    def settled_by(rung, surface:, approve: true, context: nil, **authority)
      queue = Lain::Approval::Queue.new(journal:, timeout: 1)
      built = ladder(rung, described_class::Surfaces.new(queue))
      answer = nil
      Sync do |task|
        asked = task.async { answer = built.call(effect, context) }
        pending = task.with_timeout(1) { queue.dequeue }
        approve ? pending.approve(surface:, **authority) : pending.deny(surface:, **authority)
        task.with_timeout(1) { asked.wait }
      end
      answer
    end

    let(:faulting) { rules_rung(EscalationSpecSupport::Raiser.new) }

    it "honours a human surface's allow over a fault, rather than wedging the session" do
      expect(settled_by(faulting, surface: "tty", authority: :human)).to be(true)
    end

    it "records that allow as faulted, naming the rung that broke" do
      settled_by(faulting, surface: "tty", authority: :human)

      expect(rulings.last).to include("rung" => "surfaces", "verdict" => "allow", "faulted" => true)
      expect(rulings.last["reason"]).to include("rules")
    end

    it "names the requester on the human allow it honours over a fault" do
      settled_by(faulting, surface: "tty", authority: :human, context: asked_as("researcher"))

      expect(rulings.last).to include("verdict" => "allow", "faulted" => true, "requester" => "researcher")
    end

    it "names the requester on the automatic allow a fault suppresses" do
      ladder(faulting, EscalationSpecSupport::Fixed.new("auto", :allow))
        .call(effect, asked_as("researcher"))

      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny", "requester" => "researcher")
    end

    it "reads the terminal's fault surface as automatic, because nobody answered" do
      settled_by(faulting, surface: Lain::Frontend::ApprovalPolicy::FAULT_SURFACE, approve: false)

      expect(rulings.last).to include("rung" => "surfaces", "verdict" => "deny", "authority" => "automatic")
    end

    it "records an abandoned call as an automatic deny by the surfaces rung, and the stop still propagates" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 5)
      built = ladder(described_class::Surfaces.new(queue))
      stopped = nil
      Sync do |task|
        asked = task.async do
          built.call(effect, nil)
        rescue Async::Stop
          stopped = true
          raise
        end
        task.with_timeout(1) { queue.dequeue }
        asked.stop
      end

      expect(stopped).to be(true)
      expect(rulings.last).to include("rung" => "surfaces", "verdict" => "deny", "authority" => "automatic",
                                      "tool_use_id" => "tu_1")
    end

    it "suppresses the secret oracle's allow too: a local model is a machine, not a person" do
      expect(settled_by(faulting, surface: Lain::Approval::SecretSurface::SURFACE)).to be(false)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny")
    end

    # Scenario: a new machine surface cannot count as human by omission
    it "suppresses an allow from a surface the ladder has never heard of, answering as automatic" do
      expect(settled_by(faulting, surface: "unclassified_spec_surface", authority: :automatic)).to be(false)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny")
    end

    it "suppresses that allow when the surface declares no authority at all" do
      expect(settled_by(faulting, surface: "unclassified_spec_surface")).to be(false)
    end

    # Scenario: a human's approve after a fault still stands
    it "honours a human's allow from any surface name, and records the fault" do
      expect(settled_by(faulting, surface: "secret_oracle", authority: :human)).to be(true)
      expect(rulings.last).to include("rung" => "surfaces", "verdict" => "allow", "faulted" => true,
                                      "authority" => "human")
    end

    it "leaves a clean human allow unmarked" do
      expect(settled_by(EscalationSpecSupport::Silent.new, surface: "tty", authority: :human)).to be(true)
      expect(rulings.last).to include("rung" => "surfaces", "verdict" => "allow", "faulted" => false)
    end

    it "does not resurrect a human's denial into an approval" do
      expect(settled_by(faulting, surface: "tty", authority: :human, approve: false)).to be(false)
    end
  end

  # Scenario: a command tool's call carries the parsed term
  # Scenario: an abstention carries no term, visibly
  # Scenario: a non-command tool is unaffected
  #
  # The rung's `tools:` is the LIVE toolset here, holding the same
  # {Lain::Tools::Bash} an executor would dispatch, so what these examples read
  # is the parse that tool will pick its own arm from.
  describe "the subject the rules rung builds" do
    def captured(name, input)
      rule = EscalationSpecSupport::Capturing.new
      ladder(rules_rung(rule)).call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:), nil)
      rule.seen
    end

    it "carries the command's parsed term, stage by stage" do
      expect(captured("bash", { "command" => "cat README.md | head -20" }).term)
        .to eq(Lain::Shell::Term.of(%w[cat README.md], %w[head -20]))
    end

    it "carries an empty term when the verdict abstained" do
      expect(captured("bash", { "command" => "git log --oneline -5" }).term).to be_empty
    end

    it "says a term is absent rather than leaving a rule to infer it from emptiness" do
      expect(captured("bash", { "command" => "git log --oneline -5" })).not_to be_term
    end

    it "hands a tool whose input is no command the Call it always had" do
      expect(captured("read_file", { "path" => "README.md" }))
        .to have_attributes(tool_name: "read_file", term: Lain::Shell::Term::NONE, term?: false)
    end
  end

  # The MEASURED table: Rule::Call.for is not total, and a rescue list is
  # not a substitute for a total classifier.
  describe "the rules rung, over a rule that breaks" do
    it "faults a rule answering something that is not a decision, naming the error" do
      ruling = rules_rung(EscalationSpecSupport::TrueRule.new).call(effect, nil)

      expect([ruling.abstain?, ruling.fault?]).to eq([true, true])
      expect(faults.first).to include("rule" => "true_rule", "error" => "Lain::Approval::Ladder::NotADecision")
    end

    it "faults a rule that does not implement the seam" do
      expect(rules_rung(Lain::Approval::Rule.new).call(effect, nil)).to be_fault
      expect(faults.first).to include("error" => "Lain::Approval::Rule::NotImplemented")
    end

    it "faults a rule raising an anonymously-classed error, whose class name is nil" do
      nameless = Class.new(StandardError)
      rule = Class.new(EscalationSpecSupport::Mute) { define_method(:decide) { |_c| raise nameless, "boom" } }
      stub_const("EscalationSpecSupport::NamelessRaiser", rule)

      expect(rules_rung(rule.new).call(effect, nil)).to be_fault
      expect(faults.first["error"]).to include("Class")
    end

    it "names a rule by the name it gave when wired, never asking again at fault time" do
      rules_rung(EscalationSpecSupport::LateNamer.new).call(effect, nil)

      expect(faults.first).to include("rule" => "late_namer", "error" => "EscalationSpecSupport::LateNamer::Boom")
    end

    it "reports a rule that raises while explaining, and parks without its note" do
      ruling = rules_rung(EscalationSpecSupport::BrokenExplainer.new).call(effect, nil)

      expect([ruling.abstain?, ruling.fault?, ruling.note]).to eq([true, false, nil])
      expect(faults.map { _1["rule"] }).to eq(["broken_explainer"])
    end

    it "takes the next rule's note past one that raised while explaining" do
      ruling = rules_rung(EscalationSpecSupport::BrokenExplainer.new, EscalationSpecSupport::Explaining.new)
               .call(effect, nil)

      expect(ruling.note).to eq("cat resolved to /repo/bin/cat (project)")
    end

    it "still denies past a broken rule, flagged, when the recorder itself raises" do
      rung = described_class::Rules.new(rules: [EscalationSpecSupport::Raiser.new, EscalationSpecSupport::Denier.new],
                                        tools:, faults: EscalationSpecSupport::RaisingRecorder.new)

      ruling = rung.call(effect, nil)

      expect([ruling.deny?, ruling.final?, ruling.fault?]).to eq([true, true, true])
    end

    it "still abstains, and raises nothing, when the recorder raises over a broken explanation" do
      rung = described_class::Rules.new(rules: [EscalationSpecSupport::BrokenExplainer.new], tools:,
                                        faults: EscalationSpecSupport::RaisingRecorder.new)

      expect(rung.call(effect, nil)).to be_abstain
    end
  end

  describe "the rules rung, over a rule that says why it abstained" do
    it "abstains with the note" do
      ruling = rules_rung(EscalationSpecSupport::Explaining.new).call(effect, nil)

      expect(ruling).to be_abstain
      expect(ruling.note).to eq("cat resolved to /repo/bin/cat (project)")
    end

    it "leaves a rule with nothing to say without a note" do
      expect(rules_rung(EscalationSpecSupport::Mute.new).call(effect, nil).note)
        .to be_nil
    end
  end

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

  # Shell::Verdict is three-valued and its allow claims only "literal and fully
  # understood", never "safe".
  describe "the triage rung, over Shell::Verdict" do
    def triaged(command, capability_set: Lain::Shell::Verdict::AnyProgram.new)
      rung = described_class::Triage.new(verdict: Lain::Shell::Verdict.new(capability_set:))
      ladder(rung).call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                                   input: { "command" => command }), nil)
    end

    it "denies a program the session's shell exclusion lists, which nothing enforced before" do
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

  # The one arm that refuses on its own without a capability set: a command
  # whose ARGV names a path {Lain::Sensitivity} denies. It hangs off the allow
  # branch because that is the only decision carrying a term to read.
  describe "the triage rung's argv path check" do
    let(:home) { "/home/tester" }
    let(:base) { "/srv/project" }
    let(:classifiers) { EscalationSpecSupport::Classifiers.new(home:, base:) }

    def triaged(command, cwd: nil, sensitivity: classifiers, verdict: Lain::Shell::Verdict.new,
                policy: Lain::Sensitivity::Policy::Null.instance, context: nil)
      rung = described_class::Triage.new(sensitivity:, verdict:, policy:)
      input = { "command" => command, "cwd" => cwd }.compact
      ladder(rung).call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:), context)
    end

    # A checkout under home, which is where the bare-word names were measured.
    def in_checkout(command)
      checkout = "#{home}/checkout"
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: checkout, root: checkout),
                                             home:, root: checkout)
      triaged(command, policy:, context: Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: checkout, env: {})))
    end

    # Scenario: a literal read of a denied path is denied
    it "denies a literal read of a protected path, and names it" do
      expect(triaged("cat #{home}/.ssh/id_ed25519")).to be(false)

      expect(rulings.first).to include("rung" => "triage", "verdict" => "deny", "faulted" => false)
      expect(rulings.first["reason"]).to include("#{home}/.ssh/id_ed25519", described_class::Triage::PROTECTED)
    end

    it "reads every stage of a pipeline, not merely the one that leads it" do
      expect(triaged("cat notes.txt | grep -f #{home}/.netrc")).to be(false)

      expect(rulings.first).to include("verdict" => "deny")
      expect(rulings.first["reason"]).to include("#{home}/.netrc")
    end

    # The case that separates the argv from the text on the ALLOW branch, where
    # every other allowed command splits the same either way: an unspaced pipe
    # merges the path into the next program name (`"#{home}/.netrc|wc"`), which
    # matches no rule. Reading the words the parser found finds it; splitting
    # the string does not.
    it "reads a path the raw text merges into the next program at an unspaced pipe" do
      expect(triaged("cat #{home}/.netrc|wc -l")).to be(false)

      expect(rulings.first).to include("verdict" => "deny")
      expect(rulings.first["reason"]).to include("#{home}/.netrc\" is")
    end

    # {Shell::Verdict::Doubts} bounds its own offender lists for this reason: a
    # Journal line wants the shape, not the census. The BOUND is on the
    # rendering only -- every word is still classified, or a refusal could hide
    # behind eight harmless ones.
    it "bounds how many protected paths one reason names" do
      named = (1..12).map { |nth| "#{home}/#{nth}/.netrc" }

      expect(triaged("cat #{named.join(" ")}")).to be(false)

      expect(rulings.first).to include("verdict" => "deny")
      expect(rulings.first["reason"].scan("is a protected path").size).to eq(described_class::Triage::MAX_NAMED)
      expect(classifiers.paths).to include(*named)
    end

    # Scenario: an ordinary command still abstains
    it "abstains on an ordinary command, exactly as it did before this arm existed" do
      expect(triaged("ls -la")).to be(false)

      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
      expect(rulings.first["reason"]).to include(described_class::Triage::NOT_SAFE)
      expect(classifiers.paths)
        .to eq(Lain::Shell::Named.of("ls -la", cwd: Lain::Session.cwd_of(nil), home: nil).paths.map(&:resolved))
    end

    # Scenario: an unparseable command still abstains
    it "attempts no path check at all when neither the verdict nor the path reader could read the command" do
      expect(triaged("for f in *.key; do cat $f; done")).to be(false)

      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
      expect(classifiers.paths).to be_empty
      expect(classifiers.cwds).to be_empty
    end

    # Scenario: a gated path is not denied here
    #
    # Written as a PATH deliberately: a bare `.env` would abstain under
    # {Triage::PATHLIKE} whatever this rung thought of gating, so it could not
    # tell "gated is not denied" from "bare is not denied".
    it "leaves a gated path to the human rather than denying it" do
      expect(triaged("cat ./.env")).to be(false)

      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
      expect(rulings.first["reason"]).to include(described_class::Triage::NOT_SAFE)
      expect(classifiers.paths).to include(File.join(Lain::Session.cwd_of(nil), ".env"))
    end

    # Scenario: the deny is read off argv, not the string
    #
    # A single-quoted word is literal, so bash opens the key the doubted
    # command names; an expansion is not, so nothing is read off it.
    it "denies off the named paths and never off the raw command text" do
      expect(triaged("cat '#{home}/.ssh/id_ed25519'")).to be(false)
      expect(triaged(%(cat "$HOME/.ssh/id_ed25519"))).to be(false)

      expect(rulings.select { _1["rung"] == "triage" }.map { _1["verdict"] }).to eq(%w[deny abstain])
      expect(classifiers.paths).to eq(["#{home}/.ssh/id_ed25519"])
    end

    # A home-anchored name is the pair that shows WHOSE cwd a relative word
    # resolves against: `./Cookies` is denied under the injected home and
    # ordinary anywhere else, so a rung reading the session's cwd instead of
    # the call's answers one of these two wrong.
    it "anchors a relative path on the cwd the CALL named" do
      expect(triaged("cat ./Cookies", cwd: home)).to be(false)

      expect(rulings.first).to include("verdict" => "deny")
      expect(classifiers.cwds).to eq([home])
    end

    it "does not anchor a relative path under home when the call runs elsewhere" do
      expect(triaged("cat ./Cookies")).to be(false)

      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
      expect(classifiers.cwds).to eq([nil])
    end

    # The panel's ruling. A word with no separator and no tilde is not written
    # as a path, so it is not evidence about one -- and denying on it would
    # make `grep -n Cookies lib/lain/sensitivity.rb` unrunnable from a checkout
    # under `$HOME` with nothing anywhere able to lift it, `[sensitivity]
    # exempt` included (it subtracts from the gated half only).
    it "does not refuse a bare word that merely matches a protected name" do
      expect(in_checkout("grep -n Cookies lib/lain/sensitivity.rb")).to be(false)

      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
      expect(rulings.first["reason"]).to include(described_class::Triage::BARE, '"Cookies"')
    end

    # `.netrc`, `.gnupg`, `.password-store` and `*.kdbx` match from ANY cwd, so
    # the bare-word class is not confined to a session sitting in `$HOME`.
    it "leaves the any-cwd names bare too, so a checkout stays greppable from anywhere" do
      expect(in_checkout("grep -rn .netrc lib spec")).to be(false)

      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
      expect(rulings.first["reason"]).to include(described_class::Triage::BARE, '".netrc"')
    end

    # Shell::Verdict abstains on any word carrying a `~`, so the tilde half of
    # the ruling takes an injected verdict and a project that denied its own
    # home's basename to observe. `~user` is opaque to the path reader and is
    # not refused here; the verdict's abstention still sends it to a human.
    it "treats a tilde word as written-as-a-path even with no separator in it" do
      denied = Lain::Sensitivity::Rules.from({ "denied" => [File.basename(home)] })
      allowing = lambda do |_command|
        Lain::Shell::Verdict::Decision.new(name: :allow, reason: "spec allows", term: Lain::Shell::Term.of(%w[cat ~]))
      end
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: base), home:)

      answer = triaged("cat ~", verdict: allowing, policy:,
                                sensitivity: EscalationSpecSupport::Classifiers.new(home:, base:, rules: denied))

      expect(answer).to be(false)
      expect(rulings.first).to include("verdict" => "deny")
      expect(rulings.first["reason"]).to include('"~"')
    end

    it "still refuses the same name the moment it is written as a path" do
      expect(triaged("grep -rn ./.netrc lib spec")).to be(false)

      expect(rulings.first).to include("verdict" => "deny")
      expect(rulings.first["reason"]).to include(described_class::Triage::PROTECTED, '"./.netrc"')
    end

    # `cwd` is MODEL-CONTROLLED (`bash.rb:50`), and `Sensitivity.new` refuses a
    # relative one. A factory that let that raise would hand the model a
    # one-argument disarm: the raise is a fault, a fault suppresses no DENY --
    # it replaces one with an abstention -- and a human then approves the very
    # read the rung existed to refuse.
    it "still refuses when the model names a relative cwd, and faults on nothing" do
      expect(triaged("cat #{home}/.ssh/id_ed25519", cwd: "src")).to be(false)

      expect(rulings.first).to include("verdict" => "deny", "faulted" => false)
      expect(faults).to be_empty
      expect(classifiers.cwds).to eq(["src"])
    end

    # A cwd nothing can resolve costs the RELATIVE anchoring and nothing else.
    # It must not cost the refusal: `cwd` is model-controlled, so a fallback
    # that protected nothing would let one JSON field turn this deny back into
    # the ordinary approval the rung exists to prevent -- and an ABSOLUTE path
    # never needed the call's cwd to classify in the first place. The fallback
    # is the session's own classifier, so the deny stands and nothing faults.
    it "still denies, without faulting, when the cwd cannot be resolved at all" do
      expect(triaged("cat #{home}/.ssh/id_ed25519", cwd: "bad\0dir")).to be(false)

      expect(rulings.first).to include("verdict" => "deny", "faulted" => false)
      expect(faults).to be_empty
    end

    # A doubted command under the bypass ladder: the one place an opaque reading
    # that skipped its absolute words would turn a deny into an approval.
    describe "a doubted command whose cwd cannot be resolved, under bypass" do
      let(:doubting) do
        lambda do |_command|
          Lain::Shell::Verdict::Decision.new(name: :abstain, reason: "spec doubts", term: Lain::Shell::Verdict::NO_TERM)
        end
      end

      def bypassed(cwd)
        sensitivity = Lain::CLI::Wiring::BoardBuild::Classifiers.new(home:, cwd: base,
                                                                     rules: Lain::Sensitivity::Rules.empty)
        triage = described_class::Triage.new(sensitivity:, verdict: doubting)
        bypass = described_class.bypass(tools: Lain::Toolset.new([Lain::Tools::Bash.new]), journal:, triage:)
        input = { "command" => "cat #{home}/.ssh/id_ed25519", "cwd" => cwd }.compact
        bypass.call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:), nil)
      end

      [nil, "bad\0dir", 3].each do |cwd|
        it "still denies a protected absolute path with the cwd #{cwd.inspect}" do
          expect(bypassed(cwd)).to be(false)
        end
      end
    end

    # The default is inert for {Triage}'s other deny arm's reason: nothing in
    # `lib/` knows a home where a ladder is built, so an unwired session
    # behaves exactly as it did.
    it "protects no path at all until a session wires a classifier" do
      expect(triaged("cat #{home}/.ssh/id_ed25519", sensitivity: described_class::Triage::AnyPath.new)).to be(false)

      expect(rulings.first).to include("verdict" => "abstain", "faulted" => false)
    end

    # A leased worker is judged over the factory its own environment answers,
    # and a session that protects nothing protects nothing for its workers too.
    it "answers the same inert factory for every worker a session leases" do
      factory = described_class::Triage::AnyPath.new
      leased = Lain::WorkerEnv.new(cwd: "/srv/lease", env: {}, checkout: "/srv/lease")

      expect(factory.for(leased)).to be(factory)
    end
  end

  # A word is judged where it lands as well as by its name, so a link in the
  # project is refused for the file it opens.
  describe "the triage rung's landing check" do
    around do |example|
      Dir.mktmpdir("lain-triage-landing") do |dir|
        @project = File.realpath(dir)
        example.run
      end
    end

    def ruled(command, cwd: nil, root: @project, home: "/home/tester", checkout: nil, below: [])
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
      rung = described_class::Triage.new(sensitivity: EscalationSpecSupport::Classifiers.new(home:, base: root),
                                         policy:)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: checkout || root, env: {}, checkout:))
      input = { "command" => command, "cwd" => cwd }.compact
      ladder(rung, *below).rule(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:), session)
    end

    def shadow_link(name = "shadowlink") = File.symlink("/etc/shadow", File.join(@project, name))

    # Scenario: a link to /etc/shadow is refused on the bash route under every level
    it "refuses a bare word linked to the shadow file finally, naming the file it lands on" do
      File.symlink("/etc/shadow", File.join(@project, "shadowlink"))

      ruling = ruled("cat shadowlink")

      expect(ruling).to be_deny.and be_final
      expect(ruling.told).to include('"shadowlink"', "/etc/shadow")
    end

    # Scenario: a project's own etc/shadow is not that file
    it "does not refuse a project's own etc/shadow as an account file" do
      FileUtils.mkdir_p(File.join(@project, "etc"))
      File.write(File.join(@project, "etc", "shadow"), "not the account database\n")

      ruled("cat etc/shadow")

      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
    end

    # Scenario: the /proc/self/root alias is refused
    it "refuses the /proc/self/root alias of the sudo policy finally" do
      ruling = ruled("cat /proc/self/root/etc/sudoers")

      expect(ruling).to be_deny.and be_final
      expect(ruling.told).to include("/etc/sudoers")
    end

    # The verdict abstains on a quote, a redirect and a program it does not
    # know, but the paths are still literal, so where they land is still read.
    it "refuses a link the verdict abstained on, when every path is still literal" do
      shadow_link

      rulings = ["cat 'shadowlink'", "cat < shadowlink", "sed -n 1p shadowlink"].map { ruled(_1) }

      expect(rulings).to all(be_deny.and(be_final))
      expect(rulings.map(&:told)).to all(include("/etc/shadow"))
    end

    it "reads /proc/self/cwd as the directory the command runs in" do
      shadow_link

      rulings = %w[/proc/self/cwd/shadowlink /proc/thread-self/cwd/shadowlink].map { ruled("cat #{_1}") }

      expect(rulings).to all(be_deny.and(be_final))
    end

    it "reads /proc/self/cwd after a cd as the directory that cd moved to" do
      FileUtils.mkdir_p(File.join(@project, "sub"))
      File.symlink("/etc/shadow", File.join(@project, "sub", "shadowlink"))

      expect(ruled("cd sub && cat /proc/self/cwd/shadowlink")).to be_deny.and be_final
    end

    # Outside the project a bare word is not a project file that shares a
    # protected name, so its name alone refuses.
    it "refuses a bare word naming a protected file outside the project, however the directory was reached" do
      rulings = [ruled("cd /etc && cat shadow"), ruled("cat shadow", cwd: "/etc")]

      expect(rulings).to all(be_deny.and(be_final))
    end

    # A human removes a planted link by hand: naming the link refuses whatever
    # the program does with it.
    it "refuses a program that would not follow the link as well" do
      shadow_link

      expect(%w[rm readlink].map { ruled("#{_1} shadowlink") }).to all(be_deny.and(be_final))
    end

    it "judges where a word lands before its name, so a link under a protected name still refuses" do
      shadow_link(".netrc")

      ruling = ruled("cat .netrc")

      expect(ruling).to be_deny.and be_final
      expect(ruling.told).to include('".netrc" lands on /etc/shadow')
    end

    it "does not count a link above the project as a word's landing" do
      FileUtils.mkdir_p(File.join(@project, "data", "proj", "lib"))
      File.symlink(File.join(@project, "data"), File.join(@project, "work"))

      ruled("grep -rn .netrc lib", root: File.join(@project, "work", "proj"))

      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
    end

    # The same file under a home reached through a link is the name already
    # judged, so the refusal reports the name rather than a landing.
    it "reports a path under a linked home by its name, not as a landing" do
      FileUtils.mkdir_p(File.join(@project, "var", "u"))
      File.symlink(File.join(@project, "var"), File.join(@project, "h"))
      home = File.join(@project, "h", "u")
      root = File.join(@project, "repo").tap { FileUtils.mkdir_p(_1) }

      ruling = ruled("cat #{home}/.netrc", root:, home:)

      expect(ruling).to be_deny.and be_final
      expect(ruling.told).to include("is a protected path")
      expect(ruling.told).not_to include("lands on")
    end

    # The kernel follows a cwd that links to nothing when the target appears,
    # so the rung reads it rather than failing on it.
    it "judges a word under a cwd that links to nothing without faulting" do
      File.symlink(File.join(@project, "gone"), File.join(@project, "dangling"))

      ruled("cat notes.txt", cwd: "dangling")

      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
    end

    # A leased worker's checkout lies outside the board's root, and its own
    # files share the protected names a checkout's do.
    it "counts a leased worker's own checkout as inside the project" do
      home = File.join(@project, "home")
      root = File.join(home, "dev", "proj").tap { FileUtils.mkdir_p(File.join(_1, "lib")) }
      lease = File.join(home, "worktrees", "proj-w1").tap { FileUtils.mkdir_p(File.join(_1, "lib")) }

      ["grep -rn .netrc lib", "grep -rn Cookies lib"].each { ruled(_1, root:, home:, checkout: lease) }

      expect(rulings.select { _1["rung"] == "triage" }.map { _1["verdict"] }).to eq(%w[abstain abstain])
    end

    it "counts a directory denied in its own right as outside the project" do
      home = File.join(@project, "home")
      FileUtils.mkdir_p(File.join(home, ".gnupg"))
      root = File.join(@project, "repo").tap { FileUtils.mkdir_p(_1) }

      expect(ruled("cat pubring.kbx", cwd: File.join(home, ".gnupg"), root:, home:)).to be_deny.and be_final
    end

    # Outside is where a directory lies, not the reason its name is judged
    # for: a home directory gated by its own name is still outside the project.
    %w[Documents .ssh].each do |dir|
      it "refuses a bare protected name from ~/#{dir} finally, though bypass sits below" do
        home = File.join(@project, "home")
        cwd = File.join(home, dir).tap { FileUtils.mkdir_p(_1) }
        root = File.join(@project, "repo").tap { FileUtils.mkdir_p(_1) }

        ruling = ruled("cat .netrc", cwd:, root:, home:, below: [described_class::Bypass.new])

        expect(ruling).to be_deny.and be_final
        expect(ruling.rung).to eq("triage")
      end
    end

    # A project link into a home reached through a link: the real spelling is
    # judged too, so the protected file behind it refuses.
    it "refuses a path through a project link into a home reached through a link" do
      FileUtils.mkdir_p(File.join(@project, "var", "u", ".ssh"))
      File.symlink(File.join(@project, "var"), File.join(@project, "h2"))
      root = File.join(@project, "repo").tap { FileUtils.mkdir_p(_1) }
      File.symlink(File.join(@project, "var", "u"), File.join(root, "h"))

      ruling = ruled("cat h/.ssh/id_rsa", root:, home: File.join(@project, "h2", "u"))

      expect(ruling).to be_deny.and be_final
    end

    it "leaves a bare word whose name alone is protected to a human" do
      ruled("grep -rn .netrc lib")

      expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
    end
  end

  # The settled Ruling, handed to the Gate whole, so a refusal the session
  # decided before anyone could be asked can say why -- and say that asking
  # again is pointless -- where a human's no stays a plain no.
  describe "#rule, the settled ruling a Gate renders" do
    let(:home) { "/home/tester" }
    let(:classifiers) { EscalationSpecSupport::Classifiers.new(home:, base: "/srv/project") }
    let(:excluding_curl) do
      Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["curl"]))
    end

    def bash_call(command)
      Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                 input: { "command" => command })
    end

    def gated_through(policy, command)
      gate = Lain::Middleware::Gate.new(policy:)
      dispatch_call("bash", { "command" => command }, toolset: tools, layers: [gate])
    end

    it "answers the ruling the ladder settled on, not merely whether it allows" do
      ruling = ladder(EscalationSpecSupport::Silent.new, EscalationSpecSupport::Fixed.new("rules", :deny))
               .rule(effect, nil)

      expect(ruling).to be_a(described_class::Ruling).and have_attributes(verdict: :deny, rung: "rules")
    end

    it "marks a triage deny over a protected path as one no approval lifts" do
      reading_a_key = bash_call("cat #{home}/.ssh/id_rsa")
      ruling = ladder(described_class::Triage.new(sensitivity: classifiers)).rule(reading_a_key, nil)

      expect(ruling).to be_deny.and be_final
      expect(ruling).not_to be_liftable
      expect(ruling.reason).to include("#{home}/.ssh/id_rsa")
    end

    it "marks a triage deny over a project exclusion as one no approval lifts" do
      ruling = ladder(described_class::Triage.new(verdict: excluding_curl)).rule(bash_call("curl http://x"), nil)

      expect(ruling).to be_deny.and be_final
      expect(ruling.reason).to include('"curl"')
    end

    it "marks a rules deny as one no approval lifts" do
      expect(ladder(rules_rung(EscalationSpecSupport::Denier.new)).rule(effect, nil)).to be_deny.and be_final
    end

    # The journal reason prefixes the rule's name onto its own reason; a model
    # reading that sees the name twice and learns nothing more.
    it "tells the model a rules deny's own reason, and journals it attributed to the rule" do
      ruling = ladder(rules_rung(EscalationSpecSupport::Denier.new)).rule(effect, nil)

      expect(ruling.told).to eq("spec denies everything")
      expect(rulings.last["reason"]).to eq("denier: spec denies everything")
    end

    it "tells the model a triage deny only the clause it refused on, and journals the whole reason" do
      reading_a_key = bash_call("cat #{home}/.ssh/id_rsa")
      path = ladder(described_class::Triage.new(sensitivity: classifiers)).rule(reading_a_key, nil)
      excluded = ladder(described_class::Triage.new(verdict: excluding_curl)).rule(bash_call("curl http://x"), nil)

      expect(path.told).to eq(%(#{described_class::Triage::TOLD_PROTECTED}: "#{home}/.ssh/id_rsa" is a protected path))
      expect(excluded.told).to eq(%(the session's shell exclusion covers bash commands and excludes: "curl"))
      expect(rulings.map { |record| record["reason"] }).to all(include(Lain::Shell::Verdict::CLAIM))
      expect(rulings.first["reason"]).to include("shell verdict allow", described_class::Triage::PROTECTED)
    end

    it "does not mark a surface's refusal final, since a human or a closed window can answer otherwise next time" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 0.01)

      ruling = Sync { ladder(described_class::Surfaces.new(queue)).rule(effect, nil) }

      expect(ruling).to be_deny
      expect(ruling).not_to be_final
    end

    it "does not mark the fail-closed bottom final" do
      expect(ladder(EscalationSpecSupport::Silent.new).rule(effect, nil)).not_to be_final
    end

    # Attributed to the rules rung, but no rule refused: an automatic allow was
    # suppressed over a fault, and a human's allow would have stood.
    it "does not mark a suppressed allow final, though it names the rung that faulted" do
      ruling = ladder(rules_rung(EscalationSpecSupport::Raiser.new), EscalationSpecSupport::Fixed.new("bypass", :allow))
               .rule(effect, nil)

      expect(ruling).to have_attributes(verdict: :deny, rung: "rules")
      expect(ruling).not_to be_final
      expect(rulings.last).to include("rung" => "rules", "verdict" => "deny", "final" => false)
    end

    # Scenario: a protected-path deny says why
    it "reaches the model through a Gate naming the protected path and saying no approval will lift it" do
      told = gated_through(ladder(described_class::Triage.new(sensitivity: classifiers)), "cat #{home}/.ssh/id_rsa")

      expect(told).to have_attributes(is_error: true)
      expect(told.content).to include("#{home}/.ssh/id_rsa", "no approval will lift this")
    end

    # Scenario: a project exclusion deny names the exclusion
    it "reaches the model through a Gate naming the excluded program" do
      told = gated_through(ladder(described_class::Triage.new(verdict: excluding_curl)), "curl http://x")

      expect(told.content).to include('"curl"', "excludes", "no approval will lift this")
    end
  end

  # A command whose automatically approved output held a credential is barred
  # from automatic approval, and the bar rides the context the call is judged
  # in, so the ladder's deterministic rungs stay what they were.
  describe "a context barring automatic approval" do
    let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 0.05) }

    def carried(barred:) = Lain::Middleware::WithholdAutomaticOutput::Carried.new(:the_session, barred:)

    it "reads an automatic allow for a barred command as an abstention, so the surfaces are asked" do
      Sync do |task|
        built = ladder(EscalationSpecSupport::Fixed.new("rules", :allow), described_class::Surfaces.new(queue))
        parked = task.async { built.rule(effect, carried(barred: true)) }
        pending = task.with_timeout(1) { queue.dequeue }
        pending.approve(surface: Lain::Frontend::ApprovalPolicy::SURFACE, authority: :human)

        expect(task.with_timeout(1) { parked.wait }).to be_allow.and be_human
        expect(rulings.first).to include("rung" => "rules", "verdict" => "abstain")
        expect(rulings.first["reason"]).to include(described_class::BARRED)
      end
    end

    it "still settles an automatic allow for a command nobody barred" do
      built = ladder(EscalationSpecSupport::Fixed.new("rules", :allow), EscalationSpecSupport::Tripwire.new)

      expect(built.rule(effect, carried(barred: false))).to be_allow
    end

    it "refuses a barred command under bypass approval, where no human is asked" do
      ruling = described_class.bypass(tools:, journal:).rule(effect, carried(barred: true))

      expect(ruling).to have_attributes(verdict: :deny, rung: described_class::Bypass::NAME)
      expect(rulings.last).to include("rung" => described_class::Bypass::NAME, "verdict" => "deny")
    end

    # The model cannot switch modes, so its refusal holds only what it can act
    # on; the human's line says how to reach a human.
    it "tells the model no approval is possible and not to re-send, without the mode switch" do
      ruling = described_class.bypass(tools:, journal:).rule(effect, carried(barred: true))

      expect(ruling).to be_final
      expect(ruling.told).to include("no approval is possible while approval is bypass", "do not re-send it")
      expect(ruling.told).not_to include("/mode ask")
      expect(ruling.reason).to include("switch to /mode ask")
    end

    it "marks the bypass refusal of a barred command as one a human in ask could lift" do
      ruling = described_class.bypass(tools:, journal:).rule(effect, carried(barred: true))

      expect(ruling).to be_liftable
    end

    it "tells the model about a barred bypass refusal once, without saying no approval will lift it" do
      gate = Lain::Middleware::Gate.new(policy: described_class.bypass(tools:, journal:))
      told = dispatch_call("bash", { "command" => "ls" }, toolset: tools, layers: [gate],
                                                          context: carried(barred: true))

      expect(told.content).to include("do not re-send it")
      expect(told.content).not_to include("no approval will lift this")
      expect(told.content.scan("do not re-send").size).to eq(1)
    end

    it "leaves a deny for a barred command a deny" do
      ruling = ladder(EscalationSpecSupport::Fixed.new("rules", :deny)).rule(effect, carried(barred: true))

      expect(ruling).to have_attributes(verdict: :deny, rung: "rules")
    end

    it "judges a context that carries no bar exactly as before" do
      expect(ladder(EscalationSpecSupport::Fixed.new("rules", :allow)).rule(effect, :the_session)).to be_allow
    end
  end

  describe "the rule that decided" do
    let(:allower) { EscalationSpecSupport::Allower.new }

    it "names the rule behind a rules rung allow, on the ruling and on its record" do
      ruling = ladder(rules_rung(allower)).rule(effect, nil)

      expect(ruling.rule).to eq(allower.name)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "allow", "rule" => allower.name)
    end

    it "names the rule behind a rules rung deny" do
      denier = EscalationSpecSupport::Denier.new

      expect(ladder(rules_rung(denier)).rule(effect, nil).rule).to eq(denier.name)
    end

    it "names no rule on a ruling no rule made, and leaves the key off its record" do
      ruling = ladder(EscalationSpecSupport::Fixed.new("judge", :allow)).rule(effect, nil)

      expect(ruling.rule).to be_nil
      expect(rulings.sole).not_to have_key("rule")
    end

    it "keeps the rule on the abstention a bar turns its allow into" do
      barred = Lain::Middleware::WithholdAutomaticOutput::Carried.new(:the_session, barred: true)

      ladder(rules_rung(allower)).rule(effect, barred)

      expect(rulings.first).to include("verdict" => "abstain", "rule" => allower.name)
    end
  end

  describe ".for, which is how a session wires it" do
    let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 0.05) }
    let(:built) { described_class.for(queue:, tools:, journal:, rules: [EscalationSpecSupport::Raiser.new]) }

    it "orders the rungs triage, rules, surfaces -- deterministic before the human" do
      expect(built.map(&:name)).to eq(%w[triage rules surfaces])
    end

    it "wires a real fault recorder, never a silent one" do
      built.call(effect, nil)

      expect(faults.first).to include("rule" => "raiser", "tool" => "bash", "tool_use_id" => "tu_1")
    end

    # The triage rung's DENY arm is unreachable as this repo wires it --
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
