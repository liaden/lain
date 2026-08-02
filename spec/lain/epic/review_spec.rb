# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

# The two records the baton writes. Covered here rather than in `records_spec.rb`
# for the reason `doc_written` is covered in `journaled_spec.rb`: they exist for
# exactly one writer, and their `type` strings -- derived from the class name,
# never hand-written -- are DURABLE journal discriminators, so they are pinned
# beside the object that emits them.
RSpec.describe Lain::Epic::ReviewOpened do
  def opened(**overrides)
    described_class.new(epic_slug: "alpha", path: "/srv/state/lain/epics/alpha/epic.md", generation: 1,
                        written_digest: "blake3:beef", graph_digest: "blake3:cafe", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(opened.journal_type).to eq("review_opened")
    expect(described_class::JOURNAL_TYPE).to eq("review_opened")
  end

  it "refuses an unnamed epic, an unheld path, and the byte digest missing" do
    expect { opened(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    expect { opened(path: "  ") }.to raise_error(ArgumentError, /path/)
    expect { opened(written_digest: nil) }.to raise_error(ArgumentError, /written_digest/)
  end

  # Not an omission from the example above: a prose artifact HAS no graph, so
  # nil is its honest graph address rather than a missing one. The empty string
  # is what the record must never hold -- an address-shaped value addressing
  # nothing -- and `&&=` is what keeps the two apart.
  it "keeps a prose review's absent graph digest absent rather than blank" do
    expect(opened(graph_digest: nil).graph_digest).to be_nil
  end

  it "refuses a generation that is not the positive integer identifying a review" do
    expect { opened(generation: 0) }.to raise_error(ArgumentError, /generation/)
    expect { opened(generation: nil) }.to raise_error(ArgumentError, /generation/)
    expect { opened(generation: "later") }.to raise_error(ArgumentError, /generation/)
  end

  it "refuses fractional and non-canonical wire generations" do
    expect { opened(generation: 1.9) }.to raise_error(ArgumentError, /generation/)
    expect { opened(generation: "3junk") }.to raise_error(ArgumentError, /generation/)
  end

  it "reads a wire generation as the integer it keys on" do
    expect(opened(generation: "3").generation).to eq(3)
  end

  it "is a deeply frozen, shareable value" do
    expect(opened).to be_deeply_frozen
    expect(Ractor.shareable?(opened)).to be(true)
  end
end

RSpec.describe Lain::Epic::ReviewClosed do
  def closed(**overrides)
    described_class.new(epic_slug: "alpha", path: "/srv/state/lain/epics/alpha/epic.md", generation: 1,
                        written_digest: "blake3:beef", disk_digest: "blake3:feed",
                        changes: { retitled: ["b2"] }, lossy: false, **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(closed.journal_type).to eq("review_closed")
    expect(described_class::JOURNAL_TYPE).to eq("review_closed")
  end

  it "string-keys the structural summary, so a record read back from JSON equals the one written" do
    expect(closed.changes).to eq({ "retitled" => ["b2"] })
    expect(closed(changes: { "retitled" => ["b2"] })).to eq(closed)
  end

  it "refuses a summary that is not the account's Hash of changed kinds" do
    expect { closed(changes: nil) }.to raise_error(ArgumentError, /changes/)
    expect { closed(changes: %w[retitled]) }.to raise_error(ArgumentError, /changes/)
  end

  it "refuses a suspicion that is not a boolean, since lossy is one measure and not a level" do
    expect { closed(lossy: nil) }.to raise_error(ArgumentError, /lossy/)
    expect { closed(lossy: "maybe") }.to raise_error(ArgumentError, /lossy/)
  end

  it "keeps a parse error and its kind together, the way the delta it reports does" do
    expect { closed(error: "no heading") }.to raise_error(ArgumentError, /error/)
    expect { closed(error_kind: "Lain::Epic::MalformedDocument") }.to raise_error(ArgumentError, /error/)
    expect(closed(error: "no heading", error_kind: "Lain::Epic::MalformedDocument").error_kind)
      .to eq("Lain::Epic::MalformedDocument")
  end

  it "is a deeply frozen, shareable value even with a nested summary" do
    expect(closed(changes: { retitled: ["b2"], removed: ["c"] })).to be_deeply_frozen
    expect(Ractor.shareable?(closed)).to be(true)
  end
end

# A journal that refuses its FIRST record and accepts everything after: a full
# disk, or an fd closed under us. Deliberately not a Journal double -- what the
# baton depends on is the `#<<` message, and the example is about what happens
# when that message raises.
class FlakyJournal
  attr_reader :accepted

  def initialize
    @seen = 0
    @accepted = []
  end

  def <<(record)
    @seen += 1
    raise Lain::Journal::Closed, "journal is closed" if @seen == 1

    @accepted << record
    self
  end
end

RSpec.describe Lain::Epic::Review do
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:review) { described_class.new(journal:, epic_slug: "alpha") }

  def issue(id:, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def two_issue_graph = graph_of(issue(id: "a", blocks: ["b"]), issue(id: "b", status: "done"))

  def written = Lain::Epic::Intake::Written.new(graph: two_issue_graph)

  # The one edit every scenario reviews: a retitle, which moves both the bytes
  # and the meaning, so byte_identical? and the account disagree with nothing.
  def retitled_disk = written.bytes.sub("the a issue", "a sharper title")

  def records(type) = Lain::Journal.records(io.string.lines, type:).to_a

  # A doubled journal cannot be produced by two live Reviews -- both number from
  # their own records, so both hand out 1 and the second claim overwrites the
  # first. Two claims on one path at DIFFERENT generations is a doctored or
  # hand-edited journal, and the fold has to be total over it either way.
  def reviewed = "/epics/alpha/epic.md"

  def claimed(generation)
    { "type" => "review_opened", "epic_slug" => "alpha", "path" => reviewed, "generation" => generation,
      "written_digest" => written.byte_digest, "graph_digest" => written.graph_digest }
  end

  def released(generation)
    claimed(generation).merge("type" => "review_closed", "disk_digest" => written.byte_digest,
                              "changes" => {}, "lossy" => false)
  end

  def paths_for(state_home)
    Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  end

  def home_in(tmp, slug: "alpha")
    Lain::Epic::Home.resolve(config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)),
                             paths: paths_for(tmp), root: tmp, slug:)
  end

  # Scenario: settle resolves exactly its own generation
  it "resolves exactly the settled generation's promise and leaves the other pending" do
    Sync do
      first = review.open(path: "/epics/alpha/epic.md", written:)
      second = review.open(path: "/epics/beta/epic.md", written:)

      delta = review.settle(second.generation, disk: retitled_disk)

      expect(second).to be_resolved
      expect(second.await).to be(delta)
      expect(delta.account.changes).to eq({ retitled: ["a"] })
      expect(first).not_to be_resolved
    end
  end

  it "gives each open review its own generation and its own promise" do
    first = review.open(path: "/epics/alpha/epic.md", written:)
    second = review.open(path: "/epics/beta/epic.md", written:)

    expect(second.generation).to eq(first.generation + 1)
    expect(review.settle(first.generation, disk: written.bytes)).to be_byte_identical
    expect(second).not_to be_resolved
  end

  it "journals the claim before it holds the baton, with both addresses of what lain wrote" do
    token = review.open(path: "/epics/alpha/epic.md", written:)

    expect(records("review_opened")).to contain_exactly(
      hash_including("epic_slug" => "alpha", "path" => "/epics/alpha/epic.md", "generation" => token.generation,
                     "written_digest" => written.byte_digest, "graph_digest" => written.graph_digest)
    )
  end

  it "journals the settlement with both digests, the structural summary, and the suspicion" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    review.settle(token.generation, disk: retitled_disk)

    expect(records("review_closed")).to contain_exactly(
      hash_including("epic_slug" => "alpha", "path" => "/epics/alpha/epic.md", "generation" => token.generation,
                     "written_digest" => written.byte_digest,
                     "disk_digest" => Lain::Epic::Intake.byte_digest(retitled_disk),
                     "changes" => { "retitled" => ["a"] }, "lossy" => false)
    )
  end

  # The CROSS-SEAM example: notes arrive String-keyed, because they crossed
  # msgpack from lua (`spec/lain/frontend/neovim_runtime_spec.rb` pins that shape
  # against a real editor). Reading them as Symbols raised KeyError AFTER the
  # settlement was journaled, which left the journal saying settled while the
  # baton was still held and the asker's promise never resolved.
  def from_the_editor(line:, text:, anchor_text:)
    { "line" => line, "text" => text, "anchor_text" => anchor_text }
  end

  def first_line = written.bytes.lines.first.chomp

  it "journals each resolved annotation when a review settles, in the editor's own key shape" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    note = from_the_editor(line: 1, text: "tighten this AC", anchor_text: first_line)

    review.settle(token.generation, disk: written.bytes, annotations: [note])

    expect(records("annotation")).to contain_exactly(
      hash_including("epic_slug" => "alpha", "generation" => token.generation, "issue_id" => "a",
                     "line" => 1, "text" => "tighten this AC", "anchor_text" => first_line, "drifted" => false)
    )
    expect(review.open?("/epics/alpha/epic.md")).to be(false)
    expect(token).to be_resolved
  end

  it "journals the notes in the order the human placed them, which is the only order a reader gets" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    notes = [from_the_editor(line: 3, text: "first", anchor_text: "Blocks: `b`"),
             from_the_editor(line: 1, text: "second", anchor_text: first_line)]

    review.settle(token.generation, disk: written.bytes, annotations: notes)

    expect(records("annotation").map { |record| record["text"] }).to eq(%w[first second])
  end

  # A drifted note is journaled and SAYS it drifted: the human's words survive,
  # and nothing downstream can mistake it for a note still sitting where it was
  # placed.
  it "journals a note whose anchor is gone as drifted, attributed to nothing" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    note = from_the_editor(line: 1, text: "tighten this AC", anchor_text: "a line the human deleted")

    review.settle(token.generation, disk: written.bytes, annotations: [note])

    expect(records("annotation")).to contain_exactly(
      hash_including("text" => "tighten this AC", "drifted" => true, "issue_id" => nil)
    )
  end

  # The wedge, closed by ORDER: the notes are built before anything is journaled,
  # so a note no record will accept leaves the journal and the baton agreeing
  # that the review is still open. The human fixes the note and hands it back
  # again; nothing has to reconcile a settlement that only half happened.
  it "records no settlement at all when a note cannot be journaled, and keeps holding the baton" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    unusable = from_the_editor(line: 1, text: "  ", anchor_text: first_line)

    expect { review.settle(token.generation, disk: written.bytes, annotations: [unusable]) }
      .to raise_error(ArgumentError, /text/)

    expect(records("review_closed")).to be_empty
    expect(records("annotation")).to be_empty
    expect(review.open?("/epics/alpha/epic.md")).to be(true)
    expect(token).not_to be_resolved
  end

  # The generation arrives off a wire, so it can be junk. Its only caller
  # (`CLI::HumanReplies#settle_review`) rescues NotOpen and renders a refusal to
  # the editor; anything else escapes and kills the fiber that reads the
  # editor's replies, so a stale buffer takes the reply loop down with it.
  it "refuses a wire generation that names no review as NotOpen, not as a bare ArgumentError" do
    review.open(path: "/epics/alpha/epic.md", written:)

    ["3junk", nil, "", 0, 1.9].each do |generation|
      expect { review.settle(generation, disk: retitled_disk) }.to raise_error(described_class::NotOpen)
    end
    expect(records("review_closed")).to be_empty
  end

  it "holds no baton and burns the generation when the claim cannot be journaled" do
    flaky = FlakyJournal.new
    review = described_class.new(journal: flaky, epic_slug: "alpha")

    expect { review.open(path: "/epics/alpha/epic.md", written:) }.to raise_error(Lain::Journal::Closed)
    expect(review.open?("/epics/alpha/epic.md")).to be(false)

    # The lost claim's number is never handed out again: a reused generation
    # would let a `done` gesture settle a review it does not name.
    expect(review.open(path: "/epics/alpha/epic.md", written:).generation).to eq(2)
    expect(flaky.accepted.size).to eq(1)
  end

  it "reports the baton as returned once the review settles" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    expect(review.open?("/epics/alpha/epic.md")).to be(true)

    review.settle(token.generation, disk: retitled_disk)

    expect(review.open?("/epics/alpha/epic.md")).to be(false)
  end

  # Scenario: a stale settle refuses
  it "refuses a second settle of the same generation and journals no second close" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    review.settle(token.generation, disk: retitled_disk)

    expect { review.settle(token.generation, disk: retitled_disk) }
      .to raise_error(described_class::NotOpen, /already settled/)
    expect(records("review_closed").size).to eq(1)
  end

  # Found by the mutation battery: deleting the rebuild's own record of what it
  # settled left every example green, because nothing asked a rebuilt Review to
  # tell a settled generation from an unknown one. An editor buffer that
  # outlived the process asks exactly that.
  it "remembers across a restart that a settled generation was settled, not merely unknown" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    review.settle(token.generation, disk: written.bytes)
    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    expect { rebuilt.settle(token.generation, disk: written.bytes) }
      .to raise_error(described_class::NotOpen, /already settled/)
  end

  it "refuses a generation nothing ever opened, and says so differently" do
    expect { review.settle(41, disk: retitled_disk) }
      .to raise_error(described_class::NotOpen, /never opened/)
    expect(records("review_closed")).to be_empty
  end

  # Scenario: one review per path
  it "refuses a second opener for a path already under review and journals no second claim" do
    review.open(path: "/epics/alpha/epic.md", written:)

    expect { review.open(path: "/epics/alpha/epic.md", written:) }
      .to raise_error(described_class::AlreadyOpen, %r{/epics/alpha/epic\.md})
    expect(records("review_opened").size).to eq(1)
  end

  # Scenario: an open review survives a restart as state
  it "rebuilds the open set from a journal holding an opened with no close" do
    review.open(path: "/epics/alpha/epic.md", written:)
    settled = review.open(path: "/epics/alpha/issues/b.md", written:)
    review.settle(settled.generation, disk: written.bytes)

    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    expect(rebuilt.open?("/epics/alpha/epic.md")).to be(true)
    expect(rebuilt.open?("/epics/alpha/issues/b.md")).to be(false)
  end

  it "never promises across a restart -- the fold rebuilds state and nothing else" do
    review.open(path: "/epics/alpha/epic.md", written:)

    expect(Lain::Promise).not_to receive(:new)
    described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")
  end

  it "leaves another epic's open review out of this one's baton" do
    other = described_class.new(journal:, epic_slug: "beta")
    other.open(path: "/epics/beta/epic.md", written:)

    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    expect(rebuilt.open?("/epics/beta/epic.md")).to be(false)
  end

  it "opens above every generation THIS epic has already used, settled ones included" do
    review.open(path: "/epics/alpha/epic.md", written:)
    token = review.open(path: "/epics/alpha/issues/b.md", written:)
    review.settle(token.generation, disk: written.bytes)

    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    expect(rebuilt.open(path: "/epics/alpha/plans/b.md", written:).generation).to eq(3)
  end

  # The high-water mark reads `review_closed` as well as `review_opened`, so the
  # open set and the settled set cannot overlap. Without it, a journal whose
  # claim is gone -- rotated away, or torn -- hands the settled number out
  # again, and a generation that is open AND settled settles on the first ask.
  it "never hands out a generation the journal already settled, even with the claim gone" do
    orphan = { "type" => "review_closed", "epic_slug" => "alpha", "path" => "/epics/alpha/epic.md",
               "generation" => 9, "written_digest" => "blake3:beef", "disk_digest" => "blake3:feed",
               "changes" => {}, "lossy" => false }

    rebuilt = described_class.from_journal([orphan], journal:, epic_slug: "alpha")

    expect(rebuilt.open(path: "/epics/alpha/epic.md", written:).generation).to eq(10)
  end

  # The RETRACTION, pinned so nobody reads journal-wide uniqueness back into the
  # code: a generation names a review within ONE epic, and the settle route has
  # to carry the epic slug beside it. Two live Reviews over one journal number
  # from their own records and both start at 1.
  it "numbers each epic independently, so (epic_slug, generation) is the identity" do
    beta = described_class.new(journal:, epic_slug: "beta")
    beta.open(path: "/epics/beta/epic.md", written:)

    expect(review.open(path: "/epics/alpha/epic.md", written:).generation).to eq(1)

    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "beta")
    expect(rebuilt.open(path: "/epics/beta/issues/b.md", written:).generation).to eq(2)
  end

  # The blocker the panel found: a rebuilt baton the API can name is a rebuilt
  # baton the API can release. Nothing is carried across the restart here --
  # only the journal is.
  it "hands a rebuilt baton back through the public API, with no token carried across" do
    review.open(path: "/epics/alpha/epic.md", written:)
    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    generation = rebuilt.generation_for("/epics/alpha/epic.md")
    rebuilt.settle(generation, disk: retitled_disk)

    expect(rebuilt.open?("/epics/alpha/epic.md")).to be(false)
    expect { rebuilt.open(path: "/epics/alpha/epic.md", written:) }.not_to raise_error
  end

  it "lists what is being held, so a restarted process can say whose file it is waiting on" do
    first = review.open(path: "/epics/alpha/epic.md", written:)
    second = review.open(path: "/epics/alpha/issues/b.md", written:)
    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    expect(rebuilt.open_generations).to eq({ "/epics/alpha/epic.md" => first.generation,
                                             "/epics/alpha/issues/b.md" => second.generation })
    expect(rebuilt.generation_for("/epics/alpha/nothing.md")).to be_nil
  end

  it "normalizes a held path the same way live and rebuilt, so the guard cannot go quiet" do
    review.open(path: " /epics/alpha/epic.md ", written:)
    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    expect(review.open?(" /epics/alpha/epic.md ")).to be(true)
    expect(rebuilt.open?(" /epics/alpha/epic.md ")).to be(true)
    expect(rebuilt.open?("/epics/alpha/epic.md")).to eq(review.open?("/epics/alpha/epic.md"))
  end

  # A token names the PAIR, so a settle route reads both halves off one object
  # and cannot forget the epic beside the number.
  it "carries the epic on the token, live and rebuilt, because the identity is the pair" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    expect(token.epic_slug).to eq("alpha")
    expect(rebuilt.open_generations).to eq({ "/epics/alpha/epic.md" => token.generation })
    expect(rebuilt.generation_for("/epics/alpha/epic.md")).to eq(token.generation)
  end

  # Two Reviews for ONE epic is a wiring error -- the contract is one per slug --
  # but the fold must not turn it into a journal nobody can rebuild. It holds the
  # EARLIEST claim and frees the path only when every claim has released, which
  # is the conservative direction and heals itself.
  it "rebuilds a doubled journal with the earliest claim holding, and frees the path only when both release" do
    rebuilt = described_class.from_journal([claimed(1), claimed(4)], journal:, epic_slug: "alpha")

    expect(rebuilt.generation_for(reviewed)).to eq(1)
    rebuilt.settle(1, disk: retitled_disk)
    expect(rebuilt.generation_for(reviewed)).to eq(4)
    rebuilt.settle(4, disk: retitled_disk)
    expect(rebuilt.open?(reviewed)).to be(false)
  end

  # The poison pill, pinned twice so it cannot be reintroduced a third time.
  # Refusing these mid-fold judges the journal by a PREFIX: the raise goes on
  # firing after the doubled claims have settled, and the epic is permanently
  # un-rebuildable -- the exact wedge this class exists to prevent, arriving
  # through the guard added to prevent it.
  #
  # Both shapes come off the SAME wiring error the doubled-path case tolerates:
  # two Reviews for one slug each number from their own records, so both hand
  # out 1 (see "numbers each epic independently" above).
  it "carries a generation claimed twice instead of refusing the journal that holds it" do
    rebuilt = described_class.from_journal([claimed(1), claimed(1)], journal:, epic_slug: "alpha")

    expect(rebuilt.generation_for(reviewed)).to eq(1)
    rebuilt.settle(1, disk: retitled_disk)
    expect(rebuilt.open?(reviewed)).to be(false)
  end

  it "rebuilds a doubled claim that has since released, rather than refusing forever" do
    rebuilt = described_class.from_journal([claimed(1), claimed(1), released(1), released(1)],
                                           journal:, epic_slug: "alpha")

    expect(rebuilt.open?(reviewed)).to be(false)
    expect(rebuilt.open(path: reviewed, written:).generation).to eq(2)
  end

  # A claim AFTER its own close: the journal's last word on generation 1 is that
  # a human holds the file, so the fold says so and the baton can be released.
  # Refusing left the file held by a review nothing could ever settle.
  it "holds a generation reopened after its close record, and lets it settle" do
    rebuilt = described_class.from_journal([claimed(1), released(1), claimed(1)], journal:, epic_slug: "alpha")

    expect(rebuilt.generation_for(reviewed)).to eq(1)
    expect { rebuilt.settle(1, disk: retitled_disk) }.not_to raise_error
    expect(rebuilt.open?(reviewed)).to be(false)
  end

  # A record naming NO epic is kept by the fold rather than filtered out, so its
  # own guard refuses it: a filter that swallowed the unattributable line would
  # skip exactly the record that most needs refusing, and a swallowed
  # `review_opened` loses the baton for a file a human still holds.
  it "refuses an unattributable claim rather than dropping it out of the fold" do
    expect { described_class.from_journal([claimed(1).merge("epic_slug" => "")], journal:, epic_slug: "alpha") }
      .to raise_error(ArgumentError, /epic_slug/)
  end

  it "rebuilds a journal whose doubled claims have both settled, rather than refusing forever" do
    settled = [claimed(1), claimed(4), released(1), released(4)]

    rebuilt = described_class.from_journal(settled, journal:, epic_slug: "alpha")

    expect(rebuilt.open?(reviewed)).to be(false)
    expect(rebuilt.open(path: reviewed, written:).generation).to eq(5)
  end

  # The concession, pinned rather than left implied: {Journal.records} skips a
  # line it cannot parse, so a claim torn by a crash never reaches the guard and
  # the baton is LOST. The fold fails OPEN, and `open? == false` is therefore not
  # proof that nobody is holding the file.
  it "loses a claim whose journal line was torn, because the journal's reader skips what it cannot parse" do
    review.open(path: "/epics/alpha/epic.md", written:)
    torn = io.string.lines.first[0, 40]

    rebuilt = described_class.from_journal([torn], journal:, epic_slug: "alpha")

    expect(rebuilt.open?("/epics/alpha/epic.md")).to be(false)
  end

  it "aborts the rebuild on a record it cannot read whole, rather than rebuilding a baton nothing can match" do
    truncated = { "type" => "review_opened", "epic_slug" => "alpha", "generation" => 1,
                  "written_digest" => "blake3:beef", "graph_digest" => "blake3:cafe" }

    expect { described_class.from_journal([truncated], journal:, epic_slug: "alpha") }
      .to raise_error(ArgumentError, /path/)
  end

  # Scenario: settling a rebuilt review does not wedge
  it "settles a rebuilt, promiseless generation instead of wedging the review forever" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    delta = rebuilt.settle(token.generation, disk: retitled_disk)

    expect(records("review_closed").size).to eq(1)
    expect(rebuilt.open?("/epics/alpha/epic.md")).to be(false)
    expect(delta).to be_a(Lain::Epic::Intake::Delta)
  end

  it "reports a rebuilt settle as uncompared rather than as agreement" do
    token = review.open(path: "/epics/alpha/epic.md", written:)
    rebuilt = described_class.from_journal(io.string.lines, journal:, epic_slug: "alpha")

    delta = rebuilt.settle(token.generation, disk: retitled_disk)

    expect(delta).to be_malformed
    expect(delta.error_kind).to eq(described_class::Unrecoverable.name)
    expect(delta.account.changes).to be_empty
    expect(delta.written_digest).to eq(written.byte_digest)
    expect(delta.disk_digest).to eq(Lain::Epic::Intake.byte_digest(retitled_disk))
    expect(records("review_closed").first["error_kind"]).to eq(described_class::Unrecoverable.name)
  end

  it "refuses to await a rebuilt review's promise rather than parking a caller nothing will wake" do
    expect { described_class::Unpromised.await }.to raise_error(described_class::NoPromise)
    expect(described_class::Unpromised.resolve(:anything)).to be_nil
  end

  # Scenario: the baton blocks regeneration while open
  it "blocks a journaled home from regenerating the reviewed path until the review settles" do
    Dir.mktmpdir do |tmp|
      home = home_in(tmp)
      journaled = Lain::Epic::Home::Journaled.new(home, journal:, reviews: review)
      journaled.write_epic(two_issue_graph)
      token = review.open(path: home.epic.path, written:)

      expect { journaled.write_epic(two_issue_graph) }
        .to raise_error(Lain::Epic::Home::Journaled::ReviewPending, /under review/)
      expect(home.epic.read).to eq(written.bytes)

      review.settle(token.generation, disk: home.epic.read)
      expect { journaled.write_epic(two_issue_graph) }.not_to raise_error
    end
  end

  it "keys the baton on the ABSOLUTE path the journaled home asks about, and journals that same string" do
    Dir.mktmpdir do |tmp|
      home = home_in(tmp)
      review.open(path: home.epic.path, written:)

      expect(review.open?(home.epic.path)).to be(true)
      expect(review.open?("epic.md")).to be(false)
      expect(records("review_opened").first["path"]).to eq(home.epic.path)
    end
  end

  # Three of the four epic stages are prose, not a graph -- research and the
  # issue plan -- so the baton has to be takeable over bytes that have no
  # structure to compare. What comes back is a delta MEASURED on bytes and
  # UNCOMPARED structurally, which is a third report and not either of the two
  # that already exist: it is not "the sides agreed" (Baseline) and it is not
  # "nothing could be compared because something failed" (Recalled).
  describe "a prose artifact" do
    let(:note) do
      <<~PROSE
        # Research: the serial landing boundary

        The boundary is the interesting part, and this sentence is here to be edited.
      PROSE
    end

    # A research note that QUOTES the heading grammar it is proposing, which the
    # epic parser refuses outright. Prose like this is ordinary work product,
    # and reporting it as a malformed epic is the exact false alarm this
    # baseline exists to avoid.
    let(:unparseable) { "#{note}### [x] a heading missing its backticks\n" }

    def prose(bytes = note) = Lain::Epic::Intake::Prose.new(bytes:)

    def prose_baseline(bytes = note) = described_class::ProseBaseline.new(prose(bytes))

    # Scenario: prose comes back edited
    it "reports edited prose as moved bytes and asserts nothing else about it" do
      delta = prose_baseline.delta(note.sub("this sentence is here to be edited", "the human rewrote this"))

      expect(delta).not_to be_byte_identical
      expect(delta).not_to be_structural
      expect(delta).not_to be_malformed
      expect(delta).not_to be_lossy
    end

    it "reports prose that came back untouched as byte-identical" do
      expect(prose_baseline.delta(note)).to be_byte_identical
    end

    it "carries both byte addresses, so a settlement is on record either way" do
      delta = prose_baseline.delta(unparseable)

      expect(delta.written_digest).to eq(Lain::Epic::Intake.byte_digest(note))
      expect(delta.disk_digest).to eq(Lain::Epic::Intake.byte_digest(unparseable))
    end

    # Scenario: prose that is not an epic document is not malformed
    it "carries no error for prose the epic grammar refuses outright" do
      expect { Lain::Epic::Document.parse_markdown(unparseable) }
        .to raise_error(Lain::Epic::MalformedDocument)

      delta = prose_baseline.delta(unparseable)

      expect(delta).not_to be_malformed
      expect(delta.error).to be_nil
      expect(delta.error_kind).to be_nil
      expect(delta.account.changes).to be_empty
      expect(delta).not_to be_structural
    end

    it "never runs the epic grammar over prose at all" do
      allow(Lain::Epic::Document).to receive(:parse_markdown).and_call_original

      prose_baseline.delta(unparseable)

      expect(Lain::Epic::Document).not_to have_received(:parse_markdown)
    end

    # Scenario: a truncated prose file is still suspected
    it "still suspects truncation, which is a byte measure and so survives having no graph" do
      expect(prose_baseline.delta(note[0, (note.bytesize / 2) - 1])).to be_lossy
      expect(prose_baseline.delta(note[0, note.bytesize - 1])).not_to be_lossy
    end

    it "hands a prose delta across a Ractor like every other settlement" do
      expect(prose_baseline.delta(unparseable)).to be_ractor_shareable
    end

    # Scenario: a prose review journals a nil graph digest
    #
    # PENDING on wiring this card was not scoped to touch. `Epic::ReviewOpened`
    # requires a graph digest to be PRESENT (records.rb:117-120, and the refusal
    # is pinned at the top of this file), so `#open` refuses a prose baseline
    # before it ever builds one. The record's sibling `DocWritten` already
    # models the fix exactly -- `graph_digest: nil` by default, interned with
    # `&&=` so an absent graph stays absent -- and `.handback-T26.md` names the
    # three lines. Un-pend both examples below with that change, and flip the
    # `opened(graph_digest: nil)` refusal at the top of this file.
    it "journals the byte digest and no graph digest for a prose claim" do
      review.open(path: "/epics/alpha/research.md", written: prose)

      expect(records("review_opened")).to contain_exactly(
        hash_including("path" => "/epics/alpha/research.md",
                       "written_digest" => Lain::Epic::Intake.byte_digest(note), "graph_digest" => nil)
      )
    end

    # Scenario: prose and graph reviews coexist on one Review
    it "settles each open review against its own baseline, with neither seeing the other's account" do
      prose_token = review.open(path: "/epics/alpha/research.md", written: prose)
      graph_token = review.open(path: "/epics/alpha/epic.md", written:)

      prose_delta = review.settle(prose_token.generation, disk: unparseable)
      graph_delta = review.settle(graph_token.generation, disk: retitled_disk)

      expect(prose_delta.account.changes).to be_empty
      expect(prose_delta).not_to be_malformed
      expect(graph_delta.account.changes).to eq({ retitled: ["a"] })
    end
  end
end
