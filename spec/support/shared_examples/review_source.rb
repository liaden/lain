# frozen_string_literal: true

# The changeset-source port. A source answers six messages -- #diff, #commits,
# #base_ref, #head_ref, #diff_origin and #file_at -- and every implementation
# must pass this group unchanged. {Lain::Review::Source::LocalBranch} is the first; a GitHub PR source
# is the second, and the point of writing the contract here rather than inside
# either spec is that the second one is held to it without renegotiation.
#
# == What this group deliberately does NOT say
#
# Nothing here may mention git, a working tree, a remote, a subprocess or a
# merge base. A source that fetches a pull request over HTTP and never spawns
# anything has to be able to pass this group, so every assertion below is about
# the SHAPE of the four answers and the relationships between them, never about
# how they were obtained.
#
# The merge base is where that line was hardest to draw. "base_ref is the merge
# base" is a LocalBranch statement, so what the PORT asserts is the portable
# half: that base_ref is RESOLVED to a sha rather than echoed back as the
# symbolic name the caller passed in. Resolving is the part the spike found
# matters -- an implied base shifts every old-side anchor -- while WHICH revision
# is the right one to resolve to is each implementation's business. The
# LocalBranch spec owns the merge-base assertion.
#
# Include with a Hash:
#
#   source [#call -> source]  a fresh source over a changeset of at least two
#                             commits, called once per example.
#
# The factory owes a changeset RICH enough to exercise the group, and each of
# these earned its place by being absent while a wrong implementation passed:
#
#   - at least one file whose change is ASYMMETRIC (a pure addition, +n/-0).
#     A changeset where every change replaces one line with one line reads the
#     same forwards and backwards, so a source answering the REVERSED diff
#     passes, and a source fabricating "1/1 for every file" happens to be right.
#   - at least one file touched by more than one commit, so the per-file `>=`
#     accounting is doing work rather than comparing a number to itself.
#
# Optional but checked when present: a binary file (the binary-agreement example
# skips without one) and a non-ASCII path.
#
# An empty changeset cannot exercise the contract at all -- no diff to
# shape-check, no walk to order -- so it is out of scope for this group; a source
# is free to answer one, and LocalBranch's own spec pins that it does.
#
# == Why the callable runs through #source_call
#
# Same reason as "a content-addressed store" (see store_laws.rb): the config Hash
# is built in a `describe` body, so a Proc literal there closes over the example
# GROUP, not an instance. `instance_exec` rebinds `self` to the real example, so
# the fixture helpers the factory reaches for resolve.
RSpec.shared_examples "a review changeset source" do |config|
  source = config.fetch(:source)

  define_method(:source_call) { |callable, *args| instance_exec(*args, &callable) }

  subject(:changeset_source) { source_call(source) }

  # A path pulled OUT of the raw diff carries the diff's encoding (bytes), while
  # a path the source reports is UTF-8 by contract. Comparing the two without
  # decoding fails on any non-ASCII filename even when the bytes are identical,
  # so every path extracted below is decoded first.
  def decoded(path) = path.dup.force_encoding(Encoding::UTF_8).scrub

  # `diff --git a/X b/Y` is the one per-file header a unified diff always
  # carries, and it names both sides, which the numstat cross-check needs when a
  # source reports renames.
  def diff_paths(diff)
    diff.scan(%r{^diff --git a/(.+?) b/(.+?)$}).flatten.to_set { |path| decoded(path) }
  end

  # A unified diff declares a binary file in its own text, so this is readable
  # without asking the source anything it does not already answer. An ADDED file
  # has `/dev/null` on the old side (and a deleted one on the new side), so
  # neither side can be assumed to carry a path.
  def declared_binary_paths(diff)
    diff.scan(%r{^Binary files (?:a/(.+?)|/dev/null) and (?:b/(.+?)|/dev/null) differ$})
        .flatten.compact.to_set { |path| decoded(path) }
  end

  # The paths this changeset ADDS, read out of the diff's own text: an added
  # file's old side is `/dev/null`, which is the one thing in a unified diff that
  # says "this path did not exist at the base" without asking the source
  # anything. That makes it the portable way to hold #file_at against a revision
  # it must NOT read from.
  def added_paths(diff)
    file_sections(diff).select { |section| section.include?("\n--- /dev/null\n") }
                       .map { |section| decoded(section[%r{^diff --git a/.+? b/(.+?)$}, 1]) }
  end

  # A rename reaches a numstat path as `old => new` or `pre/{old => new}/post`.
  # Both sides count as named, so a source that DETECTS renames is not failed by
  # the accounting check for doing so.
  def numstat_paths(commits)
    commits.flat_map { |commit| commit.numstat.map(&:path) }
           .flat_map { |path| rename_sides(path) }
           .to_set
  end

  # One file's slice of a unified diff, headers included.
  def file_sections(diff) = diff.split(/^(?=diff --git )/).grep(%r{^diff --git a/.+ b/.+$})

  # `+++`/`---` are the file headers, not content, so they are excluded.
  def added_removed(section)
    body = section.each_line.drop(1)
    [body.count { |line| line.start_with?("+") && !line.start_with?("+++") },
     body.count { |line| line.start_with?("-") && !line.start_with?("---") }]
  end

  # path => [added, deleted] read from the diff's own hunk bodies, split on the
  # per-file header so a `+` line is attributed to the file it belongs to.
  def diff_line_counts(diff)
    file_sections(diff).to_h do |section|
      [decoded(section[%r{^diff --git a/.+? b/(.+?)$}, 1]), added_removed(section)]
    end
  end

  def text_entries(commits) = commits.flat_map { |commit| commit.numstat.to_a }.reject(&:binary?)

  # path => [added, deleted] summed across every commit that touched it. Binary
  # entries carry no counts and are excluded; a rename contributes to BOTH of its
  # names, since over-counting is safe under a `>=` comparison.
  def walk_line_totals(commits)
    text_entries(commits).each_with_object(Hash.new { |hash, key| hash[key] = [0, 0] }) do |entry, totals|
      rename_sides(decoded(entry.path)).each { |name| totals[name] = plus(totals[name], entry) }
    end
  end

  def plus((added, deleted), entry) = [added + entry.added, deleted + entry.deleted]

  # Names the deficiency rather than reporting a bare false, because the reader
  # of this failure is an implementer of a NEW source who has no reason to know
  # why symmetry matters here.
  def thin_fixture_message(counts)
    "this factory owes a changeset containing a PURE ADDITION (+n/-0) or a pure deletion. " \
      "Every file it supplied changes symmetrically, which reads the same forwards and " \
      "backwards, so this example cannot tell a correct source from one answering the " \
      "reversed diff. Per-file counts seen: #{counts.inspect}"
  end

  def rename_sides(path)
    braced = path.match(/\A(?<pre>.*)\{(?<old>.*) => (?<new>.*)\}(?<post>.*)\z/m)
    return %i[old new].map { |side| "#{braced[:pre]}#{braced[side]}#{braced[:post]}" } if braced

    arrow = path.match(/\A(?<old>.*) => (?<new>.*)\z/m)
    arrow ? [arrow[:old], arrow[:new]] : [path]
  end

  describe "the refs it reports" do
    it "resolves base_ref to a sha rather than echoing the symbolic name it was given" do
      expect(changeset_source.base_ref).to match(/\A[0-9a-f]{40}\z/)
    end

    it "resolves head_ref to a sha rather than echoing the symbolic name it was given" do
      expect(changeset_source.head_ref).to match(/\A[0-9a-f]{40}\z/)
    end

    it "reports frozen refs, because a changeset's identity must not be edited under it" do
      expect([changeset_source.base_ref, changeset_source.head_ref]).to all(be_frozen)
    end

    it "distinguishes base from head, since a non-empty changeset spans the two" do
      expect(changeset_source.base_ref).not_to eq(changeset_source.head_ref)
    end
  end

  # The fifth message, and the reason it is a PORT message rather than one
  # source's extra: a consumer that must ask `respond_to?` before reading it is
  # a consumer branching on which implementation it holds. Nothing here says
  # WHERE the bytes came from -- that is each source's business -- only that the
  # question always has an answer, and that a source which did not fall back is
  # not carrying somebody else's words in its message.
  describe "#diff_origin" do
    it "answers the whole report, so no consumer has to ask whether it can" do
      origin = changeset_source.diff_origin

      expect(origin).to respond_to(:origin, :reason, :message, :fell_back?)
      expect([origin.origin, origin.reason]).to all(be_a(String))
      expect([origin.origin, origin.reason]).to all(satisfy { |field| !field.empty? })
    end

    it "carries no message when nothing fell back, because the message IS the refusal's words" do
      origin = changeset_source.diff_origin
      skip "this source fell back, which is the other leg" if origin.fell_back?

      expect(origin.message).to eq("")
    end
  end

  describe "#diff" do
    it "answers raw bytes, so a latin-1 hunk cannot raise on the way to the parser" do
      expect(changeset_source.diff.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "carries a per-file header and at least one hunk" do
      expect(changeset_source.diff).to match(%r{^diff --git a/.+ b/.+$})
      expect(changeset_source.diff).to match(/^@@ -\d+(,\d+)? \+\d+(,\d+)? @@/)
    end

    # A source is a read model, not a stream. An implementation that drains an
    # HTTP body or a pipe on the first call answers empty on the second, and
    # every caller downstream reads the diff more than once.
    it "answers the same bytes when asked twice" do
      expect(changeset_source.diff).to eq(changeset_source.diff)
    end
  end

  # The sixth message: one file, as one revision holds it. A diff cannot be drawn
  # from -- it carries the hunks and three lines around them, never the whole old
  # side -- so every editor rendering a changeset asks this, and the port owes an
  # answer rather than each renderer owing a repository.
  describe "#file_at" do
    it "answers nothing for a path no revision carries, rather than raising or inventing bytes" do
      expect(changeset_source.file_at(changeset_source.base_ref, "no/such/path/in/any/revision.txt")).to be_nil
    end

    # Every path a diff names exists on at least one of its two sides -- that is
    # what makes it a changed file rather than a header. A source that answered
    # nil for everything, or that read some third revision, fails here.
    it "reads every path the diff names on at least one of the two sides" do
      sides = diff_paths(changeset_source.diff).to_h do |path|
        [path, [changeset_source.file_at(changeset_source.base_ref, path),
                changeset_source.file_at(changeset_source.head_ref, path)].compact]
      end

      expect(sides).not_to be_empty
      expect(sides.reject { |_, found| found.empty? }).to eq(sides)
    end

    # THE example that says #file_at reads the revision it was GIVEN. A file the
    # changeset adds exists at the head and does not exist at the base, so a
    # source ignoring its revision argument -- reading the working tree, or the
    # head always -- passes everything above and fails this.
    it "answers an added file at the head and nothing for it at the base" do
      added = added_paths(changeset_source.diff)
      skip "the changeset under test adds no file" if added.empty?

      aggregate_failures do
        added.each do |path|
          expect(changeset_source.file_at(changeset_source.head_ref, path)).to be_a(String)
          expect(changeset_source.file_at(changeset_source.base_ref, path)).to be_nil
        end
      end
    end

    # #diff's rule, for #diff's reason: a file carries whatever bytes it carries,
    # and a latin-1 one must not raise on its way to whatever draws it.
    it "answers raw bytes" do
      path = diff_paths(changeset_source.diff).first
      bytes = changeset_source.file_at(changeset_source.head_ref, path) ||
              changeset_source.file_at(changeset_source.base_ref, path)

      expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)
    end
  end

  describe "#commits" do
    it "is non-empty" do
      expect(changeset_source.commits).not_to be_empty
    end

    it "answers the same walk when asked twice" do
      expect(changeset_source.commits.map(&:sha)).to eq(changeset_source.commits.map(&:sha))
    end

    it "is ordered oldest-first, so the last entry is the head" do
      expect(changeset_source.commits.last.sha).to eq(changeset_source.head_ref)
    end

    # The base bounds the changeset; it is not a member of it. Including it is
    # the classic off-by-one, and it re-reviews every hunk the base already
    # carried.
    it "excludes the base itself from the walk" do
      expect(changeset_source.commits.map(&:sha)).not_to include(changeset_source.base_ref)
    end

    it "reports every commit's sha resolved" do
      expect(changeset_source.commits.map(&:sha)).to all(match(/\A[0-9a-f]{40}\z/))
    end

    it "reports a single-line, non-empty subject per commit" do
      expect(changeset_source.commits.map(&:subject)).to all(match(/\A[^\n]+\z/))
    end

    it "reports a body per commit, empty when the commit has none" do
      expect(changeset_source.commits.map(&:body)).to all(be_a(String))
    end

    # Only #diff is raw bytes. A text field that inherits BINARY breaks JSON
    # generation on the way into the NDJSON Journal -- an ordinary UTF-8 subject
    # already warns, and a latin-1 one raises. A source fed by JSON gets this
    # free; one reading a subprocess has to do it on purpose, which is what makes
    # the assertion worth having in the PORT rather than in one spec.
    it "reports its text fields as UTF-8, since they are journalled as JSON" do
      fields = changeset_source.commits.flat_map do |commit|
        [commit.sha, commit.subject, commit.body, *commit.numstat.map(&:path)]
      end
      expect(fields.map(&:encoding).uniq).to eq([Encoding::UTF_8])
      expect(fields).to all(be_valid_encoding)
    end

    it "gives every commit its own numstat" do
      expect(changeset_source.commits.map(&:numstat)).to all(be_a(Enumerable))
    end

    it "reports a non-empty path per numstat entry" do
      paths = changeset_source.commits.flat_map { |commit| commit.numstat.map(&:path) }
      expect(paths).not_to be_empty
      expect(paths).to all(be_a(String))
      expect(paths).not_to include("")
    end

    # A binary file has no line counts to report, and answering 0/0 would be a
    # lie a caller cannot tell from an empty text change.
    it "reports non-negative counts for text entries and no counts for binary ones" do
      entries = changeset_source.commits.flat_map { |commit| commit.numstat.to_a }
      text, binary = entries.partition { |entry| !entry.binary? }
      aggregate_failures do
        expect(text.flat_map { |entry| [entry.added, entry.deleted] }).to all(be_a(Integer).and(be >= 0))
        expect(binary.flat_map { |entry| [entry.added, entry.deleted] }).to all(be_nil)
      end
    end
  end

  describe "the relationship between the diff and the walk" do
    # Ties the two answers to ONE changeset. A source that reports the commits of
    # one revision range and the diff of another passes every assertion above and
    # fails this one.
    it "names every file the diff touches in some commit's numstat" do
      expect(numstat_paths(changeset_source.commits)).to include(*diff_paths(changeset_source.diff))
    end

    # Without this, two wrong neighbours pass the whole group: a source answering
    # the REVERSED diff (head..base, every old-side anchor inverted), and one
    # whose numstat counts are fabricated. Neither is detectable from shape alone
    # -- both answer well-formed values -- so the two answers are held against
    # each other numerically.
    #
    # PER FILE, not in total, and that is the whole point. A global sum cannot
    # see direction: reversing a changeset whose every change is symmetric
    # (one line replaced by one) leaves both totals identical. Per file, a pure
    # addition of +5/-0 reversed becomes +0/-5 and is caught -- which is why the
    # factory owes a changeset containing one (see the header).
    #
    # `>=` rather than `==` because the squashed diff counts a line once while
    # the walk counts it in every commit that touched it, and a merge re-reports
    # what it brought in.
    it "accounts, per file, for at least as many changed lines as the diff shows" do
      totals = walk_line_totals(changeset_source.commits)
      binary = declared_binary_paths(changeset_source.diff)
      checkable = diff_line_counts(changeset_source.diff).except(*binary)

      expect(checkable).not_to be_empty
      # The example's own discriminating power is CHECKED, not assumed. Every
      # assertion below holds in both directions on a changeset whose changes are
      # all symmetric, so without an asymmetric file present this example would
      # pass a source answering the reversed diff -- silently, and with no way
      # for the next implementer to notice. A factory that owes one and does not
      # supply it is told so by name rather than left to read the header.
      asymmetric = checkable.values.any? { |plus, minus| plus.zero? ^ minus.zero? }
      expect(asymmetric).to be(true), thin_fixture_message(checkable)

      aggregate_failures do
        checkable.each do |path, (plus, minus)|
          added, deleted = totals.fetch(path, [0, 0])
          expect(added).to be >= plus
          expect(deleted).to be >= minus
        end
      end
    end

    # Shape-checking the numstat alone CANNOT catch a source that coerces a
    # binary file's counts to 0/0, because 0/0 is a legal answer for a text file
    # nothing changed in. The diff is the second witness: it names its binary
    # files outright, so the two answers can be held against each other. A probe
    # against an in-memory fake confirmed this is the one wrong neighbour the
    # rest of the group let through.
    it "agrees with the diff about which files are binary" do
      declared = declared_binary_paths(changeset_source.diff)
      skip "the changeset under test contains no binary file" if declared.empty?

      entries = changeset_source.commits
                                .flat_map { |commit| commit.numstat.to_a }
                                .select { |entry| declared.intersect?(rename_sides(entry.path).to_set) }
      expect(entries).not_to be_empty
      expect(entries.map(&:binary?)).to all(be(true))
    end
  end
end
