# frozen_string_literal: true

require "delegate"

# A source with ONE of its answers replaced, and every other message forwarded
# to the real thing. It exists so the laws below can be pointed at a deliberately
# wrong source and shown to fail -- "this example has teeth" checked rather than
# claimed, which is the discipline the reversed-diff example already applies to
# its own fixture.
class ReviewSourceStandIn < SimpleDelegator
  # @param source [Object] the real source every other message reaches
  # @param files [Array] what {#files} answers instead
  def initialize(source, files:)
    super(source)
    @files = files
  end

  # @return [Array] the substituted model values
  attr_reader :files
end

# The changeset-source port. A source answers six messages -- #files, #identity,
# #base_ref, #head_ref, #file_at and #diff_origin -- and every implementation
# must pass this group unchanged. {Lain::Review::Source::LocalBranch} is the
# first; a GitHub PR source is the second, and the point of writing the contract
# here rather than inside either spec is that the second one is held to it
# without renegotiation.
#
# == This group is UNIVERSAL; "a diff-bearing review changeset source" is not
#
# A source hands the changeset MODEL VALUES -- #files, and the #identity they
# compose -- rather than bytes for somebody downstream to parse. That is what
# makes the port satisfiable by a source that has no diff at all, and it is why
# the laws split in two:
#
#   - HERE: shape, and each answer's consistency with the source's OWN other
#     answers. A source whose #files name a side its own #file_at cannot read
#     fails this group, and that is the discriminating power the split had to
#     preserve.
#   - "a diff-bearing review changeset source" (below): #diff and #commits
#     themselves, and everything that holds one against the other -- the
#     reversed-diff and binary-agreement cross-checks -- plus the sha-format
#     assertions. Those need TWO WITNESSES, and a source with only one cannot be
#     held to them; a universal group containing them could not admit one.
#
# #diff is on that side rather than this one because a source with no diff
# cannot answer it AT ALL. A law that raises `NoMethodError` is not a law about
# shape: it is the port quietly still requiring bytes, three screens under a
# sentence promising the opposite. That was the shape of this file's first cut,
# and a corpus-shaped source failed exactly those two examples and nothing else.
#
# The split is not a weakening. Every law that moved was moved because a source
# without diff bytes or a commit walk cannot satisfy it, never because it was
# inconvenient -- a port law that cannot fail is worse than a law in the right
# place.
#
# == What this group deliberately does NOT say
#
# Nothing here may mention git, a working tree, a remote, a subprocess or a
# merge base. A source that fetches a pull request over HTTP and never spawns
# anything has to be able to pass this group, so every assertion below is about
# the SHAPE of the answers and the relationships between them, never about how
# they were obtained.
#
# The merge base is where that line was hardest to draw. "base_ref is the merge
# base" is a LocalBranch statement, so what the PORT asserts is the portable
# half: that base_ref is RESOLVED to something stable rather than echoed back as
# the symbolic name the caller passed in. WHICH revision is the right one to
# resolve to is each implementation's business, and even "it is a 40-hex sha" is
# a diff source's statement rather than the port's. The LocalBranch spec owns the
# merge-base assertion.
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
# An empty changeset cannot exercise the contract at all -- no files to
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

  # A path pulled OUT of raw diff bytes carries the diff's encoding, while a path
  # a source reports is UTF-8 by contract. Comparing the two without decoding
  # fails on any non-ASCII filename even when the bytes are identical.
  def decoded(path) = path.dup.force_encoding(Encoding::UTF_8).scrub

  # The files this changeset ADDS, read off the source's own model values rather
  # than out of a diff's `/dev/null` marker: a file with no old path did not
  # exist at the base, and that is a statement any source can make. It is what
  # makes holding #file_at against a revision it must NOT read from portable.
  def added_files(source) = source.files.select { |file| file.old_path.nil? }

  # Every side every file NAMES, with what that side actually read. A file names
  # a side by carrying a path for it: an addition names only the new, a deletion
  # only the old, a rename names both under different names.
  #
  # Nothing is compacted away, and that is the fix rather than a detail. An
  # earlier form gathered both sides and dropped the nils, which collapsed "this
  # named side read nothing" into "there was no such side" -- so a source could
  # invent an old path for every added file, read nothing there, and pass. Each
  # named side is now its own row and is judged on its own.
  def named_sides(source)
    source.files.flat_map do |file|
      [[file.old_path, source.base_ref, "old"], [file.new_path, source.head_ref, "new"]]
        .select { |path, _revision, _side| path }
        .map { |path, revision, side| ["#{file.path} (#{side})", source.file_at(revision, path)] }
    end
  end

  def unreadable_sides(source) = named_sides(source).select { |_named, bytes| bytes.nil? }.map(&:first)

  # The same source, naming one file more than its own revisions carry. Pointing
  # a law at this and requiring it to FAIL is how the law's discriminating power
  # is checked rather than asserted -- without it, "every side a file names
  # reads" is satisfied by a source answering no files at all.
  def naming_a_phantom(source)
    phantom = Lain::Review::Source::ChangedFile.new(
      old_path: "no/such/path/in/any/revision.txt", new_path: "no/such/path/in/any/revision.txt", hunks: []
    )
    ReviewSourceStandIn.new(source, files: [*source.files, phantom].freeze)
  end

  # The subtler wrong neighbour, and the one the compacted form let through: a
  # source that keeps every path real but invents a SECOND side for a file that
  # has one. It is not a cosmetic lie -- an invented old side flips the file's
  # status from `added` to `renamed`, which moves the address, and every
  # old-side anchor under it then resolves to nothing.
  #
  # It is also what made the compacted form actively dangerous rather than
  # merely weak: fabricating an old side empties {#added_files}, so the
  # neighbouring "answers an added file at the head and nothing for it at the
  # base" law SKIPS. A wrong source that switches off the law which would catch
  # it is the worst shape a port contract can have.
  def fabricating_a_side(source)
    first, *rest = source.files
    invented = Lain::Review::Source::ChangedFile.new(
      old_path: "phantom/old-side.txt", new_path: first.path, hunks: first.hunks
    )
    ReviewSourceStandIn.new(source, files: [invented, *rest].freeze)
  end

  describe "the refs it reports" do
    it "reports frozen refs, because a changeset's identity must not be edited under it" do
      expect([changeset_source.base_ref, changeset_source.head_ref]).to all(be_frozen)
    end

    it "distinguishes base from head, since a non-empty changeset spans the two" do
      expect(changeset_source.base_ref).not_to eq(changeset_source.head_ref)
    end
  end

  # The port's whole point after B2: what reaches a {Lain::Review::Changeset} is
  # MODEL VALUES, so nothing downstream has to hold bytes and a parser at once.
  describe "#files" do
    it "answers the model values a changeset reads, so nothing downstream parses anything" do
      expect(changeset_source.files).not_to be_empty
      expect(changeset_source.files).to all(respond_to(:path, :old_path, :new_path, :status, :binary?, :hunks))
    end

    # A file with neither side is not a change, and a source answering one has
    # named something no revision can be asked about.
    it "gives every file at least one of the two sides" do
      expect(changeset_source.files.reject { |file| file.old_path || file.new_path }).to be_empty
    end

    # A path is journalled as JSON into the NDJSON Journal, where one line
    # `JSON.generate` refuses breaks the parse of the whole experiment record.
    it "names a non-empty, valid UTF-8 path per file" do
      paths = changeset_source.files.map(&:path)
      expect(paths).to all(be_a(String).and(be_valid_encoding))
      expect(paths.map(&:encoding).uniq).to eq([Encoding::UTF_8])
      expect(paths).not_to include("")
    end

    # {Lain::Review::Changeset#file} already documents that a colliding path
    # keeps the FIRST, "a changeset naming a path twice is a defect nobody
    # should have their gesture resolved by" -- but nothing said the source may
    # not produce one. It is not harmless: `#hunks` doubles, which pushes
    # {Lain::Review::Hunk.keys} onto its duplicate-fallback path and moves the
    # address, for a changeset that has not changed.
    it "names each path once, since a file listed twice is a file marked twice" do
      paths = changeset_source.files.map(&:path)

      expect(paths.uniq.size).to eq(paths.size)
    end

    # #diff's rule, for #diff's reason: a source is a read model, not a stream.
    # An implementation that drains something on the first call answers an empty
    # changeset on the second, and every caller reads the files more than once.
    it "answers the same files when asked twice" do
      expect(changeset_source.files.map(&:path)).to eq(changeset_source.files.map(&:path))
    end
  end

  # The identity a {Lain::Review::Session}'s address is made of -- ONE message
  # carrying both halves, because a scheme and its parts are one value and
  # `Keying.digest` would only re-join them at the call site.
  describe "#identity" do
    it "answers the scheme and the parts together, so no caller assembles an address out of two" do
      identity = changeset_source.identity

      expect(identity).to respond_to(:scheme, :parts)
      expect(identity.scheme).to be_a(String)
      expect(identity.scheme).not_to be_empty
      expect(identity.parts).to all(be_a(String))
    end

    # Deeply frozen for {Lain::Event}'s reason: this value is what an address is
    # computed from, and nothing may edit it under a session that already
    # journalled the answer.
    it "answers a shareable value, so no reachable mutable state remains under an address" do
      expect(Ractor.shareable?(changeset_source.identity)).to be(true)
    end

    it "answers the same identity when asked twice, since an address that moves is not one" do
      expect(changeset_source.identity).to eq(changeset_source.identity)
    end

    # Not a tautology: a source answering constant parts -- the shape a first
    # implementation reaches for -- passes everything above and fails this,
    # because two changesets would then share one address.
    it "composes its parts from the changeset it describes" do
      expect(changeset_source.identity.parts).to include(*changeset_source.files.map(&:path))
    end

    # The whole reason the message is on the SOURCE: `Session.digest` asks the
    # changeset, which asks its source, and nothing anywhere tests what kind of
    # source it holds.
    it "is exactly what the session addresses the changeset by, with nothing type-testing the source" do
      identity = changeset_source.identity
      changeset = Lain::Review::Changeset.new(source: changeset_source)

      expect(Lain::Review::Session.digest(changeset))
        .to eq(Lain::Review::Keying.digest(identity.scheme, identity.parts))
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

  # One file, as one revision holds it. A diff cannot be drawn
  # from -- it carries the hunks and three lines around them, never the whole old
  # side -- so every editor rendering a changeset asks this, and the port owes an
  # answer rather than each renderer owing a repository.
  describe "#file_at" do
    it "answers nothing for a path no revision carries, rather than raising or inventing bytes" do
      expect(changeset_source.file_at(changeset_source.base_ref, "no/such/path/in/any/revision.txt")).to be_nil
    end

    # THE self-consistency law, and the one that gives this group its teeth. A
    # source may say what it likes about its own changeset, but every side it
    # NAMES must read: a file carrying an old path is a file that existed at the
    # base, and one carrying a new path is a file that exists at the head. A
    # source whose #files are fabricated, or that reads some third revision,
    # fails here while passing every shape assertion above.
    #
    # STRICTLY per named side, not "at least one of the two". The weaker form is
    # what a first reading reaches for and it is a hole: see {#fabricating_a_side}.
    #
    # The law's discriminating power is CHECKED and not assumed, on both wrong
    # neighbours. Without the phantom case a source answering no files at all
    # would satisfy this vacuously, which is exactly the failure mode the port
    # split had to avoid.
    it "reads every side its own files name, at the revision that side belongs to" do
      expect(changeset_source.files).not_to be_empty
      expect(unreadable_sides(changeset_source)).to be_empty

      expect(unreadable_sides(naming_a_phantom(changeset_source)))
        .to contain_exactly("no/such/path/in/any/revision.txt (old)",
                            "no/such/path/in/any/revision.txt (new)")
      expect(unreadable_sides(fabricating_a_side(changeset_source))).not_to be_empty
    end

    # THE example that says #file_at reads the revision it was GIVEN. A file the
    # changeset adds exists at the head and does not exist at the base, so a
    # source ignoring its revision argument -- reading the working tree, or the
    # head always -- passes everything above and fails this.
    it "answers an added file at the head and nothing for it at the base" do
      added = added_files(changeset_source)
      skip "the changeset under test adds no file" if added.empty?

      aggregate_failures do
        added.each do |file|
          expect(changeset_source.file_at(changeset_source.head_ref, file.new_path)).to be_a(String)
          expect(changeset_source.file_at(changeset_source.base_ref, file.new_path)).to be_nil
        end
      end
    end

    # #diff's rule, for #diff's reason: a file carries whatever bytes it carries,
    # and a latin-1 one must not raise on its way to whatever draws it.
    it "answers raw bytes" do
      file = changeset_source.files.first
      bytes = (file.new_path && changeset_source.file_at(changeset_source.head_ref, file.new_path)) ||
              changeset_source.file_at(changeset_source.base_ref, file.old_path)

      expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)
    end
  end
end

# The half of the port that a source must HAVE A DIFF AND A WALK to satisfy.
#
# Two messages live here outright -- #diff and #commits -- because a source
# without them cannot answer at all, and every law that holds one of a source's
# answers against ANOTHER of them follows, since those are the two witnesses.
# That pairing is what catches the wrong neighbours shape alone cannot: a source
# answering the REVERSED diff, and one whose numstat counts are fabricated.
# Putting any of it in the universal group would mean no source without a diff
# could ever pass the port.
#
# The sha-format assertions are here for the milder version of the same reason:
# "base_ref is 40 hex characters" is a statement about a source with a git
# object database behind it, not about the port.
#
# Include with the SAME Hash "a review changeset source" takes -- this group runs
# it, so a diff source names one group and is held to both.
RSpec.shared_examples "a diff-bearing review changeset source" do |config|
  source = config.fetch(:source)

  define_method(:source_call) { |callable, *args| instance_exec(*args, &callable) }

  subject(:changeset_source) { source_call(source) }

  it_behaves_like "a review changeset source", config

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

  describe "the refs a git object database resolves" do
    it "resolves base_ref to a sha rather than echoing the symbolic name it was given" do
      expect(changeset_source.base_ref).to match(/\A[0-9a-f]{40}\z/)
    end

    it "resolves head_ref to a sha rather than echoing the symbolic name it was given" do
      expect(changeset_source.head_ref).to match(/\A[0-9a-f]{40}\z/)
    end
  end

  # The message itself, not only its syntax. It is here rather than in the
  # universal group because a source with no diff cannot answer it AT ALL, and a
  # port law that raises `NoMethodError` is not a law about shape -- it is the
  # port quietly still requiring bytes. `Tools::RequestReview` is the one
  # consumer in `lib/` that wants them, and it reaches a source only through
  # {Lain::Review::Source::Repository}, which builds a local branch and nothing
  # else.
  describe "#diff" do
    it "answers raw bytes, so a latin-1 hunk cannot raise on the way to the parser" do
      expect(changeset_source.diff.encoding).to eq(Encoding::ASCII_8BIT)
    end

    # A source is a read model, not a stream. An implementation that drains an
    # HTTP body or a pipe on the first call answers empty on the second, and
    # every caller downstream reads the diff more than once.
    it "answers the same bytes when asked twice" do
      expect(changeset_source.diff).to eq(changeset_source.diff)
    end

    it "carries a per-file header and at least one hunk" do
      expect(changeset_source.diff).to match(%r{^diff --git a/.+ b/.+$})
      expect(changeset_source.diff).to match(/^@@ -\d+(,\d+)? \+\d+(,\d+)? @@/)
    end
  end

  # The files a diff source parses out of its own bytes are EAGER value objects,
  # and that is a property the marked-changeset graph rests on rather than an
  # incidental one: {Lain::Review::LazyFile} answers the same messages and is
  # deliberately not deeply frozen, so which of the two a source hands down
  # decides whether a whole rendered session is shareable. Pinned here rather
  # than in `changeset_spec.rb`, because the changeset now hands down whatever
  # its source gave it and has no say in the matter.
  describe "the files it parses" do
    it "answers frozen, shareable value objects, so no reachable mutable state remains" do
      expect(changeset_source.files).to all(satisfy { |file| Ractor.shareable?(file) })
    end

    it "answers the very same objects on a second call rather than reparsing" do
      expect(changeset_source.files).to equal(changeset_source.files)
    end
  end

  # The address a diff source composes, and the property the whole review model
  # rests on: the head is NOT in it. It moves every time the author commits, and
  # surviving that is the entire purpose of {Lain::Review::Hunk}'s
  # content-addressed keys. The BASE is in it because {Lain::Review::Marks}
  # refuses to cross one at all.
  describe "#identity, over a diff" do
    it "carries the base, so a base change is genuinely a different review" do
      expect(changeset_source.identity.parts).to include(changeset_source.base_ref)
    end

    it "leaves the head out, so an amend does not open a new round" do
      expect(changeset_source.identity.parts).not_to include(changeset_source.head_ref)
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
