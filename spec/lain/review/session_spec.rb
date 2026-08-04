# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Review::Session do
  # Two files, three hunks, two commits -- the smallest changeset that can
  # express every claim this card makes at once: a file with more than one hunk
  # (so "partially reviewed" is a state a FILE can be in), a second file (so a
  # refusal can name one and not the other), and two commits (so the commit walk
  # has something to partition).
  def diff
    <<~DIFF
      diff --git a/a.rb b/a.rb
      index 1111111..2222222 100644
      --- a/a.rb
      +++ b/a.rb
      @@ -1,3 +1,3 @@ def alpha
       one
      -two
      +TWO
      @@ -10,3 +10,3 @@ def beta
       ten
      -eleven
      +ELEVEN
      diff --git a/b.rb b/b.rb
      index 3333333..4444444 100644
      --- a/b.rb
      +++ b/b.rb
      @@ -1,2 +1,2 @@ def gamma
       x
      -y
      +Y
    DIFF
  end

  # The same two files, rewritten: different content, so every hunk key differs
  # and the digest with them. The BASE is unchanged, because a base change is
  # already refused by Marks::BaseMismatch and would prove the round boundary
  # through the wrong mechanism.
  def rewritten_diff
    <<~DIFF
      diff --git a/a.rb b/a.rb
      index 1111111..5555555 100644
      --- a/a.rb
      +++ b/a.rb
      @@ -1,3 +1,3 @@ def alpha
       one
      -two
      +DEUX
    DIFF
  end

  def commit(sha:, subject:, paths:, added: 3, deleted: 1)
    numstat = paths.map { |path| Lain::Review::Source::FileStat.new(path: -path, added:, deleted:) }
    Lain::Review::Source::Commit.new(sha: -sha, subject: -subject, body: "", numstat: numstat.freeze)
  end

  def commits
    [commit(sha: "c" * 40, subject: "first: touch a", paths: ["a.rb"]),
     commit(sha: "d" * 40, subject: "second: touch b", paths: ["b.rb"], added: 5, deleted: 2)]
  end

  # A file the diff changed but no hunk covers, at a caller-chosen path -- the
  # only shape that contributes a path and a status to the address and no hunk
  # key at all, which is what makes the framing property expressible.
  def binary_diff_for(path)
    <<~DIFF
      diff --git a/#{path} b/#{path}
      index 1111111..2222222 100644
      Binary files a/#{path} and b/#{path} differ
    DIFF
  end

  # Interned, and `commit` below freezes every field, because that is what
  # `Source::LocalBranch` actually produces -- it `.freeze`s each sha, subject,
  # body and numstat path and freezes the numstat array (`local_branch.rb`,
  # `parse_record`/`file_stat`/`resolve!`). A fixture that skipped it would make
  # the shareability group below report on the fixture rather than on the
  # values this card builds: `"b" * 40` is a fresh MUTABLE String, and one of
  # those anywhere in the graph is enough.
  def base_sha = -("b" * 40)

  def head_sha = -("h" * 40)

  def source_double(diff_text: diff, walk: commits, base_ref: base_sha, head_ref: head_sha)
    instance_double(Lain::Review::Source::LocalBranch,
                    diff: diff_text.b, commits: walk.freeze, base_ref:, head_ref:)
  end

  def changeset_over(**) = Lain::Review::Changeset.new(source: source_double(**))

  # Derived HERE, independently of the subject, and by the same batch rule
  # Marks itself applies (`Hunk.keys` over one file's hunks at a time) -- a
  # helper that asked the session for its own keys could not catch the session
  # keying them differently, which is exactly what would silently unmark
  # everything.
  def keys_for(path, over: changeset) = Lain::Review::Hunk.keys(over.hunks.select { |hunk| hunk.path == path })

  def every_key(over: changeset) = over.files.flat_map { |file| keys_for(file.path, over:) }

  def anchor_on(path, line, text, revision: head_sha)
    Lain::Review::Anchor.new(path:, side: :new, line:, anchor_text: text, revision:)
  end

  let(:changeset) { changeset_over }
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:surface) { Lain::Review::Surface::Null.new }

  def entries = io.string.lines

  def open_session(over: changeset, **rest)
    described_class.open(changeset: over, journal:, source: "local_branch", surface:, **rest)
  end

  def records_of(type) = Lain::Journal.records(entries, type:).to_a

  describe "opening a round" do
    it "journals the head of the review, addressing the changeset it opened" do
      session = open_session

      expect(records_of("changeset_opened").last)
        .to include("source" => "local_branch", "base_ref" => base_sha, "head_ref" => head_sha,
                    "digest" => session.digest)
    end

    # A Changeset holds its source privately and everything downstream reads
    # four messages without knowing which answered them, so the name has to
    # come from the caller that chose it -- and back off the record afterwards.
    it "names what produced the changeset, and answers it from the record after a resume" do
      open_session

      expect(described_class.from_journal(entries, changeset:, journal:, surface:).source).to eq("local_branch")
    end

    it "starts with nothing marked, nothing annotated and no verdict" do
      session = open_session

      expect([session.marks.to_h, session.annotations, session.verdict])
        .to eq([{}, [], Lain::Review::Verdict::None])
    end

    it "addresses the changeset by its CONTENT, so two reads of one diff open the same round" do
      expect(described_class.digest(changeset)).to eq(described_class.digest(changeset_over))
    end

    it "addresses a rewritten changeset differently, which is what makes a new round detectable" do
      rewritten = changeset_over(diff_text: rewritten_diff)

      expect(described_class.digest(changeset)).not_to eq(described_class.digest(rewritten))
    end

    # The head moves every time the author commits; the marks are meant to
    # survive that (Hunk's whole key scheme exists for it). The BASE is the ref
    # a mark set is pinned to, so the base -- not the head -- is what the
    # address carries.
    it "does not address the changeset by its head, so an amend that changes nothing keeps the round" do
      expect(described_class.digest(changeset)).to eq(described_class.digest(changeset_over(head_ref: "z" * 40)))
    end

    it "addresses it by its base, because a mark set that crossed one would be handed to the wrong hunk" do
      expect(described_class.digest(changeset)).not_to eq(described_class.digest(changeset_over(base_ref: "0" * 40)))
    end

    # The same files, edited. Nothing about the file LIST moves, so an address
    # built from paths alone would call this the same round and hand every mark
    # to code that has since changed.
    it "addresses the hunks' content, so one edited line is already a different round" do
      edited = changeset_over(diff_text: diff.sub("+TWO", "+DEUX"))

      expect(described_class.digest(changeset)).not_to eq(described_class.digest(edited))
    end

    # The framing property, defended where it actually bites. `Review::Keying`
    # holds it as a property of its own; this is that same property reached
    # through a REAL changeset, and this is the pair a mutation pass built once
    # the framing was deleted: the parts are base, then path, then status, so a
    # byte moving off the base and onto the path collides the two unless every
    # part carries its own length. Both files are binary, so neither contributes
    # a hunk key that would have separated them anyway.
    it "cannot be collided by moving a byte from its base ref onto a path" do
      one = changeset_over(diff_text: binary_diff_for("bc"), base_ref: "a")
      two = changeset_over(diff_text: binary_diff_for("c"), base_ref: "ab")

      expect(described_class.digest(one)).not_to eq(described_class.digest(two))
    end

    # Same path, byte-identical hunk, different diff FACT: `new file mode` makes
    # it an addition rather than a modification. Neither the path nor the hunk
    # key can tell those apart, which is why the status is in the address.
    it "addresses what the diff says HAPPENED, not only the lines it moved" do
      added = <<~DIFF
        diff --git a/a.rb b/a.rb
        new file mode 100644
        index 0000000..2222222
        --- /dev/null
        +++ b/a.rb
        @@ -0,0 +1 @@
        +TWO
      DIFF
      modified = added.sub("new file mode 100644\n", "").sub("--- /dev/null", "--- a/a.rb")

      expect(described_class.digest(changeset_over(diff_text: added)))
        .not_to eq(described_class.digest(changeset_over(diff_text: modified)))
    end
  end

  describe "marking a hunk" do
    it "journals the mark and folds it into the mark set" do
      session = open_session
      key = keys_for("a.rb").first

      session.mark(key, "reviewed")

      expect(records_of("hunk_marked").last).to include("hunk_key" => key, "state" => "reviewed")
      expect(session.marks.to_h).to eq({ key => "reviewed" })
    end

    it "tells the surface, so an attached editor redraws the row" do
      spy = instance_spy(Lain::Review::Surface::Null)
      key = keys_for("a.rb").first

      open_session(surface: spy).mark(key, "reviewed")

      expect(spy).to have_received(:mark).with(key, "reviewed")
    end

    # A key the changeset does not produce can never be reconciled onto anything
    # -- it is journaled, pruned on the next replay, and silently does nothing.
    # Marks#state_for refuses an unknown PATH for the same reason.
    it "refuses a hunk key this changeset does not produce, rather than journaling a mark nothing can match" do
      session = open_session

      expect { session.mark("hunk-content-v1:deadbeef", "reviewed") }
        .to raise_error(described_class::UnknownHunk, /deadbeef/)
    end

    it "journals nothing when the key is refused" do
      session = open_session
      before = records_of("hunk_marked").size

      expect { session.mark("hunk-content-v1:deadbeef", "reviewed") }.to raise_error(described_class::UnknownHunk)
      expect(records_of("hunk_marked").size).to eq(before)
    end

    it "refuses a state outside MARK_STATES before anything is journaled" do
      session = open_session

      expect { session.mark(keys_for("a.rb").first, "skimmed") }.to raise_error(Lain::Review::Marks::UnknownState)
      expect(records_of("hunk_marked")).to be_empty
    end
  end

  describe "annotating" do
    it "journals the note and reports it back" do
      session = open_session
      anchor = anchor_on("a.rb", 2, "TWO")

      session.annotate(anchor, "this reads backwards", kind: :question, drifted: false)

      expect(session.annotations.map(&:text)).to eq(["this reads backwards"])
      expect(records_of("annotation_placed").last)
        .to include("path" => "a.rb", "line" => 2, "kind" => "question", "drifted" => false)
    end

    # The card's second scenario. The temptation is `revision: changeset.head_ref`
    # -- which is right for a cumulative anchor and WRONG for one placed while a
    # single commit is on screen, and the two are indistinguishable in every
    # cumulative-scope test.
    it "records the revision the ANCHOR names, not the changeset head" do
      session = open_session
      one_commit = changeset.by_commit.first.sha

      session.annotate(anchor_on("a.rb", 2, "TWO", revision: one_commit), "here", kind: :note, drifted: false)

      expect(session.annotations.last.revision).to eq(one_commit)
      expect(session.annotations.last.revision).not_to eq(changeset.head_ref)
    end

    it "carries the anchor's id, so a replayed note is recognisably the same one" do
      session = open_session
      anchor = anchor_on("a.rb", 2, "TWO")

      session.annotate(anchor, "here", kind: :note, drifted: false)

      expect(session.annotations.last.id).to eq(anchor.id)
    end

    # AnnotationPlaced refuses a default for `drifted` on purpose: a measurement
    # nobody took is a different fact from one that came back false. The session
    # has no document to measure against, so it refuses to guess rather than
    # journal an unmeasured false.
    it "requires the drift measurement rather than defaulting it" do
      session = open_session

      expect { session.annotate(anchor_on("a.rb", 2, "TWO"), "here", kind: :note) }
        .to raise_error(ArgumentError, /drifted/)
    end

    it "keeps a drifted note, because the human's words are the part nobody can reconstruct" do
      session = open_session

      session.annotate(anchor_on("a.rb", 2, "STALE"), "here", kind: :note, drifted: true)

      expect(session.annotations.last.drifted).to be(true)
    end

    it "tells the surface, with the anchor and text it was given" do
      spy = instance_spy(Lain::Review::Surface::Null)
      anchor = anchor_on("a.rb", 2, "TWO")

      open_session(surface: spy).annotate(anchor, "here", kind: :note, drifted: false)

      expect(spy).to have_received(:annotate).with(anchor, "here", kind: :note)
    end
  end

  describe "presenting" do
    it "hands the surface the marked changeset and the scope it was asked for" do
      spy = instance_spy(Lain::Review::Surface::Null)
      session = open_session(surface: spy)

      session.present(scope: :commits)

      expect(spy).to have_received(:present).with(session.marked, scope: :commits)
    end

    # The presented scope is VIEW state and belongs to the surface: the session
    # never remembers which one was last on screen, so two presents in a row
    # cannot disagree about it.
    it "does not remember the scope it was last presented at" do
      spy = instance_spy(Lain::Review::Surface::Null)
      session = open_session(surface: spy)

      session.present(scope: :cumulative)
      session.present(scope: :commits)

      expect(spy).to have_received(:present).with(anything, scope: :cumulative).once
      expect(spy).to have_received(:present).with(anything, scope: :commits).once
    end

    it "refuses a scope outside Review::SCOPES rather than falling through to a default" do
      session = open_session

      expect { session.present(scope: :cumulatve) }.to raise_error(described_class::UnknownScope, /cumulatve/)
    end
  end

  describe "the marked changeset -- the join of a diff fact and a review fact" do
    it "answers a file entry's path and its whole-changeset tri-state" do
      session = open_session
      session.mark(keys_for("a.rb").first, "reviewed")

      expect(session.marked.files.map { |row| [row.path, row.state] })
        .to eq([["a.rb", "partial"], ["b.rb", "unreviewed"]])
    end

    # The one thing `state_of`'s vocabulary lookup actually buys, now that its
    # comment no longer claims more: a tri-state Marks produced that the
    # vocabulary does not know raises, rather than rendering as a blank glyph on
    # a file somebody had reviewed.
    it "refuses a tri-state the vocabulary does not know rather than rendering it blank" do
      marks = instance_double(Lain::Review::Marks, states: { "a.rb" => :skimmed, "b.rb" => :unreviewed })

      expect { Lain::Review::Session::MarkedChangeset.of(changeset, marks) }
        .to raise_error(KeyError, /skimmed/)
    end

    it "answers the state in FILE_STATES' own String spelling, which is what every glyph table keys on" do
      states = open_session.marked.files.map(&:state)

      expect(Lain::Review::FILE_STATES).to include(*states)
    end

    it "reaches 'reviewed' only when every hunk of the file is marked" do
      session = open_session
      keys_for("a.rb").each { |key| session.mark(key, "reviewed") }

      expect(session.marked.files.map { |row| [row.path, row.state] })
        .to eq([["a.rb", "reviewed"], ["b.rb", "unreviewed"]])
    end

    it "answers each file entry's hunks, which is how a row resolves its first new-side line" do
      row = open_session.marked.files.first

      expect(row.hunks.map(&:new_start)).to eq([1, 10])
    end

    # The keys a row hands a marking gesture must be the same keys Marks judges,
    # or a mark made from the sidebar lands on a key the tri-state never reads.
    it "answers hunk keys that are exactly the ones Marks derives" do
      rows = open_session.marked.files

      expect(rows.to_h { |row| [row.path, row.hunk_keys] })
        .to eq({ "a.rb" => keys_for("a.rb"), "b.rb" => keys_for("b.rb") })
    end

    it "answers a commit entry's subject and its share of the files" do
      walk = open_session.marked.by_commit

      expect(walk.map { |row| [row.subject, row.files.map(&:path)] })
        .to eq([["first: touch a", ["a.rb"]], ["second: touch b", ["b.rb"]]])
    end

    # The ruling: `CommitScope#numstat` is an Array<FileStat> and answers
    # neither. A row that shadowed `#numstat` with an aggregate would read as
    # satisfied against a double and crash on the real object.
    it "answers a commit entry's added and deleted as scalars" do
      walk = open_session.marked.by_commit

      expect(walk.map { |row| [row.added, row.deleted] }).to eq([[3, 1], [5, 2]])
    end

    it "forwards #numstat unshadowed, still the Array<FileStat> CommitScope answers" do
      row = open_session.marked.by_commit.first

      expect(row.numstat).to eq(changeset.by_commit.first.numstat)
    end

    it "carries the same file row object under a commit as at cumulative scope, so one mark redraws both" do
      marked = open_session.marked

      expect(marked.by_commit.first.files.first).to be(marked.files.first)
    end

    it "forwards the diff's own facts on a file row, unchanged and unrenamed" do
      row = open_session.marked.files.first

      expect([row.status, row.binary?, row.old_path, row.new_path]).to eq([:modified, false, "a.rb", "a.rb"])
    end

    it "keeps the changeset's own base and head, which every anchor rests on" do
      marked = open_session.marked

      expect([marked.base_ref, marked.head_ref]).to eq([base_sha, head_sha])
    end

    # CommitScope answers neither #hunks nor #base_ref on purpose, so a FILTERED
    # scope can never reach Marks#reconcile. A row that delegated everything
    # would hand that guarantee back.
    it "does not let a commit row answer the pair Marks#reconcile reads" do
      row = open_session.marked.by_commit.first

      expect(row).not_to respond_to(:hunks)
      expect(row).not_to respond_to(:base_ref)
    end
  end

  describe "a file the diff changed but no hunk covers" do
    let(:binary_changeset) do
      changeset_over(diff_text: binary_diff_for("logo.png"),
                     walk: [commit(sha: "e" * 40, subject: "art", paths: ["logo.png"], added: nil, deleted: nil)])
    end

    it "renders as unreviewed, because no hunk of it has been marked" do
      session = open_session(over: binary_changeset)

      expect(session.marked.files.map { |row| [row.path, row.state] }).to eq([["logo.png", "unreviewed"]])
    end

    # The honest reading, and the one that keeps the two facts from disagreeing:
    # the ROW says "no hunk here is marked reviewed" (true, and unchangeable),
    # while the POLICY judges hunks and finds none outstanding. A row that
    # claimed `reviewed` would claim a review nobody did.
    it "does not block an approve, because it has no unreviewed hunk to block with" do
      session = open_session(over: binary_changeset)

      expect { session.submit("approve") }.not_to raise_error
    end

    it "answers no hunk keys, so nothing can be marked on it" do
      expect(open_session(over: binary_changeset).marked.files.first.hunk_keys).to be_empty
    end

    # git spells a binary file's stats `-`, not 0, precisely because 0/0 is a
    # claim about lines nobody can make. The sums skip them, so the count is
    # what keeps a `+0 -0` commit row from reading as "nothing changed".
    it "counts the binary files its line sums had to skip" do
      row = open_session(over: binary_changeset).marked.by_commit.first

      expect([row.added, row.deleted, row.binaries]).to eq([0, 0, 1])
    end
  end

  describe "submitting a verdict" do
    it "journals the verdict against the changeset it judged" do
      session = open_session
      every_key.each { |key| session.mark(key, "reviewed") }

      session.submit("approve")

      expect(records_of("review_verdict").last)
        .to include("verdict" => "approve", "changeset_digest" => session.digest)
    end

    it "reports the verdict afterwards, in the vocabulary's own spelling" do
      session = open_session
      every_key.each { |key| session.mark(key, "reviewed") }

      session.submit("approve")

      expect(session.verdict).to eq("approve")
    end

    it "refuses a verdict outside VERDICTS rather than widening the vocabulary by accident" do
      session = open_session
      every_key.each { |key| session.mark(key, "reviewed") }

      expect { session.submit("looks-fine") }.to raise_error(ArgumentError, /approve/)
      expect(records_of("review_verdict")).to be_empty
    end

    it "refuses a second verdict, so a journal never shows one round judged twice" do
      session = open_session
      every_key.each { |key| session.mark(key, "reviewed") }
      session.submit("approve")

      expect { session.submit("approve") }.to raise_error(described_class::AlreadySettled)
    end

    describe "admissibility, which is the policy's and not the session's" do
      it "records a verdict over a partially reviewed changeset when the policy admits everything" do
        session = open_session(policy: Lain::Review::Verdict::Policy::Permissive.new)
        session.mark(keys_for("a.rb").first, "reviewed")

        session.submit("approve")

        expect(session.verdict).to eq("approve")
        expect(records_of("review_verdict").last).to include("verdict" => "approve")
      end

      it "refuses the same submission under the default policy, naming the file" do
        session = open_session
        session.mark(keys_for("a.rb").first, "reviewed")

        expect { session.submit("approve") }
          .to raise_error(Lain::Review::Verdict::Policy::Incomplete, /a\.rb/)
      end

      it "journals nothing when the policy refuses, so a refused approve leaves no judgement on record" do
        session = open_session
        session.mark(keys_for("a.rb").first, "reviewed")

        expect { session.submit("approve") }.to raise_error(Lain::Review::Verdict::Policy::Incomplete)
        expect(records_of("review_verdict")).to be_empty
        expect(session.verdict).to be(Lain::Review::Verdict::None)
      end

      it "asks the policy with the changeset and the marks, and takes no admissibility decision itself" do
        policy = instance_spy(Lain::Review::Verdict::Policy::Permissive)
        session = open_session(policy:)

        session.submit("approve")

        expect(policy).to have_received(:admit!).with("approve", changeset:, marks: session.marks)
      end
    end
  end

  # `.open` states an invariant for the round head -- nothing is ever held
  # without a record behind it -- and it was pinned for `.open` ALONE. The
  # ordering that makes it true of every other write had no test at all: a
  # mutation pass reversed `#mark`'s two lines and moved a file from unreviewed
  # to partial with nothing on record, entirely green. The ordering is the
  # invariant, so it is spec'd like one.
  describe "a journal that refuses the write" do
    let(:spy) { instance_spy(Lain::Review::Surface::Null) }

    # Built through a working journal, then made to refuse: `.open` has to land
    # its head before there is a session to mark anything on.
    def session_over_a_failing_journal(policy: Lain::Review::Verdict::Policy.default)
      brittle = instance_double(Lain::Journal)
      allow(brittle).to receive(:<<)
      session = described_class.open(changeset:, journal: brittle, source: "local_branch", surface: spy, policy:)
      allow(brittle).to receive(:<<).and_raise(Lain::Journal::Closed, "journal is closed")
      session
    end

    it "leaves the mark set, and the tri-state a surface renders from it, untouched" do
      session = session_over_a_failing_journal

      expect { session.mark(keys_for("a.rb").first, "reviewed") }.to raise_error(Lain::Journal::Closed)

      expect(session.marks.to_h).to be_empty
      expect(session.marked.files.map(&:state)).to eq(%w[unreviewed unreviewed])
    end

    it "does not tell the surface a mark it could not record" do
      session = session_over_a_failing_journal

      expect { session.mark(keys_for("a.rb").first, "reviewed") }.to raise_error(Lain::Journal::Closed)

      expect(spy).not_to have_received(:mark)
    end

    it "leaves the notes untouched, and tells the surface nothing" do
      session = session_over_a_failing_journal

      expect { session.annotate(anchor_on("a.rb", 2, "TWO"), "here", kind: :note, drifted: false) }
        .to raise_error(Lain::Journal::Closed)

      expect(session.annotations).to be_empty
      expect(spy).not_to have_received(:annotate)
    end

    it "leaves the verdict absent, so an unrecorded approve is not one" do
      session = session_over_a_failing_journal(policy: Lain::Review::Verdict::Policy::Permissive.new)

      expect { session.submit("approve") }.to raise_error(Lain::Journal::Closed)

      expect(session.verdict).to be(Lain::Review::Verdict::None)
      expect(session.judgement).to be(Lain::Review::Verdict::None)
    end
  end

  # The two ways a record can fail to come back, which sound alike and are
  # refused differently -- only one of them can be refused at all.
  describe "records the journal cannot give back whole" do
    it "loses a mark whose LINE was torn, because a line that never parses never reaches a guard" do
      session = open_session
      session.mark(keys_for("a.rb").first, "reviewed")
      whole = entries
      torn = whole.dup
      torn[-1] = "#{torn.last[0, 30]}\n"

      rebuilt = described_class.from_journal(torn, changeset:, journal:, surface:)

      # The control. Without it this example is green whether tearing lost the
      # mark or the mark was never journaled at all -- and "never journaled" is
      # a defect this suite has to be able to see.
      expect(described_class.from_journal(whole, changeset:, journal:, surface:).marks.to_h.size).to eq(1)
      expect(rebuilt.marks.to_h).to be_empty
      expect(rebuilt.opened).not_to be_nil
    end

    it "aborts the whole rebuild on a record that PARSES and is not a whole one" do
      open_session
      blank_key = { "type" => "hunk_marked", "hunk_key" => "", "state" => "reviewed" }

      expect { described_class.from_journal(entries + [blank_key], changeset:, journal:, surface:) }
        .to raise_error(ArgumentError, /hunk_key/)
    end

    # The one record that could once say anything at all and still fold: the
    # first-wins guard used to short-circuit before the record was rebuilt, so
    # a malformed SECOND verdict was never constructed and never refused.
    it "aborts on a malformed SECOND verdict, which the first-wins rule must not exempt" do
      session = open_session
      every_key.each { |key| session.mark(key, "reviewed") }
      session.submit("approve")
      nonsense = { "type" => "review_verdict", "verdict" => "shipit", "changeset_digest" => "" }

      expect { described_class.from_journal(entries + [nonsense], changeset:, journal:, surface:) }
        .to raise_error(ArgumentError, /verdict/)
    end

    it "aborts on a note whose line is not a diff position, rather than restoring it somewhere else" do
      session = open_session
      session.annotate(anchor_on("a.rb", 2, "TWO"), "here", kind: :note, drifted: false)
      records = Lain::Journal.records(entries).to_a
      records.last["line"] = 0

      expect { described_class.from_journal(records, changeset:, journal:, surface:) }
        .to raise_error(ArgumentError, /line/)
    end
  end

  # The Journal's fd is shared -- Rust tracing spans land on it -- so a foreign
  # line is the expected case, not an exotic one, and nothing in this suite fed
  # the fold one until a review panel's own probe did.
  describe "records this fold did not write" do
    def foreign_lines
      ['{"ts":"2026-08-04T00:00:00Z","level":"INFO","target":"lain_core","message":"span closed"}',
       '{"ts":"2026-08-04T00:00:01Z","type":"tool_output","name":"grep","bytes":12}',
       "not json at all, and not even close"].map { |line| "#{line}\n" }
    end

    it "ignores them exactly, wherever in the round they land" do
      session = open_session
      session.mark(keys_for("a.rb").first, "reviewed")
      session.annotate(anchor_on("a.rb", 2, "TWO"), "here", kind: :note, drifted: false)
      interleaved = entries.flat_map { |line| [*foreign_lines, line] } + foreign_lines

      rebuilt = described_class.from_journal(interleaved, changeset:, journal:, surface:)

      expect(rebuilt.marks.to_h.size).to eq(1)
      expect(rebuilt.annotations.map(&:text)).to eq(["here"])
    end

    it "still finds the round head with foreign lines on either side of it" do
      open_session

      rebuilt = described_class.from_journal(foreign_lines + entries + foreign_lines,
                                             changeset:, journal:, surface:)

      expect(rebuilt.opened.source).to eq("local_branch")
    end
  end

  describe "rebuilding from the journal" do
    def live_round
      session = open_session
      keys = every_key
      keys.each { |key| session.mark(key, "reviewed") }
      session.annotate(anchor_on("a.rb", 2, "TWO"), "first note", kind: :note, drifted: false)
      session.annotate(anchor_on("b.rb", 2, "Y", revision: changeset.by_commit.last.sha), "second", kind: :blocker,
                                                                                                    drifted: true)
      session
    end

    def replayed(over: changeset, entries_from: entries)
      described_class.from_journal(entries_from, changeset: over, journal:, surface:)
    end

    # The card's first scenario, whole.
    it "reports the same annotations, the same marks and the same absent verdict" do
      live = live_round

      rebuilt = replayed

      expect(rebuilt.annotations).to eq(live.annotations)
      expect(rebuilt.marks.to_h).to eq(live.marks.to_h)
      expect(rebuilt.verdict).to be(Lain::Review::Verdict::None)
    end

    it "rebuilds 2 annotations and 3 marks, not merely an equal pair of empties" do
      live_round

      rebuilt = replayed

      expect(rebuilt.annotations.size).to eq(2)
      expect(rebuilt.marks.to_h.size).to eq(3)
    end

    it "restores each note's own revision, kind and drift rather than a uniform default" do
      live_round

      rebuilt = replayed

      expect(rebuilt.annotations.map { |note| [note.kind, note.drifted, note.revision] })
        .to eq([["note", false, head_sha], ["blocker", true, changeset.by_commit.last.sha]])
    end

    it "restores a submitted verdict" do
      session = live_round
      session.submit("approve")

      expect(replayed.verdict).to eq("approve")
    end

    it "restores the changeset that verdict judged, which a position in the journal cannot imply" do
      session = live_round
      session.submit("approve")

      expect(replayed.judgement.changeset_digest).to eq(session.digest)
    end

    # `#submit` refuses a second verdict outright, so a live session's state
    # after two submissions is its FIRST -- the second never happened. The fold
    # took the last, which is a rule it invented and which let replay reach a
    # state the live session would have refused. Two verdicts in one round need
    # two writers on one journal: `#submit` cannot produce that alone, two
    # Sessions over one file can, which is what the second write below is.
    #
    # Only `changeset_digest` can tell the two apart today, because VERDICTS has
    # one member -- which is exactly why the rule has to be pinned now rather
    # than when a second value makes it visible in the word itself.
    it "keeps the FIRST judgement when two writers judged one round, as submit's refusal implies" do
      session = live_round
      session.submit("approve")
      journal << Lain::Review::ReviewVerdict.new(verdict: "approve",
                                                 changeset_digest: "review-changeset-v1:written-by-somebody-else")

      rebuilt = replayed

      expect(records_of("review_verdict").size).to eq(2)
      expect(rebuilt.judgement.changeset_digest).to eq(session.digest)
    end

    it "refuses a further verdict on the round it rebuilt, exactly as the live session did" do
      session = live_round
      session.submit("approve")

      expect { replayed.submit("approve") }.to raise_error(described_class::AlreadySettled)
    end

    it "restores the head of the round, so a resumed session still knows what it opened over" do
      live = live_round

      expect(replayed.opened).to eq(live.opened)
    end

    it "refuses a journal that never opened a review here, rather than looking like a fresh one" do
      expect { replayed(entries_from: []) }.to raise_error(described_class::NotOpened)
    end

    it "prunes a mark whose hunk the regenerated diff no longer produces" do
      live_round

      rebuilt = replayed(over: changeset_over(diff_text: rewritten_diff))

      expect(rebuilt.marks.to_h).to be_empty
    end

    # Marks are pinned to a base revision and refuse to cross one. Replay must
    # honour that: the round was opened against one base, and rebuilding it
    # against another would hand a stale mark to a hunk that merely sits where
    # the old one did.
    it "refuses to rebuild a round against a different base" do
      live_round

      expect { replayed(over: changeset_over(base_ref: "0" * 40)) }
        .to raise_error(Lain::Review::Marks::BaseMismatch)
    end

    it "writes nothing while rebuilding, so a resume does not double the journal" do
      live_round
      before = entries.size

      replayed

      expect(entries.size).to eq(before)
    end

    it "goes on recording after a resume, into the round it rebuilt" do
      live_round
      rebuilt = replayed

      rebuilt.annotate(anchor_on("a.rb", 2, "TWO"), "after the restart", kind: :note, drifted: false)

      expect(replayed.annotations.map(&:text)).to eq(["first note", "second", "after the restart"])
    end
  end

  describe "rounds" do
    # The card's third scenario. Nothing re-anchors a note onto a later round:
    # they are produced, consumed, then historical.
    it "holds no annotations when a new session opens over rewritten commits" do
      first = open_session
      first.annotate(anchor_on("a.rb", 2, "TWO"), "old round", kind: :note, drifted: false)
      every_key.each { |key| first.mark(key, "reviewed") }
      first.submit("approve")

      second = open_session(over: changeset_over(diff_text: rewritten_diff))

      expect(second.annotations).to be_empty
    end

    it "leaves the prior round's annotations readable from the journal" do
      first = open_session
      first.annotate(anchor_on("a.rb", 2, "TWO"), "old round", kind: :note, drifted: false)
      open_session(over: changeset_over(diff_text: rewritten_diff))

      expect(records_of("annotation_placed").map { |record| record["text"] }).to eq(["old round"])
    end

    it "rebuilds the LATEST round, not an older one that shared the journal" do
      first = open_session
      first.annotate(anchor_on("a.rb", 2, "TWO"), "old round", kind: :note, drifted: false)
      rewritten = changeset_over(diff_text: rewritten_diff)
      open_session(over: rewritten).annotate(anchor_on("a.rb", 2, "DEUX"), "new round", kind: :note, drifted: false)

      rebuilt = described_class.from_journal(entries, changeset: rewritten, journal:, surface:)

      expect(rebuilt.annotations.map(&:text)).to eq(["new round"])
    end

    it "does not carry the prior round's marks either" do
      first = open_session
      every_key.each { |key| first.mark(key, "reviewed") }
      rewritten = changeset_over(diff_text: rewritten_diff)
      open_session(over: rewritten)

      rebuilt = described_class.from_journal(entries, changeset: rewritten, journal:, surface:)

      expect(rebuilt.marks.to_h).to be_empty
    end
  end

  describe "replay against the live session" do
    # The card's third escalation trigger, as an assertion rather than a hope:
    # if these two sets ever differ for one journal, the content-addressing is
    # not holding and T8 is invalid.
    it "produces the identical mark set, key for key, for the same journal and changeset" do
      live = open_session
      every_key.each { |key| live.mark(key, "reviewed") }
      live.mark(keys_for("b.rb").first, "unreviewed")

      rebuilt = described_class.from_journal(entries, changeset:, journal:, surface:)

      expect(rebuilt.marks.to_h).to eq(live.marks.to_h)
    end

    it "produces the identical tri-state per file, which is what a surface actually renders" do
      live = open_session
      keys_for("a.rb").each { |key| live.mark(key, "reviewed") }

      rebuilt = described_class.from_journal(entries, changeset:, journal:, surface:)

      expect(rebuilt.marked.files.map(&:state)).to eq(live.marked.files.map(&:state))
    end

    it "takes the last word when one hunk was marked twice" do
      live = open_session
      key = keys_for("a.rb").first
      live.mark(key, "reviewed")
      live.mark(key, "unreviewed")

      rebuilt = described_class.from_journal(entries, changeset:, journal:, surface:)

      expect(rebuilt.marks.to_h.fetch(key)).to eq("unreviewed")
      expect(rebuilt.marks.to_h).to eq(live.marks.to_h)
    end
  end

  # A green T7 and a green T9 still do not render a table: until this card,
  # nothing joined a changeset's structure to marks' tri-state, so neither
  # spec could drive a real renderer over a real changeset -- T9's own doubles
  # are anonymous Structs. These two do it end to end, which is the only place
  # the row object's shape is checked against a consumer rather than against
  # an expectation written to match it.
  describe "composed with a real text surface" do
    let(:sink) { StringIO.new }

    def rendering_session
      described_class.open(changeset:, journal:, source: "local_branch",
                           surface: Lain::Review::Surface::Text.new(sink:))
    end

    # All THREE rows, not two. The tri-state legend has three glyphs and the
    # first cut of this example rendered `[x]` and `[ ]` only, so `[~]` -- the
    # one state that exists solely because a file can be partly reviewed, and
    # the only one neither Changeset nor Marks can answer alone -- was never
    # drawn by any test in this chunk.
    it "renders a cumulative row per file, covering every glyph in the tri-state legend" do
      session = rendering_session
      keys_for("a.rb").first.then { |key| session.mark(key, "reviewed") }
      keys_for("b.rb").each { |key| session.mark(key, "reviewed") }
      session.mark(keys_for("a.rb").last, "reviewed")
      session.mark(keys_for("a.rb").last, "unreviewed")

      session.present(scope: :cumulative)

      expect(sink.string).to end_with("[~] a.rb\n[x] b.rb\n")
    end

    it "renders the unreviewed glyph too, so all three of FILE_STATES are drawn by this suite" do
      rendering_session.present(scope: :cumulative)

      expect(sink.string).to end_with("[ ] a.rb\n[ ] b.rb\n")
    end

    it "renders the commit walk with each commit's subject and its own files beneath it" do
      rendering_session.present(scope: :commits)

      expect(sink.string).to end_with("first: touch a\n  [ ] a.rb\n\nsecond: touch b\n  [ ] b.rb\n")
    end
  end

  # CLAUDE.md's rule: a value object is deeply frozen, and `Ractor.shareable?`
  # is the MECHANICAL statement of "no reachable mutable state" -- it broke once
  # already because `Symbol#to_s` and interpolation both answer mutable Strings.
  # Every value this card added is spec'd against it, including the row graph,
  # whose leaves are T7's ChangedFile/CommitScope and T2's Hunk.
  describe "the values this card adds are shareable" do
    it "holds for the whole marked-changeset graph, rows, files and commits alike" do
      session = open_session
      session.mark(keys_for("a.rb").first, "reviewed")

      expect(Ractor.shareable?(session.marked)).to be(true)
    end

    it "holds for the record a note becomes" do
      session = open_session
      placed = session.annotate(anchor_on("a.rb", 2, "TWO"), "here", kind: :note, drifted: false)

      expect(Ractor.shareable?(placed)).to be(true)
    end

    it "holds for the round head and for the judgement that closes it" do
      session = open_session
      every_key.each { |key| session.mark(key, "reviewed") }
      session.submit("approve")

      expect(Ractor.shareable?(session.opened)).to be(true)
      expect(Ractor.shareable?(session.judgement)).to be(true)
    end

    it "holds for the null verdict, which is shared by every session that has none" do
      expect(Ractor.shareable?(Lain::Review::Verdict::None)).to be(true)
    end
  end

  # `opened.digest` is the address as the round OPENED; `#digest` is the address
  # now. Nothing read the first until this predicate did, and a journaled field
  # with no reader is a field that quietly stops being true.
  describe "telling a resumed round that its diff has moved" do
    it "answers false for a session over the changeset it opened" do
      expect(open_session).not_to be_regenerated
    end

    it "answers false after an amend that changed nothing, since both sides are content addresses" do
      open_session

      rebuilt = described_class.from_journal(entries, changeset: changeset_over(head_ref: "z" * 40),
                                                      journal:, surface:)

      expect(rebuilt).not_to be_regenerated
    end

    it "answers true when the diff regenerated under the resumed round" do
      open_session

      rebuilt = described_class.from_journal(entries, changeset: changeset_over(diff_text: rewritten_diff),
                                                      journal:, surface:)

      expect(rebuilt).to be_regenerated
    end
  end

  describe "the surface's verdict query, and why the session never asks it" do
    # Surface::Null#verdict returns nil and its comment names the tension for
    # this card. The resolution is that a verdict is PUSHED (a gesture reaching
    # #submit), never PULLED, so no nil ever reaches the session -- and the
    # session's own reader is a null object, so no CALLER nil-checks either.
    it "never asks a surface for a verdict" do
      spy = instance_spy(Lain::Review::Surface::Null)
      session = open_session(surface: spy)
      every_key.each { |key| session.mark(key, "reviewed") }

      session.present(scope: :cumulative)
      session.submit("approve")

      expect(spy).not_to have_received(:verdict)
    end

    it "answers a null verdict, not nil, before anything is submitted" do
      expect(open_session.verdict).to be(Lain::Review::Verdict::None)
    end

    it "answers a verdict that is #empty? either way, so a caller needs no type test" do
      session = open_session

      expect(session.verdict).to be_empty
      every_key.each { |key| session.mark(key, "reviewed") }
      session.submit("approve")
      expect(session.verdict).not_to be_empty
    end
  end
end
