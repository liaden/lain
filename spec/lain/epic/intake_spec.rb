# frozen_string_literal: true

# The intake delta: what the human did to the epic document while lain was not
# holding it. Two questions that look like one -- did the BYTES move, and did
# the MEANING move -- and the whole point of the object is that they have
# different answers. An editor that trims a line and an author who rewrites an
# acceptance criterion both change bytes; only one of them changed the epic.
#
# Everything a delta says is a report, never a verdict. `lossy?` in particular
# is a suspicion of truncation that a legitimate mass edit trips too, so its
# spec asserts that the account still names what left -- a consumer has to be
# able to ask the human rather than assert the file was cut.
#
# Totality is the other law. A human handing work back is not an error
# condition, so anything the disk can hold -- a corrupt heading, a dangling
# edge, a half-written file, bytes that are not text at all -- comes back as a
# Delta. The one exception was a defect: the encoding path raised, and the
# specs under "disk bytes that are not text" are what hold it closed.
RSpec.describe Lain::Epic::Intake do
  def issue(id, **overrides)
    Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)
  end

  def graph(*issues)
    Lain::Epic::Graph.new(issues:)
  end

  def markdown(*issues)
    Lain::Epic::Document.to_markdown(graph(*issues))
  end

  def written(*issues)
    Lain::Epic::Intake::Written.new(graph: graph(*issues))
  end

  def diff(source, disk)
    described_class.diff(written: source, disk:)
  end

  def trailing_spaces(document)
    document.lines.map { |line| line.chomp.empty? ? line : "#{line.chomp}   \n" }.join
  end

  let(:criteria_source) do
    <<~GHERKIN
      ```gherkin
      Scenario: the thing is done
        Given the thing
        Then it is done
      ```
    GHERKIN
  end

  let(:four) { %w[a b c d].map { |id| issue(id) } }
  let(:source) { written(*four) }
  let(:untouched) { markdown(*four) }
  let(:corrupt_heading) { "### [x] a heading missing its backticks\n" }

  describe "the byte comparison" do
    it "reports byte-identical when the disk holds exactly what lain wrote" do
      delta = diff(source, untouched)

      expect(delta).to be_byte_identical
      expect(delta.written_digest).to eq(delta.disk_digest)
    end

    it "carries a content address for each side" do
      delta = diff(source, markdown(*four, issue("e")))

      expect(delta.written_digest).to start_with("blake3:")
      expect(delta.disk_digest).to start_with("blake3:")
      expect(delta.written_digest).not_to eq(delta.disk_digest)
    end

    # One byte-address for file content, system-wide: a document reviewed here
    # and the same document snapshotted into the Store name the same digest.
    it "addresses the raw bytes the way every other file digest in the system does" do
      expect(source.byte_digest).to eq(Lain::Workspace::Snapshot::Blob.new(bytes: untouched).digest)
    end

    # The regression this replaces: Canonical.digest addresses the JSON ENCODING
    # of the bytes, which is injective (so equality still worked) but names an
    # address no other tool in or out of this process can reproduce.
    it "does not address the canonical encoding of the bytes" do
      expect(source.byte_digest).not_to eq(Lain::Canonical.digest(untouched))
    end

    # AC: a whitespace-only edit is byte change without structural change.
    it "sees trailing whitespace as a byte change and no structural change" do
      one = written(issue("a", description: "The first thing needs doing."))
      spaced = markdown(issue("a", description: "The first thing needs doing.")).lines.map do |line|
        line.chomp.empty? ? line : "#{line.chomp}   \n"
      end.join

      delta = diff(one, spaced)

      expect(delta).not_to be_byte_identical
      expect(delta.account).to be_empty
      expect(delta).not_to be_structural
    end

    it "sees no structural change when the whitespace is inside a criteria fence" do
      one = written(issue("a", criteria: criteria_source))

      expect(diff(one, trailing_spaces(one.bytes)).account.changes).to eq({})
    end

    it "sees no structural change when the description is a multi-line paragraph" do
      one = written(issue("a", description: "One line.\nA second line."))

      expect(diff(one, trailing_spaces(one.bytes)).account.changes).to eq({})
    end
  end

  describe "the structural account" do
    # AC: a retitle is attributed to its issue.
    it "attributes a retitle to its issue and to nothing else" do
      delta = diff(source, markdown(issue("a"), issue("b").with(title: "Rewritten"), issue("c"), issue("d")))

      expect(delta.account.retitled).to eq(%w[b])
      expect(delta.account.changes).to eq(retitled: %w[b])
      expect(delta).to be_structural
    end

    it "names an arriving issue under added" do
      delta = diff(source, markdown(*four, issue("e")))

      expect(delta.account.changes).to eq(added: %w[e])
    end

    it "names a departing issue under removed" do
      delta = diff(source, markdown(issue("a"), issue("b"), issue("c")))

      expect(delta.account.changes).to eq(removed: %w[d])
    end

    it "separates a rewritten description from a retitle" do
      delta = diff(written(issue("a", description: "One.")), markdown(issue("a", description: "Two.")))

      expect(delta.account.changes).to eq(redescribed: %w[a])
    end

    it "reads a changed status mark as a status change" do
      delta = diff(source, markdown(issue("a"), issue("b", status: "done"), issue("c"), issue("d")))

      expect(delta.account.changes).to eq(status_changed: %w[b])
    end

    it "reads a rewritten criteria fence as a criteria change" do
      before = criteria_source
      after = criteria_source.sub("the thing is done", "the other thing is done")

      delta = diff(written(issue("a", criteria: before)), markdown(issue("a", criteria: after)))

      expect(delta.account.changes).to eq(criteria_changed: %w[a])
    end

    it "reads a redirected blocks edge as an edge change" do
      delta = diff(written(issue("a", blocks: %w[b]), issue("b"), issue("c")),
                   markdown(issue("a", blocks: %w[c]), issue("b"), issue("c")))

      expect(delta.account.changes).to eq(edges_changed: %w[a])
    end

    # `discovered_from` is provenance rather than a graph edge, but it is a link
    # LINE in the document the human edited, so an edit to it must land in the
    # account rather than fall between the kinds.
    it "counts a rewritten Discovered from line as an edge change" do
      delta = diff(written(issue("a"), issue("b", discovered_from: "a")),
                   markdown(issue("a"), issue("b", discovered_from: "z")))

      expect(delta.account.changes).to eq(edges_changed: %w[b])
    end

    it "reports every kind at once, each keyed by issue id" do
      delta = diff(source, markdown(issue("a").with(title: "Rewritten"), issue("b", status: "done"), issue("c"),
                                    issue("e")))

      expect(delta.account.to_h).to eq(added: %w[e], removed: %w[d], retitled: %w[a], redescribed: [],
                                       edges_changed: [], status_changed: %w[b], criteria_changed: [])
    end

    # The account is COMPLETE: added/removed cover `id`, and the five comparisons
    # plus the three link fields cover the other seven members exactly. That
    # completeness is the whole claim -- "no edit falls between the kinds" -- and
    # a new member on Issue would break it in silence, which is the failure
    # `discovered_from` was pulled into edges_changed to prevent.
    it "compares every member an Issue carries" do
      compared = %i[id] + Lain::Epic::Document::LINK_FIELDS.each_value.to_a +
                 %i[title description status criteria]

      expect(Lain::Epic::Issue.members.sort).to eq(compared.sort)
    end

    # An edge set is a set, so Issue sorts it and the order an author writes the
    # ids in is not meaning. The account has to agree with that, or every
    # cosmetic reshuffle of a link line would read as a redirected dependency.
    it "does not read a reordered link line as an edge change" do
      one = written(issue("a", blocks: %w[b c]), issue("b"), issue("c"))
      reordered = one.bytes.sub("Blocks: `b`, `c`", "Blocks: `c`, `b`")

      expect(one.bytes).to include("Blocks: `b`, `c`")
      expect(diff(one, reordered).account.changes).to eq({})
    end

    it "names one issue under every kind its edit touched" do
      one = written(issue("a", description: "One."))
      delta = diff(one, markdown(issue("a", description: "Two.").with(title: "Rewritten")))

      expect(delta.account.changes).to eq(retitled: %w[a], redescribed: %w[a])
    end

    it "names an edge edit and the removal it points at, separately" do
      delta = diff(written(issue("a", blocks: %w[b]), issue("b")), markdown(issue("a")))

      expect(delta.account.changes).to eq(removed: %w[b], edges_changed: %w[a])
    end

    it "has an empty account exactly when the two graphs share a digest" do
      one = written(issue("a", description: "One.", criteria: criteria_source), issue("b"))
      same = diff(one, markdown(issue("a", description: "One.", criteria: criteria_source), issue("b")))
      other = diff(one, markdown(issue("a", description: "Two.", criteria: criteria_source), issue("b")))

      expect(same.account).to be_empty
      expect(other.account).not_to be_empty
    end

    # A wave plan is a value an author diffs across settles, so the account may
    # not depend on the order the disk document happened to list its issues in.
    it "orders every list the same whatever order the disk lists its issues in" do
      one = written(issue("a"), issue("b"), issue("c"))
      forward = diff(one, markdown(issue("c").with(title: "X"), issue("a").with(title: "X"),
                                   issue("b").with(title: "X")))
      backward = diff(one, markdown(issue("a").with(title: "X"), issue("b").with(title: "X"),
                                    issue("c").with(title: "X")))

      expect(Lain::Canonical.dump(forward.account.to_h)).to eq(Lain::Canonical.dump(backward.account.to_h))
    end
  end

  # The identity law: a document handed back untouched is no edit at all, over
  # every field an Issue carries and every status it may hold.
  describe "a document handed back untouched" do
    let(:loaded) do
      [issue("a", description: "Prose.\n\nMore prose.", status: "in_flight", criteria: criteria_source,
                  blocks: %w[b], related: %w[c]),
       issue("b", status: "done", discovered_from: "a"),
       issue("c", status: "abandoned", criteria: criteria_source, related: %w[a])]
    end

    it "is byte-identical, empty, unsuspected and well-formed against its own emit" do
      one = written(*loaded)
      delta = diff(one, one.bytes)

      expect(delta).to be_byte_identical
      expect(delta.account.changes).to eq({})
      expect([delta.lossy?, delta.malformed?, delta.structural?]).to eq([false, false, false])
    end

    it "is the same value computed twice" do
      one = written(*loaded)

      expect(diff(one, one.bytes)).to eq(diff(one, one.bytes))
    end
  end

  # The threshold, as a table, because it is a rule a consumer will quote to a
  # human: LESS than half the bytes came back. Written in byte prefixes, since a
  # truncated file is exactly a byte prefix -- and whether a given prefix
  # happens to parse is deliberately irrelevant to the answer.
  describe "when the suspicion of loss fires" do
    # Padded to an EVEN byte count, or "exactly half" is not expressible.
    let(:padded) do
      one = written(issue("a", description: "x" * 100))
      one.bytes.bytesize.even? ? one : written(issue("a", description: "x" * 101))
    end
    let(:half) { padded.bytes.bytesize / 2 }

    it "fires when less than half the bytes came back" do
      expect(diff(padded, padded.bytes.byteslice(0, half - 1))).to be_lossy
    end

    it "does not fire when exactly half the bytes came back" do
      expect(diff(padded, padded.bytes.byteslice(0, half))).not_to be_lossy
    end

    it "does not fire when more than half the bytes came back" do
      expect(diff(padded, padded.bytes.byteslice(0, half + 1))).not_to be_lossy
    end

    it "fires on an empty disk" do
      expect(diff(padded, "")).to be_lossy
    end

    it "does not fire on a document handed back untouched" do
      expect(diff(padded, padded.bytes)).not_to be_lossy
    end

    it "does not fire on a document that came back longer" do
      expect(diff(padded, "#{padded.bytes}\n")).not_to be_lossy
    end

    it "cannot fire when nothing was written" do
      expect(diff(written, markdown(issue("a")))).not_to be_lossy
    end

    it "fires when three of four equal issues are cut away" do
      expect(diff(source, markdown(issue("a")))).to be_lossy
    end

    # An id rename moves no bytes to speak of, so it is no truncation -- what
    # left is `account.removed`'s business, exactly, not a suspicion's.
    it "does not fire on a wholesale id renumbering" do
      one = written(issue("a"), issue("b"), issue("c"))
      delta = diff(one, markdown(issue("1"), issue("2"), issue("3")))

      expect(delta).not_to be_lossy
      expect(delta.account.added.size).to eq(3)
    end

    it "reads a single renamed id in a four-issue epic as add plus remove, unsuspected" do
      delta = diff(source, markdown(issue("a2"), issue("b"), issue("c"), issue("d")))

      expect(delta.account.changes).to eq(added: %w[a2], removed: %w[a])
      expect(delta).not_to be_lossy
    end

    # Public, so a caller that builds its own Delta can answer the module's own
    # question rather than guess at it.
    it "answers the same measure for any two byte strings" do
      expect(described_class.lossy?("x" * 100, "x" * 49)).to be(true)
      expect(described_class.lossy?("x" * 100, "x" * 50)).to be(false)
    end
  end

  describe "the empty document" do
    it "parses to an empty graph and reads as total removal" do
      delta = diff(written(issue("a"), issue("b")), "")

      expect(delta).not_to be_malformed
      expect(delta.account.removed).to eq(%w[a b])
      expect(delta).to be_lossy
    end

    it "is byte-identical and empty when both sides are the empty epic" do
      one = written

      expect(diff(one, one.bytes).account).to be_empty
      expect(diff(one, one.bytes)).to be_byte_identical
    end
  end

  describe "the account as a value" do
    let(:account) { Lain::Epic::Intake::Account.between(graph(issue("a")), graph(issue("a"), issue("b"))) }

    it "names its changes as a Hash, which is where the iteration lives" do
      expect(account.changes).to eq(added: %w[b])
    end

    it "keeps the full seven-kind shape in to_h, for a journal record" do
      expect(account.to_h.keys).to eq(Lain::Epic::Intake::KINDS)
    end

    # The block was silently dropped while Enumerable's #to_h shadowed Data's --
    # and a per-kind summary line is exactly what a consumer reaches for.
    it "honours a block passed to to_h" do
      expect(account.to_h { |kind, ids| [kind, ids.size] })
        .to eq(added: 1, removed: 0, retitled: 0, redescribed: 0, edges_changed: 0,
               status_changed: 0, criteria_changed: 0)
    end

    # A record of seven fields, not a collection. The inherited Enumerable
    # surface answered `include?(:added)` with false on an account whose `added`
    # was non-empty, because the elements were pairs.
    it "does not pretend to be a collection of its kinds" do
      expect(account).not_to respond_to(:each)
      expect(account).not_to respond_to(:include?)
    end
  end

  describe "a file that may have been truncated" do
    # A byte truncation rather than a re-emitted smaller graph: the shape a
    # crashed editor actually leaves behind.
    def cut_after_first(document)
      document[0...document.index("### [ ] `b`")]
    end

    # AC: a truncated file reads as lossy, never as clean removals.
    it "lists the missing issues and flags the loss as a suspicion" do
      delta = diff(source, cut_after_first(untouched))

      expect(delta.account.removed).to eq(%w[b c d])
      expect(delta).to be_lossy
    end

    # Issue counts are not where this boundary is pinned -- see the byte table
    # below, which uses an even-length document so "exactly half" is exact.
    # Cutting HALF the issues out of a uniform epic lands a byte or two under
    # the threshold (the separator goes too), so a spec written in issue counts
    # would be testing separator arithmetic. One of four is a real margin.
    it "does not suspect a small deletion" do
      delta = diff(source, markdown(issue("a"), issue("b"), issue("c")))

      expect(delta.account.removed).to eq(%w[d])
      expect(delta).not_to be_lossy
    end

    # `lossy?` asks "was this file cut short?" and nothing else. What LEFT is a
    # separate question the account answers exactly, so a rewrite that keeps the
    # document's size is not a suspected truncation however many ids moved --
    # the old id-count measure called this one lossy, which was a false positive
    # over a fact `removed` already stated precisely.
    it "does not suspect a wholesale rewrite that keeps the document's size" do
      delta = diff(source, markdown(issue("w"), issue("x"), issue("y"), issue("z")))

      expect(delta).not_to be_lossy
      expect(delta.account.removed).to eq(%w[a b c d])
      expect(delta.account.added).to eq(%w[w x y z])
    end

    it "leaves an untouched document unsuspected" do
      expect(diff(source, untouched)).not_to be_lossy
    end

    it "does not suspect a loss when a full-length document is merely corrupt" do
      delta = diff(source, untouched.sub("### [ ] `b` Issue b", "### [ ] b Issue b"))

      expect(delta).to be_malformed
      expect(delta).not_to be_lossy
    end
  end

  # The property the measure exists to have, swept rather than sampled. The
  # corruption preserves byte length -- one backtick becomes an `x`, which
  # breaks the heading and nothing else -- so parse success is the ONLY variable
  # between the two runs. Under a measure that changed with the branch, 15 of 45
  # cases answered oppositely; the first row below is one of them.
  describe "the suspicion does not turn on whether the disk parsed" do
    def epic_of(count, weight)
      (1..count).map { |n| issue("i#{n}", description: "x" * weight) }
    end

    def unparseable(document)
      document.sub("`", "x")
    end

    [0, 60].product((2..5).to_a).each do |weight, count|
      (1...count).each do |gone|
        it "agrees for #{count} issues, #{gone} removed, description weight #{weight}" do
          one = written(*epic_of(count, weight))
          kept = markdown(*epic_of(count, weight).first(count - gone))
          corrupt = diff(one, unparseable(kept))

          expect(corrupt).to be_malformed
          expect(diff(one, kept)).not_to be_malformed
          expect(corrupt.lossy?).to eq(diff(one, kept).lossy?)
        end
      end
    end
  end

  describe "disk bytes that are not an epic" do
    # AC: unparseable disk bytes are a malformed delta.
    it "carries the parse error instead of raising" do
      delta = diff(source, corrupt_heading)

      expect(delta).to be_malformed
      expect(delta.error).to include("is not an issue heading")
    end

    it "names the kind of refusal, so a consumer need not match message text" do
      grammar = diff(source, corrupt_heading)
      orphaned = diff(written(issue("a", blocks: %w[b]), issue("b")), "### [ ] `a` Issue a\n\nBlocks: `b`\n")

      expect(grammar.error_kind).to eq("Lain::Epic::MalformedDocument")
      expect(orphaned.error_kind).to eq("Lain::Epic::MalformedGraph")
    end

    # A truncation that cuts the issue an edge names gets here rather than to
    # the removals: the bytes are grammatical, the graph they describe is not.
    it "reports a graph-level refusal as malformed too" do
      orphaned = <<~MARKDOWN
        ### [ ] `a` Issue a

        Blocks: `b`
      MARKDOWN

      delta = diff(written(issue("a", blocks: %w[b]), issue("b")), orphaned)

      expect(delta).to be_malformed
      expect(delta.error).to include("unknown issue")
    end

    it "still carries both byte digests, and claims no structure" do
      delta = diff(source, corrupt_heading)

      expect(delta.written_digest).to eq(source.byte_digest)
      expect(delta.disk_digest).to eq(Lain::Workspace::Snapshot::Blob.new(bytes: corrupt_heading).digest)
      expect(delta).not_to be_structural
    end

    it "is not byte-identical, since bytes lain wrote always parse" do
      expect(diff(source, corrupt_heading)).not_to be_byte_identical
    end
  end

  # The hole totality had. Home::Artifact#read is File.read, so an editor that
  # saved Latin-1 and a crashed write that left half a binary file both arrive
  # here as bytes Canonical refuses -- the exact case .diff exists to absorb,
  # and the one it used to raise on.
  describe "disk bytes that are not text" do
    let(:latin1) { "### [ ] `a` Caf\xE9\n" }

    it "returns a malformed delta rather than raising" do
      expect { diff(source, latin1) }.not_to raise_error
    end

    it "says the bytes are not text, and how many there were" do
      delta = diff(source, latin1)

      expect(delta).to be_malformed
      expect(delta.error).to include("not valid UTF-8")
      expect(delta.error).to include(latin1.bytesize.to_s)
    end

    it "still addresses those bytes, since a raw digest needs no encoding" do
      expect(diff(source, latin1).disk_digest)
        .to eq(Lain::Workspace::Snapshot::Blob.new(bytes: latin1).digest)
    end

    # Encoding is not content: the same bytes read under BINARY and under UTF-8
    # are the same file, and must address and compare identically.
    it "reads a binary-encoded copy of what lain wrote as byte-identical" do
      delta = diff(source, untouched.dup.force_encoding(Encoding::ASCII_8BIT))

      expect(delta).to be_byte_identical
      expect(delta).not_to be_malformed
      expect(delta.account).to be_empty
    end
  end

  describe "what lain wrote" do
    it "defaults its bytes to the document lain emits for that graph" do
      expect(source.bytes).to eq(untouched)
    end

    it "keeps bytes that differ cosmetically from the emit" do
      recorded = Lain::Epic::Intake::Written.new(graph: graph(*four), bytes: "#{untouched}\n")

      expect(recorded.bytes).to eq("#{untouched}\n")
      expect(recorded.byte_digest).not_to eq(source.byte_digest)
    end

    # Bytes and graph that disagree make the delta contradict itself: the disk
    # can match the bytes exactly, and so read byte_identical, while differing
    # from the graph every structural kind is measured against.
    it "refuses bytes that parse to a different epic than its graph" do
      expect { Lain::Epic::Intake::Written.new(graph: graph(issue("a")), bytes: markdown(issue("b"))) }
        .to raise_error(Lain::Epic::MalformedDocument, /different epic/)
    end

    it "refuses a graph it cannot emit, rather than failing inside Document" do
      expect { Lain::Epic::Intake::Written.new(graph: nil) }
        .to raise_error(Lain::Epic::MalformedGraph, /Epic::Graph/)
    end

    it "addresses its graph and its bytes separately" do
      expect(source.graph_digest).to eq(graph(*four).digest)
      expect(source.byte_digest).not_to eq(source.graph_digest)
    end

    # Document::Writer already refuses every graph it cannot write back, and the
    # round trip is pinned generatively in document_spec, so the disagreement
    # check can never fire on the emit -- only caller-supplied bytes can differ.
    it "does not parse its own emit" do
      allow(Lain::Epic::Document).to receive(:parse_markdown).and_call_original

      written(*four)

      expect(Lain::Epic::Document).not_to have_received(:parse_markdown)
    end

    it "builds positionally, the way every other Data in this codebase does" do
      expect(Lain::Epic::Intake::Written.new(markdown(issue("a")), graph(issue("a"))).graph)
        .to eq(graph(issue("a")))
    end
  end

  # Three of the four epic stages are prose, not a graph, so the written side of
  # a review has to be sayable without one. This is the value that says it --
  # beside Written rather than inside it, because Written's whole invariant is
  # that its bytes and its graph agree, and there is no graph here to agree with.
  describe "what lain wrote as prose" do
    let(:note) { "# Research\n\nThe interesting part is the second paragraph.\n" }

    def prose(bytes) = Lain::Epic::Intake::Prose.new(bytes:)

    it "addresses its bytes at the same address the reviewed document uses" do
      expect(prose(note).byte_digest).to eq(described_class.byte_digest(note))
    end

    # Structurally nil, the way DocWritten's is: a graph digest is a property of
    # the RESOLVED artifact, so prose has no way to acquire one. This is the nil
    # a consumer reads to learn nothing structural was compared.
    it "has no graph digest, because prose has no way to acquire one" do
      expect(prose(note).graph_digest).to be_nil
    end

    it "keeps the bytes it was handed, byte for byte" do
      expect(prose(note).bytes).to eq(note)
    end

    it "refuses a written side that is not bytes, rather than digesting something else" do
      expect { prose(nil) }.to raise_error(Lain::Epic::MalformedDocument, /bytes/)
      expect { prose(graph(issue("a"))) }.to raise_error(Lain::Epic::MalformedDocument, /bytes/)
    end

    # Prose is never parsed, here or anywhere downstream: a research note is not
    # an epic document, and reporting one as a malformed epic would be a false
    # alarm about the human's work rather than a report of it.
    it "does not parse the bytes it holds" do
      allow(Lain::Epic::Document).to receive(:parse_markdown).and_call_original

      prose(corrupt_heading).byte_digest

      expect(Lain::Epic::Document).not_to have_received(:parse_markdown)
    end

    it "builds positionally, the way every other Data in this codebase does" do
      expect(Lain::Epic::Intake::Prose.new(note).bytes).to eq(note)
    end

    it "is a deeply frozen, shareable value" do
      expect(prose(+note)).to be_deeply_frozen
    end
  end

  describe "the states a delta may not hold" do
    let(:clean) { diff(source, markdown(*four, issue("e"))) }

    # Every value in this tier is total by construction -- Graph refuses
    # duplicates, Issue refuses unrepresentable ids -- and this is the value
    # four cards branch on. An account is what the PARSE produced, so a failed
    # parse can hold none; `lossy` is measured in bytes and so survives one.
    it "refuses an account alongside a parse error" do
      account = Lain::Epic::Intake::Account.between(graph(issue("a")), graph)

      expect do
        Lain::Epic::Intake::Delta.new(written_digest: "blake3:x", disk_digest: "blake3:y", account:,
                                      lossy: true, error: "boom", error_kind: "Lain::Error")
      end.to raise_error(Lain::Epic::MalformedDelta, /nothing was compared/)
    end

    it "refuses an error without its kind" do
      expect do
        Lain::Epic::Intake::Delta.new(written_digest: "blake3:x", disk_digest: "blake3:y",
                                      account: Lain::Epic::Intake::Account.empty, lossy: false,
                                      error: "boom", error_kind: nil)
      end.to raise_error(Lain::Epic::MalformedDelta)
    end

    it "refuses the same states through Data#with" do
      expect { clean.with(error: "boom", error_kind: "Lain::Error") }
        .to raise_error(Lain::Epic::MalformedDelta)
    end

    # Every member is checked, not just the two the invariant above names:
    # Data#with reaches all six, and a nil digest made #byte_identical? answer
    # TRUE (nil == nil) while a nil account answered NoMethodError instead of a
    # refusal -- the door the guard exists to close, left open three times.
    it "refuses a digest that is not a String" do
      expect { clean.with(written_digest: nil) }.to raise_error(Lain::Epic::MalformedDelta, /digest/)
    end

    it "refuses an account that is not an Account" do
      expect { clean.with(account: nil) }.to raise_error(Lain::Epic::MalformedDelta, /Account/)
    end

    it "refuses a suspicion that is not a boolean" do
      expect { clean.with(lossy: "yes") }.to raise_error(Lain::Epic::MalformedDelta, /true or false/)
    end

    it "refuses an error that is not a String" do
      expect { clean.with(error: :boom, error_kind: "Lain::Error") }
        .to raise_error(Lain::Epic::MalformedDelta, /String/)
    end
  end

  # Totality, fuzzed. Every one of these is something a human, an editor, or a
  # half-finished write can put on disk, and not one of them may reach a caller
  # as an exception.
  describe "hostile disk bytes" do
    [
      "",
      "\n\n\n",
      "# An epic\n\nJust prose.\n",
      "### [ ] `a` Issue a\n### [ ] `a` Issue a\n",
      "### [?] `a` Issue a\n",
      "### [ ] `` Issue a\n",
      "### [ ] `a` Issue a\n\nBlocks: `a`\n",
      "### [ ] `a` A\n\nBlocks: `b`\n\n### [ ] `b` B\n\nBlocks: `a`\n",
      "### [ ] `a` Issue a\n\nWibble: `b`\n",
      "### [ ] `a` Issue a {abc}\n",
      "### [ ] `a` Issue a\n\n```gherkin\nnot a scenario\n```\n",
      "### [ ] `a` Issue a\n\n```gherkin\n",
      "  \t leading whitespace only\n",
      "### [ ] `a` Issue a\n" * 200,
      "\xC3\x28 not text at all\n",
      "\x00\x01\x02\x03"
    ].each_with_index do |bytes, index|
      it "answers with a delta rather than an exception for hostile input #{index}" do
        expect(diff(source, bytes)).to be_a(Lain::Epic::Intake::Delta)
      end
    end
  end

  describe "the value" do
    it "reads neither the clock nor the disk" do
      allow(File).to receive(:read).and_raise("diff read the disk")
      allow(Time).to receive(:now).and_raise("diff read the clock")

      expect(diff(source, markdown(*four, issue("e"))).account.added).to eq(%w[e])
    end

    it "shares an empty account too" do
      expect(Lain::Epic::Intake::Account.empty).to be_deeply_frozen
    end

    it "is deeply frozen, so a delta may cross a Ractor" do
      expect(diff(source, markdown(*four, issue("e")))).to be_deeply_frozen
    end

    it "is deeply frozen when malformed" do
      expect(diff(source, "### nope\n")).to be_deeply_frozen
    end

    it "is deeply frozen when the disk bytes were not text" do
      expect(diff(source, "### [ ] `a` Caf\xE9\n")).to be_deeply_frozen
    end
  end
end
