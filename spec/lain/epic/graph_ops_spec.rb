# frozen_string_literal: true

# The operations that restructure an epic mid-flight. Every one is pure and ends
# in Graph.new, so T2's construction validation re-runs over the result for free
# -- which is what makes "refuses a cycle" and "refuses an unknown edge" true here
# without a line of new checking.
#
# The contract that carries the weight is the REWRITE: when an operation removes
# an id, every edge anywhere in the graph that named it is restated to name what
# replaced it. Forgetting the rewrite does not lose an edge quietly -- it trips
# T2's dangling-edge error, which is the wrong failure, blaming the author for a
# graph the operation malformed. Both edge kinds in EDGE_FIELDS are rewritten,
# `related` as much as `blocks`.
RSpec.describe Lain::Epic::Graph do
  def issue(id, **overrides)
    Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)
  end

  def graph(*issues)
    described_class.new(issues:)
  end

  # x blocks y blocks z -- one issue with an inbound edge, an outbound edge, and
  # a third party on each side of it.
  def chain
    graph(issue("x", blocks: %w[y]), issue("y", blocks: %w[z]), issue("z"))
  end

  def edge_ids(value)
    value.flat_map { |member| member.blocks + member.related }.uniq.sort
  end

  describe "#add" do
    it "returns a graph holding the new issue" do
      expect(graph(issue("a")).add(issue("b")).ids).to eq(%w[a b])
    end

    it "stamps the provenance it is given" do
      value = graph(issue("a")).add(issue("b"), discovered_from: "a")

      expect(value.fetch("b").discovered_from).to eq("a")
    end

    it "keeps the issue's own provenance when none is given" do
      value = graph(issue("a")).add(issue("b", discovered_from: "elsewhere"))

      expect(value.fetch("b").discovered_from).to eq("elsewhere")
    end

    # Which side wins when BOTH are set. The two examples above each pin one side
    # only, and a precedence this cheap to invert deserves a test that can tell
    # the two orderings apart.
    it "prefers the provenance it is given over the one the issue already carries" do
      value = graph(issue("a")).add(issue("b", discovered_from: "elsewhere"), discovered_from: "a")

      expect(value.fetch("b").discovered_from).to eq("a")
    end

    # T2's duplicate check, re-run for free by returning a Graph.new.
    it "refuses an id the graph already holds" do
      expect { graph(issue("a")).add(issue("a")) }
        .to raise_error(Lain::Epic::MalformedGraph, /duplicate.*"a"/m)
    end

    it "refuses an issue whose edge names an id the graph does not hold" do
      expect { graph(issue("a")).add(issue("b", blocks: %w[ghost])) }
        .to raise_error(Lain::Epic::MalformedGraph, /"ghost".*"b"/m)
    end

    # Nothing already in the graph can name an id that did not exist a moment
    # ago, so the only cycle an addition can close is its own self-edge.
    it "refuses an addition that blocks itself, as a one-hop cycle" do
      expect { graph(issue("a")).add(issue("c", blocks: %w[c])) }
        .to raise_error(Lain::Epic::MalformedGraph, /c -> c/)
    end

    it "refuses anything that is not an Epic::Issue, rather than failing three frames down" do
      expect { graph(issue("a")).add({ id: "b" }) }
        .to raise_error(Lain::Epic::MalformedGraph, /Epic::Issue.*id: "b"/m)
    end
  end

  describe "#split" do
    # AC: split preserves reachability.
    it "points every inbound blocks edge at every part" do
      value = chain.split("y", into: [issue("y1"), issue("y2")])

      expect(value.fetch("x").blocks).to eq(%w[y1 y2])
    end

    it "carries the original's outbound edges onto every part" do
      value = chain.split("y", into: [issue("y1"), issue("y2")])

      expect([value.fetch("y1").blocks, value.fetch("y2").blocks]).to eq([%w[z], %w[z]])
    end

    it "records the split id as every part's provenance" do
      value = chain.split("y", into: [issue("y1"), issue("y2")])

      expect([value.fetch("y1").discovered_from, value.fetch("y2").discovered_from]).to eq(%w[y y])
    end

    # The one place an operation overwrites authored data, and the one place the
    # three operations disagree: `add` and `merge` both let the author's declared
    # provenance stand. A part's provenance IS the split -- it did not exist
    # before it, so nothing else it could claim is true -- and that asymmetry is
    # pinned here so it reads as a decision rather than as an accident.
    it "overwrites a part's own declared provenance with the split id" do
      value = chain.split("y", into: [issue("y1", discovered_from: "elsewhere"), issue("y2")])

      expect([value.fetch("y1").discovered_from, value.fetch("y2").discovered_from]).to eq(%w[y y])
    end

    it "removes the issue it split" do
      expect(chain.split("y", into: [issue("y1"), issue("y2")]).ids).to eq(%w[x y1 y2 z])
    end

    # The correction T2's panel found: `related` is validated against known ids
    # just as `blocks` is, so a third party holding one to the split issue would
    # blow up as a dangling edge if only `blocks` were rewritten.
    it "rewrites inbound related edges too, not only blocks" do
      value = graph(issue("x", related: %w[y]), issue("y")).split("y", into: [issue("y1"), issue("y2")])

      expect(value.fetch("x").related).to eq(%w[y1 y2])
    end

    it "carries the original's related edges onto every part" do
      value = graph(issue("y", related: %w[w]), issue("w")).split("y", into: [issue("y1"), issue("y2")])

      expect([value.fetch("y1").related, value.fetch("y2").related]).to eq([%w[w], %w[w]])
    end

    it "leaves no edge anywhere naming the id it split" do
      value = graph(issue("x", blocks: %w[y], related: %w[y]), issue("y")).split("y", into: [issue("y1")])

      expect(edge_ids(value)).to eq(%w[y1])
    end

    it "keeps a part's own declared edges alongside what it inherits" do
      value = graph(issue("y", blocks: %w[z]), issue("z"), issue("w"))
              .split("y", into: [issue("y1", related: %w[w]), issue("y2")])

      expect(value.fetch("y1").related).to eq(%w[w])
    end

    # The escalation trigger's intended escape: a part that must wait on its
    # sibling says so in `into:`, and the result is a DAG rather than a dropped
    # edge.
    it "accepts a part that blocks its sibling, expressed explicitly" do
      value = chain.split("y", into: [issue("y1"), issue("y2", blocks: %w[y1])])

      expect(value.fetch("y2").blocks).to eq(%w[y1 z])
    end

    # A part naming the id being split means "the other parts": the rewrite maps
    # it to every part, and the part's own id falls out because the rewrite made
    # that self-reference, not the author.
    it "reads a part's edge to the split id as an edge to its siblings" do
      value = chain.split("y", into: [issue("y1"), issue("y2", blocks: %w[y])])

      expect(value.fetch("y2").blocks).to eq(%w[y1 z])
    end

    it "splits into a single part, which is a rename" do
      value = chain.split("y", into: [issue("why")])

      expect([value.ids, value.fetch("x").blocks]).to eq([%w[why x z], %w[why]])
    end

    it "refuses an id the graph does not hold" do
      expect { chain.split("ghost", into: [issue("y1")]) }
        .to raise_error(Lain::Epic::UnknownIssue, /"ghost"/)
    end

    # Splitting into nothing would delete the issue and silently drop every edge
    # that named it -- the quiet failure the rewrite exists to prevent.
    it "refuses splitting into no parts at all" do
      expect { chain.split("y", into: []) }
        .to raise_error(Lain::Epic::MalformedGraph, /split parts.*"y"/m)
    end

    it "refuses parts that are not an Array, naming them as split parts" do
      expect { chain.split("y", into: issue("y1")) }
        .to raise_error(Lain::Epic::MalformedGraph, /split parts must be an Array/)
    end

    it "refuses a part that is not an Epic::Issue, naming it" do
      expect { chain.split("y", into: [issue("y1"), { id: "y2" }]) }
        .to raise_error(Lain::Epic::MalformedGraph, /split parts.*id: "y2"/m)
    end

    it "refuses a part whose id collides with an issue the graph already holds" do
      expect { chain.split("y", into: [issue("x")]) }
        .to raise_error(Lain::Epic::MalformedGraph, /duplicate.*"x"/m)
    end

    it "refuses parts whose edges close a cycle, naming the path" do
      expect { chain.split("y", into: [issue("y1", blocks: %w[x]), issue("y2")]) }
        .to raise_error(Lain::Epic::MalformedGraph, /x -> y1 -> x/)
    end
  end

  describe "#merge" do
    # AC: merge drops self-edges.
    it "drops the edge between the two issues it merged" do
      value = graph(issue("a", blocks: %w[b]), issue("b", blocks: %w[w]), issue("w"))
              .merge("a", "b", as: issue("c"))

      expect(value.fetch("c").blocks).to eq(%w[w])
    end

    it "unions the edges of both, keeping everything that was not a self-reference" do
      value = graph(issue("a", blocks: %w[v], related: %w[b]), issue("b", blocks: %w[w]),
                    issue("v"), issue("w"))
              .merge("a", "b", as: issue("c"))

      expect([value.fetch("c").blocks, value.fetch("c").related]).to eq([%w[v w], []])
    end

    it "keeps the merged issue's own declared edges" do
      value = graph(issue("a"), issue("b"), issue("w")).merge("a", "b", as: issue("c", blocks: %w[w]))

      expect(value.fetch("c").blocks).to eq(%w[w])
    end

    # AC: merge rewrites third-party edges.
    it "restates every third-party edge to name the merged issue" do
      value = graph(issue("x", blocks: %w[a]), issue("a"), issue("b", blocks: %w[y]), issue("y"))
              .merge("a", "b", as: issue("c"))

      expect([value.fetch("x").blocks, value.fetch("c").blocks]).to eq([%w[c], %w[y]])
    end

    it "leaves no edge anywhere naming either merged id" do
      value = graph(issue("x", blocks: %w[a], related: %w[b]), issue("a"), issue("b"))
              .merge("a", "b", as: issue("c"))

      expect(edge_ids(value)).to eq(%w[c])
    end

    it "rewrites third-party related edges too, not only blocks" do
      value = graph(issue("x", related: %w[a b]), issue("a"), issue("b")).merge("a", "b", as: issue("c"))

      expect(value.fetch("x").related).to eq(%w[c])
    end

    it "removes both merged issues" do
      expect(graph(issue("a"), issue("b")).merge("a", "b", as: issue("c")).ids).to eq(%w[c])
    end

    it "leaves the merged issue's provenance nil unless it was given one" do
      expect(graph(issue("a"), issue("b")).merge("a", "b", as: issue("c")).fetch("c").discovered_from).to be_nil
    end

    it "keeps the provenance the merged issue declares" do
      value = graph(issue("a"), issue("b")).merge("a", "b", as: issue("c", discovered_from: "a"))

      expect(value.fetch("c").discovered_from).to eq("a")
    end

    it "merges into one of the ids it consumed" do
      value = graph(issue("x", blocks: %w[b]), issue("a", blocks: %w[b]), issue("b"))
              .merge("a", "b", as: issue("a"))

      expect([value.ids, value.fetch("a").blocks, value.fetch("x").blocks]).to eq([%w[a x], [], %w[a]])
    end

    it "refuses a first id the graph does not hold" do
      expect { chain.merge("ghost", "y", as: issue("c")) }
        .to raise_error(Lain::Epic::UnknownIssue, /"ghost"/)
    end

    it "refuses a second id the graph does not hold" do
      expect { chain.merge("y", "ghost", as: issue("c")) }
        .to raise_error(Lain::Epic::UnknownIssue, /"ghost"/)
    end

    # Merging an issue with itself is a rename wearing a merge's clothes, and
    # every edge rule below reads as a no-op -- so it is refused rather than
    # quietly obliged.
    it "refuses merging an issue with itself" do
      expect { chain.merge("y", "y", as: issue("c")) }
        .to raise_error(Lain::Epic::MalformedGraph, /itself.*"y"/m)
    end

    it "refuses a replacement that is not an Epic::Issue" do
      expect { graph(issue("a"), issue("b")).merge("a", "b", as: { id: "c" }) }
        .to raise_error(Lain::Epic::MalformedGraph, /Epic::Issue.*id: "c"/m)
    end

    it "refuses a merge that closes a cycle, naming the path" do
      expect { graph(issue("a", blocks: %w[x]), issue("b"), issue("x", blocks: %w[b])).merge("a", "b", as: issue("c")) }
        .to raise_error(Lain::Epic::MalformedGraph, /c -> x -> c/)
    end

    it "refuses a merged id that collides with a third party" do
      expect { graph(issue("a"), issue("b"), issue("x")).merge("a", "b", as: issue("x")) }
        .to raise_error(Lain::Epic::MalformedGraph, /duplicate.*"x"/m)
    end
  end

  # The three operations are one object with different arguments, and that object
  # is Graph's, not the unit's: a Revision applied to issues Graph did not fetch
  # answers for an edit the graph never agreed to, exactly as Blocking would.
  describe "the Revision seam" do
    it "is a private constant" do
      expect { Lain::Epic::Revision }.to raise_error(NameError, /private constant/)
    end

    # const_get deliberately bypasses the privacy above, as graph_spec does to
    # reach Blocking, for the same purpose: proving that a path unreachable
    # through the unit's API fails loudly rather than quietly. The three
    # operations pass only `discovered_from`, so an override naming an edge field
    # would either beat the rewrite or be beaten by it depending on splat order,
    # and neither outcome would be visible.
    it "refuses an override that names an edge field, rather than silently racing the rewrite" do
      expect { Lain::Epic.const_get(:Revision).new([], [issue("a")], blocks: %w[b]) }
        .to raise_error(Lain::Epic::MalformedGraph, /blocks/)
    end
  end

  # AC: operations are pure.
  describe "purity" do
    def operations(value)
      { "add" => -> { value.add(issue("new")) },
        "split" => -> { value.split("y", into: [issue("y1"), issue("y2")]) },
        "merge" => -> { value.merge("x", "y", as: issue("c")) } }
    end

    it "leaves the receiver's digest where it was" do
      value = chain
      before = value.digest
      operations(value).each_value(&:call)

      expect(value.digest).to eq(before)
    end

    it "leaves the receiver's issues where they were" do
      value = chain
      before = value.map(&:canonical)
      operations(value).each_value(&:call)

      expect(value.map(&:canonical)).to eq(before)
    end

    it "returns a value that is none of the others" do
      digests = operations(chain).values.map { |op| op.call.digest }

      expect(digests.uniq).to eq(digests)
    end

    it "returns a value that is not the receiver" do
      value = chain
      digests = operations(value).values.map { |op| op.call.digest }

      expect(digests).to all(satisfy { |digest| digest != value.digest })
    end

    it "returns a frozen, Ractor-shareable graph from every operation" do
      results = operations(chain).values.map(&:call)

      expect(results.map { |result| result.frozen? && Ractor.shareable?(result) }).to eq([true, true, true])
    end
  end
end
