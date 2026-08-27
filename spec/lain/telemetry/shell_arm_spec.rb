# frozen_string_literal: true

require "json"
require "tmpdir"

# What arm a gated shell call ran on, as the Journal will hold it. The gate's own
# `shell verdict` line only exists when the ladder runs, and `/mode auto` replaces
# the ladder wholesale -- so this record is the only account of arm selection an
# unattended run leaves behind, and every example below is written from a reader
# of that run's point of view.
#
# This file is also the record's ONLY coverage, which is a fact about the record
# rather than an oversight: both whole-set sweeps build their subjects through
# `GenericBuild`, which passes one dummy value for every member, and `claim` is a
# forced member no generic builder can supply. The last example here pins that.
RSpec.describe Lain::Telemetry::ShellArm do
  subject(:event) do
    described_class.new(tool_use_id: "tu_1", verdict: :allow, arm: :term,
                        reason: "every stage is literal and fully understood",
                        term: [%w[cat README.md], %w[head -20]])
  end

  describe "an allowed term" do
    it "names the allow verdict and carries the term as written" do
      expect(event.tool_use_id).to eq("tu_1")
      expect(event.verdict).to eq(:allow)
      expect(event.arm).to eq(:term)
      expect(event.reason).to eq("every stage is literal and fully understood")
      expect(event.term).to eq([%w[cat README.md], %w[head -20]])
      expect(event).to be_allow
    end

    it "tags itself as a shell_arm record under String keys" do
      expect(event.journal_type).to eq("shell_arm")
      expect(event.to_journal.keys).to all(be_a(String))
      expect(event.to_journal).to include("type" => "shell_arm", "verdict" => :allow, "arm" => :term)
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(tool_use_id: "tu_1", verdict: :allow, arm: :term,
                                 reason: "every stage is literal and fully understood",
                                 term: [%w[cat README.md], %w[head -20]])

      expect(event).to eq(twin)
      expect(event.hash).to eq(twin.hash)
      expect(event).to be_deeply_frozen
    end

    # The gate and the tool both hand this record a Symbol today, but a record
    # rebuilt from a journal line holds the String the wire carried.
    it "takes the verdict and arm names as Strings, so a record rebuilt from a journal line is the same record" do
      from_wire = described_class.new(tool_use_id: +"tu_1", verdict: +"allow", arm: +"term",
                                      reason: +"every stage is literal and fully understood",
                                      term: [[+"cat", +"README.md"], [+"head", +"-20"]])

      expect(from_wire).to eq(event)
    end
  end

  # A real Journal, a real file, real NDJSON lines -- what the acceptance
  # criterion asks for, and strictly more than `JSON.parse(JSON.generate(...))`
  # proves: `Journal#encode` catches a serialization failure and writes a
  # `journal_error` record in the same slot, so a record that cannot be encoded
  # still yields a parseable line and would sail past an in-memory assertion.
  describe "written to the journal and read back" do
    let(:abstention) do
      described_class.new(tool_use_id: "tu_2", verdict: :abstain, arm: :string,
                          reason: "not fully understood: a quoted argument")
    end

    it "writes one parseable line per record, with the term verbatim and the claim on both" do
      lines = Dir.mktmpdir do |dir|
        path = File.join(dir, "session.ndjson")
        journal = Lain::Journal.open(path)
        journal.record(event)
        journal.record(abstention)
        journal.close
        File.readlines(path, chomp: true)
      end

      allowed, abstained = lines.map { |line| JSON.parse(line) }

      expect(allowed).to include(
        "type" => "shell_arm", "tool_use_id" => "tu_1", "verdict" => "allow", "arm" => "term",
        "reason" => "every stage is literal and fully understood",
        "term" => [%w[cat README.md], %w[head -20]], "claim" => Lain::Shell::Verdict::CLAIM
      )
      expect(allowed).to have_key("ts")
      expect(abstained).to include("verdict" => "abstain", "arm" => "string", "term" => [],
                                   "claim" => Lain::Shell::Verdict::CLAIM)
    end

    it "rebuilds from the line it wrote into a record equal to the one that wrote it" do
      line = Dir.mktmpdir do |dir|
        path = File.join(dir, "session.ndjson")
        journal = Lain::Journal.open(path)
        journal.record(event)
        journal.close
        File.readlines(path, chomp: true).first
      end

      fields = JSON.parse(line).slice("tool_use_id", "verdict", "arm", "reason", "term").transform_keys(&:to_sym)
      rebuilt = described_class.new(**fields)

      expect(rebuilt).to eq(event)
      expect(Ractor.shareable?(rebuilt)).to be(true)
    end
  end

  describe "an abstention" do
    subject(:event) do
      described_class.new(tool_use_id: "tu_2", verdict: :abstain, arm: :string,
                          reason: "not fully understood: a quoted argument")
    end

    it "carries the Null Object itself as its term, so reading it needs no nil guard" do
      expect(event.term).to eq([])
      expect(event.term).to equal(Lain::Shell::Verdict::NO_TERM)
      expect(event.to_journal.fetch("term")).to eq([])
    end

    it "refuses a nil term rather than storing one" do
      expect do
        described_class.new(tool_use_id: "tu_2", verdict: :abstain, arm: :string, reason: "not understood",
                            term: nil)
      end.to raise_error(ArgumentError, /term must be an Array of argv Arrays/)
    end

    # A record saying "no arm was chosen" while carrying the argv of a chosen one
    # tells a reader the opposite of what happened, and the record exists to answer
    # exactly that question.
    it "refuses a term on anything but an allow" do
      expect do
        described_class.new(tool_use_id: "tu_2", verdict: :abstain, arm: :string, reason: "not understood",
                            term: [%w[cat README.md]])
      end.to raise_error(ArgumentError, /term must be empty unless the verdict allows/)
    end
  end

  describe "a denial" do
    subject(:event) do
      described_class.new(tool_use_id: "tu_3", verdict: :deny, arm: :string,
                          reason: "the session excludes a program this command names: curl")
    end

    it "names the deny verdict, the string arm it ran on, and no term" do
      expect(event.verdict).to eq(:deny)
      expect(event.arm).to eq(:string)
      expect(event.term).to equal(Lain::Shell::Verdict::NO_TERM)
      expect(event).not_to be_allow
      expect(event).to be_deeply_frozen
    end
  end

  # The member without which this record was WRONG, not merely thin. `verdict`
  # answers what was decided and `arm` answers what ran, and the case that
  # separates them is reachable through a shipped flag: {Lain::Exec::Docker}
  # takes only a one-stage term, so under `--exec docker` an allowed PIPE falls
  # back to the model's own string and a shell runs it inside the container.
  describe "which arm actually ran" do
    it "records an allow that ran on the string arm, keeping the term it authorised but did not run" do
      diverged = described_class.new(tool_use_id: "tu_9", verdict: :allow, arm: :string,
                                     reason: "every stage is literal and fully understood",
                                     term: [%w[cat README.md], %w[head -20]])

      expect(diverged.verdict).to eq(:allow)
      expect(diverged.arm).to eq(:string)
      expect(diverged.term).to eq([%w[cat README.md], %w[head -20]])
      expect(diverged).to be_deeply_frozen
    end

    # `allow?` answers the VERDICT, which is why it is not enough on its own and
    # why its docstring used to say the opposite. Pinned so nobody re-reads it
    # as "ran as a term".
    it "still answers allow? on that record, because allow? is about the verdict" do
      diverged = described_class.new(tool_use_id: "tu_9", verdict: :allow, arm: :string,
                                     reason: "understood", term: [%w[cat README.md], %w[head -20]])

      expect(diverged).to be_allow
      expect(diverged.arm).not_to eq(:term)
    end

    # The predicate a reader counting deterministic runs reaches for, and the
    # reason it is not `allow?`: the natural spelling of "what fraction ran with
    # no shell" is a `count`, and over a bench run containing one `--exec docker`
    # pipe the two predicates give different answers. Only one of them is the
    # question that was asked.
    it "counts what ran, where allow? counts what was decided" do
      understood = { verdict: :allow, reason: "understood", term: [%w[cat a], %w[head -1]] }
      run = [described_class.new(tool_use_id: "tu_a", arm: :term, **understood),
             described_class.new(tool_use_id: "tu_b", arm: :string, **understood),
             described_class.new(tool_use_id: "tu_c", verdict: :abstain, arm: :string, reason: "quoted")]

      expect(run.count(&:term_arm?)).to eq(1)
      expect(run.count(&:allow?)).to eq(2)
    end

    it "distinguishes the two arms of one identical decision" do
      fields = { tool_use_id: "tu_9", verdict: :allow, reason: "understood", term: [%w[ls -la]] }

      expect(described_class.new(**fields, arm: :term)).not_to eq(described_class.new(**fields, arm: :string))
    end

    it "is shareable on the string arm too, whose term is a real one" do
      diverged = described_class.new(tool_use_id: +"tu_9", verdict: +"allow", arm: +"string",
                                     reason: +"understood", term: [[+"cat", +"a"], [+"head", +"-1"]])

      expect(Ractor.shareable?(diverged)).to be(true)
      expect(diverged.term.first.first).to equal(-"cat")
    end

    it "rejects an arm name nothing runs" do
      expect { described_class.new(tool_use_id: "tu_9", verdict: :allow, arm: :argv, reason: "ok", term: [%w[ls]]) }
        .to raise_error(ArgumentError, /arm must be term or string, got argv/)
    end

    it "rejects a nil arm, which is the one question this record exists to answer" do
      expect { described_class.new(tool_use_id: "tu_9", verdict: :allow, arm: nil, reason: "ok", term: [%w[ls]]) }
        .to raise_error(ArgumentError, /arm must name the arm the command ran on/)
    end

    # The asymmetry is deliberate: an allow on the string arm is real and
    # recorded, while a term arm under a verdict that authorised no term
    # describes something that cannot have happened.
    it "refuses the term arm under a verdict that authorised no term" do
      %i[abstain deny].each do |name|
        expect { described_class.new(tool_use_id: "tu_9", verdict: name, arm: :term, reason: "no") }
          .to raise_error(ArgumentError, /arm must be string unless the verdict allows/)
      end
    end

    it "refuses the term arm on an allow carrying no term to have run" do
      expect { described_class.new(tool_use_id: "tu_9", verdict: :allow, arm: :term, reason: "ok", term: []) }
        .to raise_error(ArgumentError, /arm must be string unless the verdict allows/)
    end
  end

  describe "the safety claim" do
    it "carries the same disclaimer every shell verdict record carries" do
      expect(event.claim).to equal(Lain::Shell::Verdict::CLAIM)
      expect(event.to_journal.fetch("claim")).to eq(Lain::Shell::Verdict::CLAIM)
    end

    it "carries it on a denial and an abstention too, not just on an allow" do
      %i[deny abstain].each do |name|
        other = described_class.new(tool_use_id: "tu_4", verdict: name, arm: :string, reason: "because")
        expect(other.claim).to eq(Lain::Shell::Verdict::CLAIM)
      end
    end

    # The claim is not a constructor argument at all, which is what keeps it from
    # being weakened by the caller that most wants to. The cost, and it is the
    # intended trade: `Data#with` re-calls `initialize` with EVERY member, so this
    # record has no working `#with` at all -- `with(reason:)` raises over `claim`
    # exactly as `with(claim:)` does. Nothing needs to copy a journal record.
    it "cannot be handed in, and no copy can rewrite it" do
      expect do
        described_class.new(tool_use_id: "tu_5", verdict: :allow, arm: :string, reason: "ok", term: [], claim: "safe")
      end
        .to raise_error(ArgumentError, /claim/)
      expect { event.with(claim: "this command is safe") }.to raise_error(ArgumentError, /claim/)
      expect { event.with(reason: "anything at all") }.to raise_error(ArgumentError, /claim/)
    end
  end

  describe "shareability" do
    it "holds no reachable mutable state, even built entirely from mutable Strings" do
      mutable = described_class.new(tool_use_id: +"tu_6", verdict: :allow, arm: +"term", reason: +"understood",
                                    term: [[+"grep", +"-n", +"foo", +"lib"], [+"wc", +"-l"]])

      expect(Ractor.shareable?(mutable)).to be(true)
      expect(mutable).to be_deeply_frozen
      expect(mutable.term.first).to be_frozen
      expect(mutable.term.first.first).to be_frozen
      expect(mutable.term.first.first).to equal(-"grep")
    end

    it "holds no reachable mutable state on an abstention, whose term is the shared Null Object" do
      one = described_class.new(tool_use_id: "tu_7", verdict: :abstain, arm: :string, reason: "x")
      another = described_class.new(tool_use_id: "tu_8", verdict: :abstain, arm: :string, reason: "y")

      expect(Ractor.shareable?(one)).to be(true)
      expect(one.term).to equal(another.term)
      expect(one.term).to equal(Lain::Shell::Verdict::NO_TERM)
    end
  end

  describe "refusals" do
    it "rejects a verdict name no Shell::Verdict decision answers to" do
      expect { described_class.new(tool_use_id: "tu_8", verdict: :approve, arm: :string, reason: "x") }
        .to raise_error(ArgumentError, /verdict must be allow, deny or abstain/)
    end

    it "rejects a nil verdict loudly" do
      expect { described_class.new(tool_use_id: "tu_8", verdict: nil, arm: :string, reason: "x") }
        .to raise_error(ArgumentError, /verdict must name the verdict the call was given/)
    end

    it "rejects a nil reason -- an arm with no reason is a record a reader cannot act on" do
      expect { described_class.new(tool_use_id: "tu_8", verdict: :allow, arm: :term, reason: nil, term: [%w[ls]]) }
        .to raise_error(ArgumentError, /reason must carry the verdict's reason/)
    end

    it "rejects a record that names no call, which nothing could join back to a tool_use block" do
      expect { described_class.new(tool_use_id: nil, verdict: :allow, arm: :term, reason: "ok", term: [%w[ls]]) }
        .to raise_error(ArgumentError, /tool_use_id must name the call this record is about/)
    end

    it "rejects a term that is not argv, so no reader has to guess at a stage's shape" do
      expect do
        described_class.new(tool_use_id: "tu_8", verdict: :allow, arm: :term, reason: "ok", term: ["cat README.md"])
      end
        .to raise_error(ArgumentError, /term must be an Array of argv Arrays/)
    end
  end

  # Why the examples above are not redundant with the two whole-set sweeps, and
  # must not be trimmed as though they were. `spec/journalable_surface_spec.rb`
  # and `spec/value_object_shareability_spec.rb` both build their subjects with
  # `GenericBuild`, which passes ONE dummy value for every member. `claim` is a
  # forced member -- no keyword accepts it -- so no generic builder can ever
  # construct this record, and it lands in each sweep's `unreached` list where
  # the only surviving assertion is that its name starts with "Lain::". Every
  # guarantee those sweeps make for other records is made HERE for this one.
  #
  # If this example ever fails because the record became buildable, the sweeps
  # have started covering it: delete this block and the note above it.
  describe "the coverage this file carries alone" do
    it "is in the sweeps' registry but is not one of the records they can build" do
      expect(GenericBuild.value_classes).to include(described_class)
      expect(GenericBuild.build(described_class)).to be_nil
    end
  end
end
