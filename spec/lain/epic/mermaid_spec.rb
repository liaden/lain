# frozen_string_literal: true

# {Lain::Epic::Mermaid} is a pure renderer over {Lain::Epic::Progress}: no
# journal, no home, no clock. A fixture here is therefore just a {Progress}
# built directly from a graph whose issues already carry the statuses under
# test -- `Progress.fold([], graph:, epic_slug:)` folds nothing over them, so
# the graph's own stored statuses are what the diagram reads.
RSpec.describe Lain::Epic::Mermaid do
  def issue(id, status: "pending", **overrides)
    Lain::Epic::Issue.new(id:, title: "the #{id} issue", status:, **overrides)
  end

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def progress_of(*issues, slug: "alpha")
    Lain::Epic::Progress.fold([], graph: graph_of(*issues), epic_slug: slug)
  end

  def render(*issues) = described_class.render(progress_of(*issues))

  # Scenario: the diagram is deterministic and drawn from the fold
  describe "a done blocker, its ready successor, and an issue stuck behind a pending blocker" do
    # `a` done and blocking `b`; `b` pending with its only blocker done, so it
    # is ready; `d` pending with nothing blocking IT, blocking `c`; `c` pending
    # behind `d`, so `c` is not ready.
    def fixture
      [issue("a", status: "done", blocks: %w[b]), issue("b"), issue("d", blocks: %w[c]), issue("c")]
    end

    it "renders byte-identically across two runs" do
      expect(render(*fixture)).to eq(render(*fixture))
    end

    it "classes the done blocker, its ready successor, and the blocked issue" do
      diagram = render(*fixture)

      expect(diagram).to include("class n_a done")
      expect(diagram).to include("class n_b pending")
      expect(diagram).to include("class n_c blocked")
    end

    it "draws a --> b as a blocks edge" do
      expect(render(*fixture)).to include("n_a --> n_b")
    end

    it "opens with the flowchart header" do
      expect(render(*fixture).lines.first).to eq("flowchart TD\n")
    end
  end

  # Scenario: a keyword-shaped id is safe
  describe "an issue whose id is a mermaid keyword" do
    it "prefixes the node id and keeps the label as the bare id" do
      diagram = render(issue("end"))

      expect(diagram).to include('n_end["end"]')
      # A bare `end[...]` -- unprefixed -- must never appear; only the
      # prefixed form may open a node declaration.
      expect(diagram).not_to match(/(?<!n_)\bend\[/)
    end
  end

  describe "classDef" do
    it "declares one classDef per state, in done/in_flight/pending/blocked/abandoned order" do
      diagram = render(issue("a", status: "done"), issue("b", status: "in_flight"),
                       issue("c", status: "abandoned"))

      expect(diagram.scan(/classDef (\w+)/).flatten).to eq(%w[done in_flight pending blocked abandoned])
    end

    it "classes an abandoned issue as abandoned rather than blocked" do
      diagram = render(issue("a", status: "abandoned"))

      expect(diagram).to include("class n_a abandoned")
    end
  end

  describe "related edges" do
    it "draws one dotted edge for a pair related from either side, deduplicated" do
      diagram = render(issue("a", related: %w[b]), issue("b", related: %w[a]))

      expect(diagram.scan("n_a -.- n_b").size).to eq(1)
    end
  end

  describe "discovered_from edges" do
    it "draws a dotted arrow from a live ancestor to its descendant" do
      diagram = render(issue("a"), issue("b", discovered_from: "a"))

      expect(diagram).to include("n_a -.-> n_b")
    end

    it "omits the edge when the ancestor is not live" do
      diagram = render(issue("b", discovered_from: "gone"))

      expect(diagram).not_to include("-.->")
      expect(diagram).not_to include("n_gone")
    end
  end

  describe "node ids" do
    it "are declared sorted by issue id" do
      diagram = render(issue("z"), issue("a"), issue("m"))

      declared = diagram.lines.grep(/\A\s*n_\w+\[/).map { |line| line[/n_(\w+)/, 1] }
      expect(declared).to eq(%w[a m z])
    end
  end

  # A probe found the old scheme collided: it disambiguated a sanitized BASE
  # against other
  # ids that sanitized to the SAME base, but never checked a candidate against
  # ids that landed there directly. "a b" and "a.b" both sanitize to "a_b" and
  # correctly split into `n_a_b`/`n_a_b_2` -- but "a_b_2" sanitizes to exactly
  # the SECOND candidate's own literal spelling, so it silently reused it and
  # two different issues drew as one node.
  describe "node id disambiguation" do
    it "assigns three distinct node ids to issues that collide under sanitizing AND under the suffix scheme" do
      diagram = render(issue("a b"), issue("a.b"), issue("a_b_2"))

      declared = diagram.lines.grep(/\A {4}(n_\S+)\[/) { Regexp.last_match(1) }
      expect(declared.uniq.size).to eq(3)
    end

    it "renders byte-identically across two runs, even while resolving a collision" do
      first = render(issue("a b"), issue("a.b"), issue("a_b_2"))
      second = render(issue("a b"), issue("a.b"), issue("a_b_2"))

      expect(first).to eq(second)
    end
  end

  # `escape` used to handle only `"`, the one character that could otherwise
  # close the label's own quotes. A review probe rendered the diagram through
  # a real mermaid engine (`mmdc`) and found `&`, `<`, `>` and `#` all reach
  # the SVG unescaped: `<img src=x>`/`<b>` render as live markup, `<script>`
  # produces an empty label, and `#9829;` decodes to a heart glyph -- none of
  # which is the issue id the author typed. `&` is escaped FIRST, so the
  # entities this method itself introduces are never re-escaped.
  describe "label escaping" do
    it "escapes & before anything else, so its own entities survive untouched" do
      expect(render(issue("a&b"))).to include('["a&amp;b"]')
    end

    it "escapes <, which a browser would otherwise read as markup" do
      expect(render(issue("a<b"))).to include('["a&lt;b"]')
    end

    it "escapes >, which a browser would otherwise read as markup" do
      expect(render(issue("a>b"))).to include('["a&gt;b"]')
    end

    it "escapes \", which would otherwise close the label's own quotes" do
      expect(render(issue('a"b'))).to include('["a&quot;b"]')
    end

    it "escapes #, so a numeric-entity-shaped id is not decoded by the renderer" do
      expect(render(issue("a#9829;b"))).to include('["a&num;9829;b"]')
    end
  end

  # Folded from the same review probe: hostile ids the fixtures above do not
  # already cover.
  describe "hostile ids (regression)" do
    it "keeps a --> sequence inside a label inert rather than reading as an edge" do
      diagram = render(issue("x-->y"))

      edge_lines = diagram.lines.map(&:chomp).grep(/\A {4}n_\S+ --> n_\S+\z/)
      expect(edge_lines).to be_empty
      # `>` is escaped ({#label escaping}), so the arrow survives as
      # `--&gt;` rather than the literal three-character sequence -- the
      # point pinned here is that it draws no EDGE, not that it is unescaped.
      expect(diagram).to include("x--&gt;y")
    end

    it "prefixes reserved keywords beyond end (class, subgraph, graph)" do
      %w[class subgraph graph].each do |keyword|
        diagram = render(issue(keyword))

        expect(diagram).not_to match(/(?<!n_)\b#{keyword}\[/)
        expect(diagram).to include("\"#{keyword}\"")
      end
    end
  end
end
