# frozen_string_literal: true

require "stringio"

# The issue graph as a deeply frozen content-addressed value. Two laws carry the
# weight here. Construction is TOTAL: a graph that constructs is one every query
# can answer, so duplicates, dangling edges, and cycles are refused at the door
# rather than surfacing as a wrong answer or an infinite walk later. And every
# query is DETERMINISTIC: id order in, id order out, so a wave plan is a value an
# author can diff rather than a fresh shuffle each run.
RSpec.describe Lain::Epic::Graph do
  def issue(id, **overrides)
    Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)
  end

  def graph(*issues)
    described_class.new(issues:)
  end

  # a blocks b, a blocks c, b blocks d, c blocks d -- the shape that separates a
  # real antichain layering from a topological order that emits one issue a wave.
  def diamond
    graph(issue("a", blocks: %w[b c]), issue("b", blocks: %w[d]), issue("c", blocks: %w[d]), issue("d"))
  end

  describe "construction" do
    it "orders issues by id regardless of the order they arrive in" do
      value = graph(issue("c"), issue("a"), issue("b"))

      expect(value.map(&:id)).to eq(%w[a b c])
    end

    it "constructs empty" do
      expect(described_class.new.to_a).to eq([])
    end

    it "is deeply frozen, so a graph can cross a Ractor boundary" do
      expect(Ractor.shareable?(diamond)).to be(true)
    end

    it "refuses anything but an Array of issues, rather than failing three frames down" do
      expect { described_class.new(issues: { "a" => issue("a") }) }
        .to raise_error(Lain::Epic::MalformedGraph, /must be an Array/)
    end

    it "refuses a member that is not an Epic::Issue, naming it" do
      expect { graph(issue("a"), { id: "b" }) }
        .to raise_error(Lain::Epic::MalformedGraph, /must all be Epic::Issue.*id: "b"/m)
    end

    it "refuses duplicate ids, naming the id" do
      expect { graph(issue("a"), issue("b"), issue("a")) }
        .to raise_error(Lain::Epic::MalformedGraph, /duplicate.*"a"/m)
    end

    # AC: an edge naming an unknown id is refused.
    it "refuses a blocks edge naming an unknown id, naming both the ghost and its referrer" do
      expect { graph(issue("a", blocks: %w[ghost]), issue("b")) }
        .to raise_error(Lain::Epic::MalformedGraph, /"ghost".*"a"/m)
    end

    it "refuses a related edge naming an unknown id" do
      expect { graph(issue("a", related: %w[ghost])) }
        .to raise_error(Lain::Epic::MalformedGraph, /"ghost".*related.*"a"/m)
    end

    # discovered_from is provenance, not an edge: T3's split removes the original
    # and T10 folds transitions naming it as inert history, so an id the graph no
    # longer holds is the DESIGNED state, not drift.
    it "accepts a discovered_from naming an issue the graph no longer holds" do
      value = graph(issue("a", discovered_from: "gone"))

      expect(value.fetch("a").discovered_from).to eq("gone")
    end
  end

  describe "cycles" do
    # AC: a cycle is refused at construction naming its canonical path.
    it "refuses a cycle, naming the path rotated to the smallest id" do
      expect { graph(issue("b", blocks: %w[c]), issue("c", blocks: %w[a]), issue("a", blocks: %w[b])) }
        .to raise_error(Lain::Epic::MalformedGraph, /a -> b -> c -> a/)
    end

    it "names the same path however the issues are ordered on the way in" do
      expect { graph(issue("a", blocks: %w[b]), issue("b", blocks: %w[c]), issue("c", blocks: %w[a])) }
        .to raise_error(Lain::Epic::MalformedGraph, /a -> b -> c -> a/)
    end

    # T1 left the self-edge to this check on purpose, judging a cycle path the
    # better message.
    it "refuses an issue that blocks itself, as a one-hop cycle" do
      expect { graph(issue("a", blocks: %w[a])) }.to raise_error(Lain::Epic::MalformedGraph, /a -> a/)
    end

    it "reports the cycle rather than the acyclic issues hanging off it" do
      expect { graph(issue("root", blocks: %w[b]), issue("b", blocks: %w[c]), issue("c", blocks: %w[b])) }
        .to raise_error(Lain::Epic::MalformedGraph, /b -> c -> b/)
    end

    it "accepts a diamond, which shares nodes without looping" do
      expect { diamond }.not_to raise_error
    end
  end

  describe "#ready" do
    # AC: ready is open-and-unblocked. The open blocker is itself pending and
    # unblocked, so it is ready too -- what the AC separates is the two issues
    # UNDER those blockers, and only the done-blocked one is returned.
    it "returns only pending issues whose every blocker is done" do
      value = graph(issue("done-blocker", status: "done", blocks: %w[unblocked]),
                    issue("open-blocker", blocks: %w[still-blocked]),
                    issue("unblocked"), issue("still-blocked"))

      expect(value.ready.map(&:id)).to eq(%w[open-blocker unblocked])
    end

    it "holds an issue back while any blocker is merely in flight" do
      value = graph(issue("a", status: "in_flight", blocks: %w[b]), issue("b"))

      expect(value.ready.map(&:id)).to eq([])
    end

    it "counts an abandoned blocker as still blocking, since abandoned is not done" do
      value = graph(issue("a", status: "abandoned", blocks: %w[b]), issue("b"))

      expect(value.ready.map(&:id)).to eq([])
    end

    it "excludes issues that are not pending, whatever their blockers say" do
      value = graph(issue("in-flight", status: "in_flight"), issue("done", status: "done"),
                    issue("abandoned", status: "abandoned"), issue("pending"))

      expect(value.ready.map(&:id)).to eq(%w[pending])
    end

    it "returns issues in id order" do
      value = graph(issue("c"), issue("a"), issue("b"))

      expect(value.ready.map(&:id)).to eq(%w[a b c])
    end
  end

  describe "#waves" do
    # AC: waves are maximal antichains, not lazy singletons.
    it "puts every issue in the earliest wave its blockers allow" do
      expect(diamond.waves.map { |wave| wave.map(&:id) }).to eq([%w[a], %w[b c], %w[d]])
    end

    it "places unrelated issues together rather than in a chain" do
      value = graph(issue("a"), issue("b"), issue("c"))

      expect(value.waves.map { |wave| wave.map(&:id) }).to eq([%w[a b c]])
    end

    it "partitions the graph -- every issue appears exactly once" do
      expect(diamond.waves.flatten.map(&:id)).to eq(%w[a b c d])
    end

    it "is consistent with the blocks order -- a blocker's wave precedes its blocked" do
      waves = diamond.waves.map { |wave| wave.map(&:id) }

      expect(waves.index { |wave| wave.include?("a") }).to be < waves.index { |wave| wave.include?("d") }
    end

    it "has no waves at all when there are no issues" do
      expect(described_class.new.waves).to eq([])
    end
  end

  describe "#blocked_by" do
    it "derives the inverse of blocks, in id order" do
      expect(diamond.blocked_by("d")).to eq(%w[b c])
    end

    it "is empty for an issue nothing blocks" do
      expect(diamond.blocked_by("a")).to eq([])
    end

    it "refuses an id the graph does not hold" do
      expect { diamond.blocked_by("ghost") }.to raise_error(Lain::Epic::UnknownIssue, /"ghost"/)
    end
  end

  describe "#fetch" do
    it "returns the issue" do
      expect(diamond.fetch("b").id).to eq("b")
    end

    it "refuses an id the graph does not hold, naming it" do
      expect { diamond.fetch("ghost") }.to raise_error(Lain::Epic::UnknownIssue, /"ghost"/)
    end
  end

  describe "#digest" do
    it "does not move when the issues arrive in a different order" do
      expect(graph(issue("a"), issue("b")).digest).to eq(graph(issue("b"), issue("a")).digest)
    end

    it "moves when an issue's meaning changes" do
      expect(graph(issue("a")).digest).not_to eq(graph(issue("a", status: "done")).digest)
    end

    it "is a blake3 content address" do
      expect(diamond.digest).to start_with("blake3:")
    end
  end

  describe "Enumerable" do
    it "enumerates issues in id order" do
      expect(diamond.select { |value| value.blocks.any? }.map(&:id)).to eq(%w[a b c])
    end

    it "lists every id in graph order, frozen" do
      expect(diamond.ids).to eq(%w[a b c d]).and be_frozen
    end
  end

  # Every structural edit yields, beside the new graph, the fiber that describes
  # it. Ids and digests alone cannot re-run `split(id, into:)` -- the parts an
  # author wrote are not derivable from the graph they left -- so the fiber
  # carries the op's FULL ARGUMENTS as the replay payload, and the digest pair is
  # the oracle a replay is judged against.
  describe "revision fibers" do
    # The operation, plus every fiber it yielded. A revision nobody observes must
    # still answer a graph, so the pair is what every example below reads.
    def observed
      caught = []
      [yield(->(fiber) { caught << fiber }), caught]
    end

    # A fiber denotes ONE arrow, `before -> after`, so a replay over any other
    # graph is a question the fiber cannot answer -- and the witness for why that
    # refusal is not decoration: a merge unions the two sides' edge sets, so two
    # DIFFERENT graphs merge to the same one. Replaying this fiber over `other`
    # lands squarely on the recorded `after`, which is precisely the wrong answer
    # arriving quietly.
    let(:merge_witness) do
      cut_from = graph(issue("a", blocks: %w[x]), issue("b"), issue("x"))
      other = graph(issue("a"), issue("b", blocks: %w[x]), issue("x"))
      _, fibers = observed { |watch| cut_from.merge("a", "b", as: issue("c"), &watch) }
      [fibers.first, cut_from, other]
    end

    it "yields a split's fiber, carrying its arguments, preimage, results and digest pair" do
      before = graph(issue("x", blocks: %w[a]), issue("a"))
      parts = [issue("a1"), issue("a2")]

      after, fibers = observed { |watch| before.split("a", into: parts, &watch) }

      expect(fibers.map(&:to_h))
        .to eq([{ operation: "split", arguments: { "id" => "a", "into" => parts.map(&:canonical) },
                  preimage: %w[a], results: %w[a1 a2], before: before.digest, after: after.digest }])
    end

    it "yields an add's fiber, whose preimage is empty because an addition removes nothing" do
      before = graph(issue("a"))
      arrival = issue("found", blocks: %w[a])

      after, fibers = observed { |watch| before.add(arrival, discovered_from: "a", &watch) }

      expect(fibers.map(&:to_h))
        .to eq([{ operation: "add", arguments: { "issue" => arrival.canonical, "discovered_from" => "a" },
                  preimage: [], results: %w[found], before: before.digest, after: after.digest }])
    end

    # The keyword is optional and the arrival's own provenance stands in for it,
    # so the two readings agree on the graph and disagree on the RECORD. What is
    # journaled is the provenance the revision applied -- a replay reproduces the
    # graph either way, and an audit reading lineage off the record would
    # otherwise see an absence where the edit had an answer.
    it "records the provenance an addition resolved, not the keyword it was called with" do
      arrival = issue("found", discovered_from: "elsewhere")

      _, fibers = observed { |watch| graph(issue("a")).add(arrival, &watch) }

      expect(fibers.map { |fiber| fiber.arguments["discovered_from"] }).to eq(%w[elsewhere])
    end

    it "yields a merge's fiber, naming both sides in its preimage" do
      before = graph(issue("a"), issue("b"))
      merged = issue("c")

      after, fibers = observed { |watch| before.merge("a", "b", as: merged, &watch) }

      expect(fibers.map(&:to_h))
        .to eq([{ operation: "merge", arguments: { "left" => "a", "right" => "b", "as" => merged.canonical },
                  preimage: %w[a b], results: %w[c], before: before.digest, after: after.digest }])
    end

    # The additive-API guarantee: a fiber is something an operation OFFERS, never
    # something it returns instead of the graph. Every existing caller passes no
    # block and reads a Graph back.
    it "answers the same graph whether or not anybody is listening" do
      before = graph(issue("a"))
      watched, = observed { |watch| before.split("a", into: [issue("a1")], &watch) }

      expect(before.split("a", into: [issue("a1")])).to eq(watched)
    end

    it "yields nothing when a revision is refused, so no fiber describes a graph that never existed" do
      before = graph(issue("a", blocks: %w[x]), issue("b"), issue("x", blocks: %w[b]))

      _, fibers = observed do |watch|
        expect { before.merge("a", "b", as: issue("c"), &watch) }.to raise_error(Lain::Epic::MalformedGraph)
      end

      expect(fibers).to eq([])
    end

    it "is a deeply frozen, shareable value" do
      _, fibers = observed { |watch| graph(issue("a")).add(issue("b"), &watch) }

      expect(fibers.map { |fiber| Ractor.shareable?(fiber) }).to eq([true])
    end

    it "refuses to replay over a graph it was not cut from" do
      fiber, _cut_from, other = merge_witness

      expect { fiber.replay(other) }.to raise_error(Lain::Epic::MalformedGraph, /before/)
    end

    it "is refusing a replay that would otherwise land on the recorded after" do
      fiber, _cut_from, other = merge_witness

      expect(fiber.with(before: other.digest).replay(other).digest).to eq(fiber.after)
    end

    it "vouches for the graph it was cut from and for no other" do
      fiber, cut_from, other = merge_witness

      expect([fiber.reproduces?(cut_from), fiber.reproduces?(other)]).to eq([true, false])
    end

    # `preimage` and `results` are not decoration either: {#reproduces?} DERIVES
    # them from the replay, so a record that lies about what left or arrived
    # fails the audit rather than passing on the digests alone.
    it "refuses to vouch when the recorded preimage and results are not what the replay moved" do
      before = graph(issue("x", blocks: %w[a]), issue("a"))
      _, fibers = observed { |watch| before.split("a", into: [issue("a1"), issue("a2")], &watch) }
      tampered = fibers.first.with(preimage: [], results: %w[nonsense zzz])

      expect([fibers.first.reproduces?(before), tampered.reproduces?(before)]).to eq([true, false])
    end

    # The degenerate edits the law has to survive: an id that both LEAVES and
    # ARRIVES moves nothing in the graph, so the claim is read over the ids that
    # only left and only arrived. A split into a part bearing the departing id is
    # legal, and reproduces.
    it "vouches for a split into a part that keeps the departing id" do
      before = graph(issue("x", blocks: %w[a]), issue("a"))
      _, fibers = observed { |watch| before.split("a", into: [issue("a", title: "Rewritten")], &watch) }

      expect(fibers.map { |fiber| fiber.reproduces?(before) }).to eq([true])
    end

    it "refuses an operation nothing can replay" do
      expect do
        Lain::Epic::GraphFiber.new(operation: "rename", arguments: {}, preimage: [], results: [],
                                   before: "blake3:a", after: "blake3:b")
      end.to raise_error(Lain::Epic::MalformedGraph, %r{"rename".*add/split/merge}m)
    end

    # Ids are asserted rather than coerced, for the reason {Issue#clean_edges}
    # states: `[["nested"]].map(&:to_s)` produces an "id" no issue can ever
    # match, and quiet coercion is what this tier's constructors exist to refuse.
    it "refuses a preimage or a results list that is not issue ids", :aggregate_failures do
      expect { fiber_with(results: [%w[nested]]) }.to raise_error(Lain::Epic::MalformedGraph, /results/)
      expect { fiber_with(preimage: [""]) }.to raise_error(Lain::Epic::MalformedGraph, /preimage/)
    end

    # The argument vocabulary is declared once, beside the closed op set, so a
    # fiber carrying another operation's keys cannot construct and reach a
    # replay that fetches keys it does not hold.
    it "refuses arguments that are not the operation's own" do
      expect { fiber_with(arguments: { "issue" => {}, "discovered_from" => nil }) }
        .to raise_error(Lain::Epic::MalformedGraph, /split.*id.*into/m)
    end

    def fiber_with(**overrides)
      Lain::Epic::GraphFiber.new(operation: "split", arguments: { "id" => "a", "into" => [] },
                                 preimage: %w[a], results: %w[a1], before: "blake3:a", after: "blake3:b",
                                 **overrides)
    end
  end

  # AC: revisions replay to the recorded digest. The chain is read back out of
  # the JOURNAL -- parsed JSON, String keys, nothing held over from the
  # operations that wrote it -- because a replay reaching for an object the
  # original op kept proves the descriptor complete only by accident.
  describe "replaying a journaled chain of revisions" do
    let(:io) { StringIO.new }
    let(:scribe) { Lain::Epic::Scribe.new(epic_slug: "demo", journal: Lain::Journal.new(io:)) }
    let(:start) { graph(issue("x", blocks: %w[a]), issue("a")) }

    # A split, an addition discovered from one of its parts, and a merge of the
    # other part with what was discovered -- three ops that each remove and
    # arrive at something different.
    def revised
      one = start.split("a", into: [issue("a1"), issue("a2")]) { |fiber| scribe.graph_revised(fiber) }
      two = one.add(issue("a3", blocks: %w[a1]), discovered_from: "a1") { |fiber| scribe.graph_revised(fiber) }
      two.merge("a2", "a3", as: issue("a23")) { |fiber| scribe.graph_revised(fiber) }
    end

    def journaled = Lain::Journal.records(io.string.lines, type: "graph_revision").to_a

    it "lands on the last record's after digest, replaying from the records alone", :aggregate_failures do
      finish = revised
      records = journaled

      replayed = records.inject(start) { |value, record| Lain::Epic::GraphFiber.of(record).replay(value) }

      expect(records.size).to eq(3)
      # The chain is anchored at both ends: without this the claim is only that
      # SOME graph replays to the last `after`, not that the recorded chain
      # replays from where it says it started.
      expect(start.digest).to eq(records.first["before"])
      expect(replayed.digest).to eq(records.last["after"])
      expect(replayed).to eq(finish)
    end

    # The digest pair is only an oracle if both halves are read: a replay landing
    # on `after` from some other graph vouches for nothing.
    it "vouches for every step, each fiber reproducing the pair it recorded" do
      revised
      states = journaled.inject([start]) do |seen, record|
        seen + [Lain::Epic::GraphFiber.of(record).replay(seen.last)]
      end

      expect(journaled.zip(states).map { |record, value| Lain::Epic::GraphFiber.of(record).reproduces?(value) })
        .to eq([true, true, true])
    end

    it "refuses a record that carries no arguments to replay from, rather than replaying nothing" do
      revised

      expect { Lain::Epic::GraphFiber.of(journaled.first.except("arguments")) }
        .to raise_error(Lain::Epic::MalformedGraph, /arguments/)
    end
  end

  # A regression tripwire, not a benchmark. The cycle walk once started fresh
  # from every id -- a 1000-long chain cost ~2.4s to build and ~2.4s more to
  # wave, and n=1600 took over ten seconds each. The bound below sits two orders
  # of magnitude above what one linear walk actually costs, so it fails on the
  # quadratic shape and on nothing else. n stays well under the recursion limit
  # documented on Blocking.
  describe "scale" do
    it "walks the blocks DAG once, not once per starting id" do
      length = 1000
      chain = (0...length).map do |i|
        issue(format("i%04d", i), blocks: i + 1 < length ? [format("i%04d", i + 1)] : [])
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.new(issues: chain).waves
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 1.0
    end
  end

  # Blocking is Graph's collaborator, not the unit's API: Graph validates
  # dangling edges before building one, and nothing outside this file may
  # construct one in the wrong order.
  describe "the Blocking seam" do
    it "is a private constant" do
      expect { Lain::Epic::Blocking }.to raise_error(NameError, /private constant/)
    end

    # const_get deliberately bypasses the privacy above to reach code that is
    # unreachable by design, and prove it fails as a rendered Lain::Error rather
    # than as a bare KeyError from the inverse index.
    it "refuses a dangling edge as a MalformedGraph rather than a KeyError" do
      dangling = [Lain::Epic::Issue.new(id: "a", title: "A", blocks: %w[ghost])]

      expect { Lain::Epic.const_get(:Blocking).new(dangling) }
        .to raise_error(Lain::Epic::MalformedGraph, /"ghost".*"a"/m)
    end
  end
end
