# frozen_string_literal: true

require "stringio"

# The review surface's four journal records. They are Journalable Data values
# like every other Lain::Telemetry event, and their `type` strings are DURABLE
# discriminators a later reader joins on, so every one is pinned as a literal
# here rather than derived -- a spec that recomputes `underscore` would agree
# with a rename that broke every recorded journal.
#
# Three of the four are invisible to spec/journalable_surface_spec.rb's registry
# sweep: their guards refuse every uniform dummy GenericBuild offers, so they
# land on that sweep's named blind-spot list beside eight of the nine epic
# records. The uniqueness example at the bottom of this file is what covers them,
# and it is not a duplicate of the global one -- it is the same claim asked about
# the records the global one cannot build.
RSpec.shared_examples "a review journal record" do |discriminator|
  it "journals under the underscored basename of its class" do
    expect(record.journal_type).to eq(discriminator)
    expect(described_class::JOURNAL_TYPE).to eq(discriminator)
  end

  # AC1, in its strong form: not `include`, but the whole record back. The
  # reconstruction is the half that catches a member the wire cannot carry -- a
  # Symbol side journals as a String, and a record that cannot be rebuilt from
  # its own line is one no session can replay.
  it "round-trips through a real journal, unchanged" do
    io = StringIO.new
    Lain::Journal.new(io:).record(record)

    parsed = Lain::Journal.records(io.string.lines, type: discriminator).to_a

    expect(parsed.size).to eq(1)
    expect(parsed.first.except("ts")).to eq(record.to_journal)
    expect(described_class.new(**parsed.first.except("ts", "type").transform_keys(&:to_sym))).to eq(record)
  end

  it "is a deeply frozen, shareable value" do
    expect(record).to be_deeply_frozen
  end
end

# The head of a review: which source produced the changeset, what it spans, and
# the address every later record joins back to.
RSpec.describe Lain::Review::ChangesetOpened do
  def opened(**overrides)
    described_class.new(source: "local_branch", base_ref: "a1b2c3", head_ref: "d4e5f6",
                        digest: "cafe", **overrides)
  end

  let(:record) { opened }

  it_behaves_like "a review journal record", "changeset_opened"

  it "refuses a changeset that names no source, no span, or no address" do
    expect { opened(source: nil) }.to raise_error(ArgumentError, /source/)
    expect { opened(base_ref: "  ") }.to raise_error(ArgumentError, /base_ref/)
    expect { opened(head_ref: nil) }.to raise_error(ArgumentError, /head_ref/)
    expect { opened(digest: "") }.to raise_error(ArgumentError, /digest/)
  end

  # A refusal that says "got nil" over a value that was `""` sends the reader
  # looking for a missing argument they did not pass. Every message reports the
  # value it actually judged, in `inspect` form, so nil and "" and "  " are three
  # different sentences.
  it "reports the value it judged rather than assuming which blank arrived" do
    expect { opened(digest: "") }.to raise_error(ArgumentError, 'digest must address the changeset, got ""')
    expect { opened(digest: nil) }.to raise_error(ArgumentError, "digest must address the changeset, got nil")
    expect { opened(source: "  ") }
      .to raise_error(ArgumentError, 'source must name what produced the changeset, got ""')
  end

  # The source registry is the port's (T3) and one of its entries is deletable
  # (T10). A second copy of the set here would have to be edited to delete a
  # capability, which is exactly the drift a shared vocabulary avoids.
  it "accepts any named source rather than restating the source registry" do
    expect(opened(source: "github_pr").source).to eq("github_pr")
  end
end

# One hunk's reviewed mark. The tri-state a file or a commit shows is DERIVED
# from these (T8), so the vocabulary stored here is binary and closed.
RSpec.describe Lain::Review::HunkMarked do
  def marked(**overrides)
    described_class.new(hunk_key: "hunk-content-v1:beef", state: "reviewed", **overrides)
  end

  let(:record) { marked }

  it_behaves_like "a review journal record", "hunk_marked"

  it "carries both mark states and refuses a third spelling" do
    expect(marked(state: "unreviewed").state).to eq("unreviewed")
    expect { marked(state: "partial") }.to raise_error(ArgumentError, /state/)
    expect { marked(state: nil) }.to raise_error(ArgumentError, /state/)
  end

  it "refuses a mark that names no hunk" do
    expect { marked(hunk_key: nil) }.to raise_error(ArgumentError, /hunk_key/)
  end

  # The key's scheme prefix belongs to Review::Hunk (T2), which is the object
  # that can change it. Restating the prefixes here would be a second copy of
  # that scheme waiting to disagree with the first.
  it "does not restate the key scheme it stores" do
    expect(marked(hunk_key: "hunk-span-v1:beef").hunk_key).to eq("hunk-span-v1:beef")
  end

  it "accepts a Symbol state as readily as its name" do
    expect(marked(state: :reviewed).state).to eq("reviewed")
  end

  # The half of Wire's two rules that nothing else here could see. `presence:`
  # already treats a whitespace-only String as blank, so every refusal in this
  # file passes with or without the strip -- and a token arriving off a wire with
  # a space around it would then miss its closed set and be refused as an unknown
  # spelling rather than read as the value it is.
  it "reads a token through the whitespace a wire wrapped it in" do
    expect(marked(state: " reviewed ").state).to eq("reviewed")
    expect(marked(hunk_key: " hunk-content-v1:beef\n").hunk_key).to eq("hunk-content-v1:beef")
  end
end

# The judgement, against the changeset it judged. Both halves are required: a
# verdict with no changeset digest is a judgement of nothing.
RSpec.describe Lain::Review::ReviewVerdict do
  def verdict(**overrides)
    described_class.new(verdict: "approve", changeset_digest: "cafe", **overrides)
  end

  let(:record) { verdict }

  it_behaves_like "a review journal record", "review_verdict"

  # Research open question 3 has not settled the vocabulary, so the set holds
  # exactly the one value this chunk writes. A second member is a design
  # decision, and this is what makes taking it deliberate rather than incidental.
  it "admits only the verdict the chunk has chosen" do
    expect(Lain::Review::VERDICTS).to eq(%w[approve])
    expect { verdict(verdict: "request_changes") }.to raise_error(ArgumentError, /verdict/)
  end

  # The refusal has to name the DECISION, not just the set. An agent that reads
  # "must be one of approve" concludes the set is too small and widens it; the
  # correct response is to stop, because the vocabulary is an open research
  # question and picking it is not this chunk's to do.
  it "refuses in a way that says the vocabulary is unsettled, not that the set is short" do
    expect { verdict(verdict: "request_changes") }
      .to raise_error(ArgumentError, /research open question 3/)
    expect { verdict(verdict: "request_changes") }
      .to raise_error(ArgumentError, /Review::VERDICTS/)
    expect { verdict(verdict: "request_changes") }
      .to raise_error(ArgumentError, /got "request_changes"/)
  end

  it "refuses a judgement of nothing" do
    expect { verdict(changeset_digest: nil) }.to raise_error(ArgumentError, /changeset_digest/)
  end
end

# One note a human left on a changeset. The changeset-shaped sibling of
# Epic::Annotation, which stays as-is: this one is keyed by an anchor id and a
# (path, side, line) rather than by an epic slug and a generation, and it carries
# the revision it was authored against.
RSpec.describe Lain::Review::AnnotationPlaced do
  def placed(**overrides)
    described_class.new(id: "1f0c-4b", path: "lib/lain/agent.rb", side: "new", line: 42,
                        anchor_text: "  @store.write(input)", text: "validate first",
                        kind: "note", drifted: false, revision: "d4e5f6", **overrides)
  end

  let(:record) { placed }

  it_behaves_like "a review journal record", "annotation_placed"

  # AC3. The line is a position, read exactly as strictly as the epic sibling's:
  # a truncated "42abc" would anchor the note to a line nobody named, and a
  # negative one to a line that cannot exist.
  it "refuses a line that is not the positive canonical integer the editor sent" do
    expect { placed(line: -3) }.to raise_error(ArgumentError, /line/)
    expect { placed(line: 0) }.to raise_error(ArgumentError, /line/)
    expect { placed(line: nil) }.to raise_error(ArgumentError, /line/)
    expect { placed(line: "42abc") }.to raise_error(ArgumentError, /line/)
    expect { placed(line: 42.9) }.to raise_error(ArgumentError, /line/)
    expect(placed(line: "42").line).to eq(42)
  end

  # AC3's other half: refused at CONSTRUCTION, so nothing malformed ever reaches
  # the fd. A record refused on the way back out would already be on disk.
  it "refuses before the journal is ever written to" do
    io = StringIO.new
    journal = Lain::Journal.new(io:)

    expect { journal.record(placed(line: -3)) }.to raise_error(ArgumentError, /line/)
    expect(io.string).to be_empty
  end

  it "carries both sides of the diff and refuses a third" do
    expect(placed(side: "old").side).to eq("old")
    expect(placed(side: :new).side).to eq("new")
    expect { placed(side: "both") }.to raise_error(ArgumentError, /side/)
  end

  it "carries the three note kinds and refuses a fourth" do
    expect(Lain::Review::ANNOTATION_KINDS).to eq(%w[note question blocker])
    expect(placed(kind: :blocker).kind).to eq("blocker")
    expect { placed(kind: "praise") }.to raise_error(ArgumentError, /kind/)
  end

  # The revision is the whole point of this record over the epic sibling
  # (research open question 4b): an annotation validated against one diff and
  # submitted against another is a live bug in tuicr, and it is only avoidable if
  # the diff the human was looking at is on the record.
  it "refuses a note that does not name the revision it was authored against" do
    expect { placed(revision: nil) }.to raise_error(ArgumentError, /revision/)
    expect { placed(revision: "  ") }.to raise_error(ArgumentError, /revision/)
  end

  it "refuses a note with no id, no path, and no words" do
    expect { placed(id: nil) }.to raise_error(ArgumentError, /id/)
    expect { placed(path: "") }.to raise_error(ArgumentError, /path/)
    expect { placed(text: "  ") }.to raise_error(ArgumentError, /text/)
  end

  # Where this record parts company with Epic::Annotation, deliberately. That one
  # refuses a blank anchor_text because a prose document has no blank line worth
  # annotating; a diff does -- an added empty line is a real, anchorable position,
  # and refusing it would lose the human's words over a line they legitimately
  # chose. Absent is still refused: nil is not a line, "" is.
  it "anchors to a blank line but not to a missing one" do
    expect(placed(anchor_text: "").anchor_text).to eq("")
    expect { placed(anchor_text: nil) }.to raise_error(ArgumentError, /anchor_text/)
  end

  # The leading indentation IS the evidence: drift is anchor_text against the
  # line the number now names, so an anchor stripped on the way in would compare
  # equal to a line that had been re-indented and report no drift. Nothing else
  # in this file would notice a `strip` here -- both sides of a round trip would
  # be stripped alike -- so this is the example that holds it.
  it "keeps an anchored line exactly as the document had it" do
    expect(placed(anchor_text: "    end").anchor_text).to eq("    end")
    expect(placed(text: " needs a spec ").text).to eq(" needs a spec ")
  end

  it "carries the drift flag as one boolean, and refuses anything else" do
    expect(placed(drifted: true).drifted).to be(true)
    expect { placed(drifted: nil) }.to raise_error(ArgumentError, "drifted must be true or false, got nil")
    expect { placed(drifted: "maybe") }
      .to raise_error(ArgumentError, 'drifted must be true or false, got "maybe"')
  end

  # Drift is a MEASUREMENT -- anchor_text against the line the number now names --
  # and a measurement nobody took is not the same fact as one that came back
  # false. A default would let a caller that never compared journal "did not
  # drift", which is the reading a later audit cannot tell from a real one. Every
  # caller that can place a note has already resolved the anchor, so requiring it
  # costs nothing and refuses the one case that would be a lie.
  it "requires the drift measurement rather than defaulting to a claim" do
    expect { described_class.new(**placed.to_h.except(:drifted)) }
      .to raise_error(ArgumentError, /drifted/)
  end

  # The guard is reachable WITHOUT the constructor, which is what makes the
  # numericality clause above WireInteger real rather than dead: T13 folds these
  # records back in from the journal, where a line is already an Integer and
  # WireInteger is never called. Without this example the clause deletes clean.
  it "re-refuses a line through its guard alone, where WireInteger cannot reach" do
    carrier = described_class.guard_carrier.new(line: -1)
    carrier.valid?

    expect(carrier.errors.where(:line).map(&:message))
      .to include(a_string_matching(/must be the diff line the note points at, got -1/))
  end
end

# AC4, asked here as well as globally because the global sweep cannot ask it of
# these records. spec/journalable_surface_spec.rb groups by journal_type over the
# records GenericBuild could BUILD, and three of these four refuse every uniform
# dummy -- so a collision on `hunk_marked`, `review_verdict` or `annotation_placed`
# would pass that sweep in silence.
RSpec.describe "the review records' journal discriminators" do
  # `allocate.journal_type`, not the class basename. Two records can share a
  # basename and still not collide, and -- the case that matters -- a record can
  # OVERRIDE `journal_type` and collide while its basename does not.
  # Forge::Intent and Forge::Outcome already override it in this repo, so this is
  # a shape the registry really has. Asking the method is also what makes the
  # sweep total: `allocate` needs no constructor, so a record whose guard refuses
  # every generic dummy is still answerable here.
  def discriminators_in_the_registry
    ObjectSpace.each_object(Class).select do |klass|
      klass.include?(Lain::Telemetry::Journalable)
    rescue StandardError
      false
    end
  end

  it "collides with none of the includers already in the registry" do
    reviews = [Lain::Review::ChangesetOpened, Lain::Review::HunkMarked,
               Lain::Review::ReviewVerdict, Lain::Review::AnnotationPlaced]
    taken = (discriminators_in_the_registry - reviews).map { |klass| klass.allocate.journal_type }

    expect(reviews.map { |klass| klass::JOURNAL_TYPE })
      .to contain_exactly("changeset_opened", "hunk_marked", "review_verdict", "annotation_placed")
    expect(reviews.map { |klass| klass.allocate.journal_type } & taken).to be_empty
  end

  # The sweep answers for the WHOLE registry, which is the property that lets it
  # stand in for spec/journalable_surface_spec.rb's collision example over the
  # records GenericBuild cannot build.
  it "answers for every includer, including the ones no generic dummy constructs" do
    klasses = discriminators_in_the_registry

    expect(klasses.size).to be > 60
    expect(klasses.map { |klass| klass.allocate.journal_type }.uniq.size).to eq(klasses.size)
  end
end
