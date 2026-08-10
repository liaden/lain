# frozen_string_literal: true

require "stringio"
require "tmpdir"

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

  # Wrapped in {DiffSource}, so `files` and `identity` are the PRODUCTION
  # composition rather than two more stubs -- see that file for why stubbing
  # them would make every digest example below assert about its own fixture.
  def source_double(diff_text: diff, walk: commits, base_ref: base_sha, head_ref: head_sha)
    DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                    diff: diff_text.b, commits: walk.freeze, base_ref:, head_ref:))
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

  # The commit walk, which is what the session still groups by -- named once
  # here so an example reaching for a commit's sha says which grouping it read
  # it out of.
  def walk = Lain::Review::Partition::STRATEGIES.fetch(:commits)

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

    # The address moved OFF this class and onto the source (B2), and the whole
    # requirement was that it not move a byte in doing so: `/review` addresses are
    # journalled, and a `changeset_digest` that stopped joining would silently
    # orphan every verdict ever recorded.
    #
    # Recomposed HERE, independently, exactly as `Session.digest_parts` composed
    # it -- base, then path/status/keys per file, with the keys derived by
    # {MarkedChangeset.keys_by_path} rather than by the source. That second half
    # is the anti-drift half: the source now writes the `group_by(&:path)` +
    # `Hunk.keys` rule for itself, and a session addressing a changeset by keys
    # the marks do not recognise would unmark everything without failing
    # anything else.
    it "composes the address the parts were composed in before it moved to the source, byte for byte" do
      keys = Lain::Review::Session::MarkedChangeset.keys_by_path(changeset)
      parts = [changeset.base_ref,
               *changeset.files.flat_map { |file| [file.path, file.status.to_s, *keys.fetch(file.path, [])] }]

      expect(described_class.digest(changeset))
        .to eq(Lain::Review::Keying.digest("review-changeset-v1", parts))
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
      one_commit = changeset.partitions(walk).first.detail.sha

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

    it "refuses a scope no strategy declares rather than falling through to a default" do
      session = open_session

      expect { session.present(scope: :cumulatve) }.to raise_error(described_class::UnknownScope, /cumulatve/)
    end

    # The whole of A3 in one example: a strategy that ships is a scope that
    # resolves, with nothing to edit in between. `by_directory` was registered
    # by the card before this one and was NOT reachable, because the vocabulary
    # was a second list of two literals.
    it "resolves every registered strategy, so shipping one is all it takes to reach it" do
      spy = instance_spy(Lain::Review::Surface::Null)
      session = open_session(surface: spy)

      Lain::Review::Partition::STRATEGIES.each_key { |scope| session.present(scope:) }

      expect(spy).to have_received(:present)
        .with(anything, scope: satisfy { |scope| Lain::Review::Partition::STRATEGIES.key?(scope) })
        .exactly(Lain::Review::Partition::STRATEGIES.size).times
    end

    it "names the whole registry when it refuses, so a reader learns what they could have said" do
      session = open_session

      expect { session.present(scope: :by_size) }
        .to raise_error(described_class::UnknownScope, /by_directory/)
    end

    # A name and the strategy it names are ONE value, and the reason is this
    # repo's own "one classifier, and disagreement is unrepresentable" rule at
    # small scale: a pair carried as two arguments can be handed a name from one
    # scope and a strategy from another, and the refusal then blames the scope it
    # never tested. {Session::Scope.resolve} derives the second member from the
    # first and is the only door in, so the disagreeing pair cannot be
    # constructed rather than being merely untested.
    it "hands the strategy over WITH the name" do
      resolved = described_class::Scope.resolve("by_directory")

      expect(resolved.name).to eq(:by_directory)
      expect(resolved.strategy).to be(Lain::Review::Partition::STRATEGIES.fetch(:by_directory))
    end

    # The half that makes the sentence above true rather than merely intended.
    # BOTH doors: `Data.define` mints `.[]` beside `.new`, and privatising one
    # leaves the other wide open -- verified, not assumed.
    it "offers no second door through which a disagreeing pair could be built" do
      commits = Lain::Review::Partition::STRATEGIES.fetch(:commits)

      expect { described_class::Scope.new(name: :by_directory, strategy: commits) }
        .to raise_error(NoMethodError, /private method/)
      expect { described_class::Scope[name: :by_directory, strategy: commits] }
        .to raise_error(NoMethodError, /private method/)
    end

    it "refuses an unresolvable name at the one door there is" do
      expect { described_class::Scope.resolve(:by_size) }
        .to raise_error(described_class::UnknownScope, /by_size/)
    end

    # The half of resolution that a name alone does not finish. A marked
    # changeset CARRIES its partitions, so a view built at one strategy and
    # drawn at another renders the wrong grouping under the right heading --
    # `--scope by_directory` drew the COMMIT walk, labels and all, and the
    # scope word in the headline was the only thing that changed.
    it "groups the view by the strategy the scope resolved to, not by the walk" do
      spy = instance_spy(Lain::Review::Surface::Null)
      session = open_session(surface: spy)

      session.present(scope: :by_directory)

      expect(spy).to have_received(:present)
        .with(having_attributes(partitions: all(having_attributes(label: "."))), scope: :by_directory)
    end
  end

  # The SECOND refusal, and it is deliberately not the first one's business:
  # `scope!` is a class-level validator with no collaborators, so it can say
  # whether a name is a strategy and cannot say whether THIS source can be
  # grouped that way. Different questions, different sentences.
  describe "a strategy the source cannot answer for" do
    # Exactly `diff`, `base_ref` and `head_ref` -- a Data answers those three
    # and genuinely does not answer `#commits`, which is what makes this an
    # honest stand-in for the corpus source rather than a double that merely
    # says so. An `instance_double` of a real Source would still respond to the
    # walk and the example would pass against a subject that never checked.
    #
    # Wrapped in {DiffSource} for the port's model-value half (`#files` and
    # `#identity`) and for nothing else: the wrapper is a `SimpleDelegator`, so
    # `respond_to?(:commits)` still reaches the Data and still answers false,
    # which is the whole property these examples rest on. The Data itself
    # cannot include `Source::Diffed` -- a Data instance is frozen, so the
    # module's `@files ||=` memo raises `FrozenError` on first read.
    def commitless_changeset
      data = Data.define(:diff, :base_ref, :head_ref)
                 .new(diff: diff.b, base_ref: base_sha, head_ref: head_sha)
      Lain::Review::Changeset.new(source: DiffSource.over(data))
    end

    it "refuses the commit walk, naming the scope and the source" do
      session = open_session(over: commitless_changeset)

      expect { session.present(scope: :commits) }
        .to raise_error(described_class::UnsupportedScope, /commits.*local_branch/m)
    end

    # A refusal that only says no leaves the reader to guess what would have
    # worked. The alternatives are MEASURED against this very source, so the
    # message cannot recommend a second grouping it would also refuse -- and
    # the scope that failed is not among them.
    it "names the scopes this source DOES support, so the refusal is actionable" do
      session = open_session(over: commitless_changeset)

      expect { session.present(scope: :commits) }
        .to raise_error(described_class::UnsupportedScope) { |error|
          offered = error.message[/\[(.*?)\]/, 1]
          expect(offered).to include(":cumulative", ":by_directory")
          expect(offered).not_to include(":commits")
        }
    end

    # The reason this refusal exists at all: without it the walk dies on a
    # missing message somewhere inside the partition, which names neither the
    # scope the human asked for nor the source that could not serve it. The
    # class is asserted exactly, so a `NoMethodError` from the walk fails here
    # rather than reading as "it refused".
    it "refuses rather than dying on the missing message inside the walk" do
      session = open_session(over: commitless_changeset)

      raised = begin
        session.present(scope: :commits)
      rescue StandardError => e
        e
      end

      expect(raised).to be_a(described_class::UnsupportedScope)
    end

    it "still presents at a scope the source CAN answer for" do
      session = open_session(over: commitless_changeset)

      expect { session.present(scope: :by_directory) }.not_to raise_error
    end

    # Applicability is checked BEFORE the ceiling, because the ceiling walks
    # the partitions and that walk is what would die.
    it "refuses before the size guard reads a partition" do
      session = open_session(over: commitless_changeset, bounds: Lain::Review::Bounds.new(max_files: 0))

      expect { session.present(scope: :commits) }.to raise_error(described_class::UnsupportedScope)
    end
  end

  # T31c. {Lain::Review::Bounds#check_presentation!} used to be called from
  # {Lain::CLI::Review#present} and nowhere else -- so the ONE text command that
  # remembered to ask was bounded and every editor surface was not: `/review` of
  # an 800-file pull request drew all of it into the sidebar. The guard lives
  # here now, which is the one place every surface is reached through, and there
  # is exactly one caller of it in the tree (`bounds_spec.rb` pins that count
  # mechanically, because prose cannot).
  describe "the size past which it refuses to present" do
    # The DEFAULT ceiling, reached by a changeset rather than by an injected
    # Bounds: a session that bounded only what a caller handed it ceilings for
    # would pass every other example in this block and still draw this one
    # whole. 301 files against {Lain::Review::Bounds::DEFAULT_MAX_FILES}.
    def oversized_changeset(count: Lain::Review::Bounds::DEFAULT_MAX_FILES + 1)
      paths = Array.new(count) { |index| "file_#{index}.rb" }
      changeset_over(diff_text: oversized_diff(paths), walk: [oversized_commit(paths)])
    end

    def oversized_diff(paths) = paths.map { |path| one_hunk_section(path) }.join

    def one_hunk_section(path)
      <<~DIFF
        diff --git a/#{path} b/#{path}
        index 1111111..2222222 100644
        --- a/#{path}
        +++ b/#{path}
        @@ -1,2 +1,2 @@ def alpha
         x
        -y
        +Y
      DIFF
    end

    def oversized_commit(paths)
      numstat = paths.map { |path| Lain::Review::Source::FileStat.new(path: -path, added: 1, deleted: 1) }
      Lain::Review::Source::Commit.new(sha: -("e" * 40), subject: "the wide commit", body: "",
                                       numstat: numstat.freeze)
    end

    def bounded(**ceilings) = open_session(bounds: Lain::Review::Bounds.new(**ceilings))

    def bounded_onto(drawn, **ceilings) = open_session(surface: drawn, bounds: Lain::Review::Bounds.new(**ceilings))

    it "refuses a changeset past the DEFAULT file ceiling, with no Bounds injected at all" do
      session = open_session(over: oversized_changeset)

      expect { session.present(scope: :cumulative) }
        .to raise_error(Lain::Review::Bounds::TooLarge, /301 files.*ceiling of 300/m)
    end

    it "names the measurement, the ceiling and the alternative, in Bounds' own words" do
      expect { bounded(max_files: 1).present(scope: :cumulative) }
        .to raise_error(Lain::Review::Bounds::TooLarge, /2 files.*ceiling of 1.*scope: commits/m)
    end

    # A refusal that has already rendered is not a refusal, and for an editor
    # surface it is worse than none: the sidebar is up, so the human believes
    # they are looking at the whole changeset.
    it "draws nothing at all when it refuses, so the guard runs before the surface is told" do
      spy = instance_spy(Lain::Review::Surface::Null)

      expect { bounded_onto(spy, max_files: 1).present(scope: :cumulative) }
        .to raise_error(Lain::Review::Bounds::TooLarge)
      expect(spy).not_to have_received(:present)
    end

    # The scope reaching the guard is the RESOLVED one, and this pins both
    # halves of that. A guard reading its argument raw dies on
    # `SCOPE_CHECKS.fetch` with a KeyError for the String spelling a wire sends;
    # a guard reading the wrong scope refuses the commit walk that the refusal
    # above advertises as the way through, which would make the advice a lie.
    it "bounds the scope it resolved, so the walk this refusal recommends actually presents" do
      session = bounded(max_files: 1)

      expect { session.present(scope: "cumulative") }
        .to raise_error(Lain::Review::Bounds::TooLarge, /cumulative view/)
      expect { session.present(scope: "commits") }.not_to raise_error
    end

    # The marked view is built AT the scope presented, so the expectation names
    # the flat grouping rather than reading `#marked`'s default -- a view built
    # at the walk and drawn at `cumulative` is the defect, not the baseline.
    it "presents whatever fits, so an ordinary changeset reaches the surface untouched" do
      spy = instance_spy(Lain::Review::Surface::Null)
      session = bounded_onto(spy, max_files: 2)

      session.present(scope: :cumulative)

      flat = session.marked(strategy: Lain::Review::Partition::STRATEGIES.fetch(:cumulative))
      expect(spy).to have_received(:present).with(flat, scope: :cumulative)
    end

    # A resume is where a diff has had time to GROW -- the author went on
    # working -- so a resumed round that skipped the ceiling would be the one
    # most likely to meet it.
    it "bounds a resumed round too, not only one this process opened" do
      open_session
      resumed = described_class.from_journal(entries, changeset:, journal:, surface:,
                                                      bounds: Lain::Review::Bounds.new(max_files: 1))

      expect { resumed.present(scope: :cumulative) }.to raise_error(Lain::Review::Bounds::TooLarge)
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
      marks = instance_double(Lain::Review::Marks, assert_same_base!: nil, state_of: :skimmed)

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

    # A partition row is headed by its LABEL, which for the commit walk is the
    # commit's subject. The sha is on the DETAIL, because a directory partition
    # has none and a row that forwarded one would be lying on every strategy
    # but this one.
    it "answers a partition entry's label and its share of the files" do
      rows = open_session.marked.partitions

      expect(rows.map { |row| [row.label, row.files.map(&:path)] })
        .to eq([["first: touch a", ["a.rb"]], ["second: touch b", ["b.rb"]]])
    end

    # The ruling: `ByCommit::Commit#numstat` is an Array<FileStat> and answers
    # neither. A row that shadowed `#numstat` with an aggregate would read as
    # satisfied against a double and crash on the real object.
    it "answers a partition entry's added and deleted as scalars" do
      rows = open_session.marked.partitions

      expect(rows.map { |row| [row.added, row.deleted] }).to eq([[3, 1], [5, 2]])
    end

    # The commit's OWN figure, not the group's share of the diff, and it is the
    # DETAIL that decides that: a partition whose strategy reports no accounting
    # gets the hunk-derived count instead, which is what keeps a directory row
    # from rendering a numstat nobody produced.
    it "reads the accounting off the detail rather than counting the group's hunks" do
      rows = open_session.marked.partitions
      hunkwise = Lain::Review::Partition::Undetailed

      expect(rows.map(&:added)).not_to eq(rows.map { |row| hunkwise.added(row.files) })
    end

    it "leaves #numstat on the detail, still the Array<FileStat> a commit answers" do
      row = open_session.marked.partitions.first

      expect(row.detail.numstat).to eq(changeset.partitions(walk).first.detail.numstat)
    end

    it "does not forward a commit's own facts onto the row, which no directory could answer" do
      row = open_session.marked.partitions.first

      expect(row).not_to respond_to(:sha)
      expect(row).not_to respond_to(:numstat)
    end

    it "carries the same file row object under a partition as at whole scope, so one mark redraws both" do
      marked = open_session.marked

      expect(marked.partitions.first.files.first).to be(marked.files.first)
    end

    # The join is built at whichever strategy it is handed, so the axis reaches
    # the renderers rather than stopping at the changeset. The session still
    # asks for the walk, which is what keeps this a rename and not a feature.
    it "joins at whichever strategy it is built with, not only the commit walk" do
      by_directory = Lain::Review::Session::MarkedChangeset
                     .of(changeset, Lain::Review::Marks.new(base_ref: base_sha),
                         strategy: Lain::Review::Partition::ByDirectory.new)

      expect(by_directory.partitions.map(&:label)).to eq(["."])
      expect(by_directory.partitions.first.files.map(&:path)).to eq(%w[a.rb b.rb])
    end

    it "forwards the diff's own facts on a file row, unchanged and unrenamed" do
      row = open_session.marked.files.first

      expect([row.status, row.binary?, row.old_path, row.new_path]).to eq([:modified, false, "a.rb", "a.rb"])
    end

    it "keeps the changeset's own base and head, which every anchor rests on" do
      marked = open_session.marked

      expect([marked.base_ref, marked.head_ref]).to eq([base_sha, head_sha])
    end

    # A Partition answers neither #hunks nor #base_ref on purpose, so a FILTERED
    # group can never reach Marks#reconcile. A row that delegated everything
    # would hand that guarantee back.
    it "does not let a partition row answer the pair Marks#reconcile reads" do
      row = open_session.marked.partitions.first

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
      row = open_session(over: binary_changeset).marked.partitions.first

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
      session.annotate(anchor_on("b.rb", 2, "Y", revision: changeset.partitions(walk).last.detail.sha),
                       "second", kind: :blocker,
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
        .to eq([["note", false, head_sha], ["blocker", true, changeset.partitions(walk).last.detail.sha]])
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
  # whose leaves are T7's ChangedFile, a Review::Partition and T2's Hunk.
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

  # What the whole card is FOR, measured where it is actually paid: a real
  # {Source::Corpus} over a real directory, a real {Survey::Chunker} dispatch,
  # and a real session presenting through it.
  #
  # Every claim here is a count of CHUNKER INVOCATIONS, taken at the chunker's
  # own `#call` -- not a flag, not a memo ivar, and not a spy on the subject.
  # "Nothing was read" is a claim about work that did not happen, and a subject
  # asked to testify about itself passes just as well when it walked the corpus
  # and threw the answer away. Measured before this card: `.open` chunked 0 of
  # 50 and `#present` chunked 50 of 50, with no mark anywhere.
  describe "presenting a corpus, which must cost only what has been read", :seam do
    # Fifty, because the number is the point: the defect this card closes was
    # invisible at two files and cost the whole tree at fifty.
    let(:corpus_size) { 50 }

    around do |example|
      Dir.mktmpdir("lain-session-corpus") { |made| @root = File.realpath(made) and example.run }
    end

    # Records every file it actually chunks, and chunks it for real -- the
    # `chunker:` seam {Source::Corpus} declares for exactly this, so the count
    # rides the production stack rather than replacing it.
    def counting_dispatch(log)
      lambda do |path|
        real = Lain::Survey::Chunker.for(path)
        lambda do |path:, source:|
          log << path
          real.call(path:, source:)
        end
      end
    end

    def corpus_session(log, drawn_on: surface)
      sensitivity = Lain::Sensitivity.new(home: "/home/surveyor", cwd: @root)
      corpus = Lain::Review::Source::Corpus.new(walk: Lain::Survey::Walk.new(root: @root, sensitivity:),
                                                projection: Lain::Survey::Projection.new(
                                                  ledger: Lain::Sensitivity::Ledger.new
                                                ),
                                                chunker: counting_dispatch(log))
      described_class.open(changeset: Lain::Review::Changeset.new(source: corpus), journal:,
                           source: "corpus", surface: drawn_on)
    end

    before do
      corpus_size.times do |n|
        File.binwrite(File.join(@root, "f#{n}.rb"), "# frozen_string_literal: true\n\ndef m#{n}\n  #{n}\nend\n")
      end
    end

    it "opens without reading a file, which is what the identity pass already bought" do
      log = []

      corpus_session(log)

      expect(log).to be_empty
    end

    it "presents without reading one either, where it used to read every one" do
      log = []
      session = corpus_session(log)

      session.present(scope: :cumulative)

      expect(log).to be_empty
    end

    it "presents every file as unreviewed all the same, which is the honest answer to an unasked question" do
      states = corpus_session([]).marked(strategy: Lain::Review::Partition::STRATEGIES.fetch(:cumulative))
                                 .files.map(&:state)

      expect(states).to eq([Lain::Review::Session::MarkedChangeset::HUNKLESS] * corpus_size)
    end

    # The card's second scenario, and the one B15's shortcut could not reach: a
    # single mark took the derivation and {Marks#states} then walked all fifty.
    it "costs one file when one file has been marked, not fifty" do
      log = []
      session = corpus_session(log)
      marked_file = session.changeset.files.first
      session.mark(Lain::Review::Hunk.keys(marked_file.hunks).first, "reviewed")

      session.present(scope: :cumulative)

      expect(log.uniq).to eq([marked_file.path])
    end

    it "shows that one file reviewed and the other forty-nine unreviewed" do
      session = corpus_session([])
      marked_file = session.changeset.files.first
      Lain::Review::Hunk.keys(marked_file.hunks).each { |key| session.mark(key, "reviewed") }

      rows = session.marked(strategy: Lain::Review::Partition::STRATEGIES.fetch(:cumulative)).files

      expect(rows.map(&:state).tally).to eq({ "reviewed" => 1, "unreviewed" => corpus_size - 1 })
    end

    # Through the surface a `lain review` actually reaches, not the null one --
    # the claim is about what a USER pays to see a survey's table, and a null
    # surface would prove only that the session did not chunk on its own.
    it "draws the whole table through a real text surface, still without reading a file" do
      log = []
      sink = StringIO.new
      session = corpus_session(log, drawn_on: Lain::Review::Surface::Text.new(sink:))

      session.present(scope: :cumulative)

      expect(log).to be_empty
      expect(sink.string.lines.size).to eq(corpus_size)
    end

    # The probe's own canary. Every count above is zero or one, and a seam that
    # measured nothing would report exactly that -- so one example drives the
    # corpus the eager way and must see all fifty.
    it "counts fifty when every file is genuinely read, so the counter is not measuring nothing" do
      log = []
      session = corpus_session(log)

      session.changeset.files.each(&:hunks)

      expect(log.uniq.size).to eq(corpus_size)
    end
  end
end
