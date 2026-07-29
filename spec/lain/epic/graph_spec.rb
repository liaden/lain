# frozen_string_literal: true

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
