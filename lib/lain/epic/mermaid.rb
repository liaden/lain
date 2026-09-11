# frozen_string_literal: true

module Lain
  module Epic
    # The epic's issue graph as mermaid `flowchart` source, folded from
    # {Epic::Progress} the same way {CLI::Epic::Report} folds its text
    # projection -- both read the one public seam, {CLI::Epic#progress}, so a
    # diagram and a text report of the same epic can never disagree about which
    # issue is ready.
    #
    # A PURE function of a {Progress} value: no I/O, no clock, no random
    # ordering, so `render(progress) == render(progress)` byte for byte. That
    # purity is what makes the diagram fit for `epic.md` (GitHub renders a
    # committed fence) as much as for a live buffer that re-renders on every
    # epic event -- the epic-orchestration plan's "canonical form stays mermaid
    # source".
    #
    # == Node ids are prefixed, never the issue id verbatim
    #
    # Mermaid reserves bare words like `end`, `class` and `subgraph` as syntax,
    # and an issue author owns their id's grammar ({Epic::ID_RESERVED}) with no
    # obligation to avoid mermaid's. Prefixing every node id sidesteps the
    # collision entirely rather than special-casing the reserved list, and the
    # issue id still reaches the reader verbatim as the node's quoted LABEL.
    #
    # == The `gated` class is not rendered
    #
    # The epic-orchestration plan's classDef list names a fifth state, `gated`,
    # for an issue with a sign-off parked. {Approval::SignoffQueue::Item} keys a
    # parked artifact on `(artifact_digest, epic_slug, stage)` and carries no
    # `issue_id` -- so which issue a parked implementation gate belongs to is
    # not a field this fold can read, only a guess (the digest addresses a
    # changeset, and a changeset names no issue on its own). Guessing an
    # attribution the record does not carry is exactly the kind of silent wrong
    # answer this codebase refuses elsewhere, so `gated` is left undrawn rather
    # than inferred; every issue still classes as one of the five states below.
    module Mermaid
      # One state per stored status, plus `blocked` -- pending with an
      # unfinished blocker, derived from {Progress#ready} rather than stored
      # anywhere. Order is the emit order for `classDef`, matching the sequence
      # named in the epic-orchestration plan (done / in-flight / pending /
      # blocked / abandoned) so a diff between two diagrams is never just a
      # reshuffled legend.
      CLASS_STYLES = {
        "done" => "fill:#2e7d32,stroke:#1b4d1e,color:#ffffff",
        "in_flight" => "fill:#f9a825,stroke:#8a5a00,color:#000000",
        "pending" => "fill:#eceff1,stroke:#607d8b,color:#000000",
        "blocked" => "fill:#c62828,stroke:#7f1d1d,color:#ffffff",
        "abandoned" => "fill:#78909c,stroke:#37474f,color:#ffffff,stroke-dasharray:4 2"
      }.freeze

      # Every mermaid node id this module emits opens with this, so a graph
      # whose author picked an id shaped like mermaid's own syntax (`end`,
      # `class`, a bare number) never collides with it.
      NODE_PREFIX = "n_"

      module_function

      # @param progress [Progress] the folded epic state to draw
      # @return [String] `flowchart TD` source, newline-joined, no trailing
      #   fence -- the caller decides whether this is embedded in a ```mermaid
      #   block (`epic.md`) or a live buffer
      def render(progress) = Renderer.new(progress).to_s

      # The one-shot builder behind {Mermaid.render}. Held apart from the
      # module the way {Document::Writer} is held apart from {Document}: this
      # carries the per-render working state (the node-id assignment), and the
      # module above stays the stateless entry point and the shared vocabulary.
      class Renderer
        FLOWCHART_HEADER = "flowchart TD"

        # Mermaid's label ultimately reaches a browser DOM, so every character
        # that means something there -- not just the `"` that would close a
        # label's own quotes -- has to leave as an entity: `<`/`>` read as
        # markup (`<img src=x>` renders a live image, `<script>` an empty
        # label), and `#nnnn;` decodes as a numeric character reference (an id
        # containing one silently became a different glyph). `&` is replaced
        # FIRST and alone, so the entities the other four replacements
        # introduce are never themselves re-escaped into `&amp;amp;...`. A
        # backtick needs no entry -- {Epic::ID_RESERVED} refuses one before an
        # Issue ever constructs. `Hash` preserves insertion order, which is
        # what makes that ordering a property of the table rather than of
        # four separate call sites.
        ESCAPES = {
          "&" => "&amp;",
          "<" => "&lt;",
          ">" => "&gt;",
          '"' => "&quot;",
          "#" => "&num;"
        }.freeze

        def initialize(progress)
          @graph = progress.graph
          @ready_ids = progress.ready.to_set(&:id)
          @node_ids = assign_node_ids
        end

        def to_s = [FLOWCHART_HEADER, *nodes, *edges, *class_defs, *classes].join("\n")

        private

        # {Graph} is itself ordered by id ("equal issue sets are equal graphs
        # whatever order they were built in"), so walking it directly IS the
        # sorted walk -- a second `.sort` here would only restate a promise
        # {Graph}'s own constructor already keeps.
        def ids = @graph.map(&:id)

        def nodes = ids.map { |id| "    #{node(id)}[#{label(id)}]" }

        def label(id) = "\"#{escape(id)}\""

        def escape(text) = ESCAPES.reduce(text.to_s) { |escaped, (raw, entity)| escaped.gsub(raw, entity) }

        def edges = [*blocks_edges, *related_edges, *discovered_from_edges]

        # `blocks` is the direct relation ("this issue blocks that one"), so the
        # arrow points the same way the field reads: `a --> b` for `a.blocks`
        # naming `b`. {Issue#blocks} is already deduplicated and sorted.
        def blocks_edges
          ids.flat_map { |id| @graph.fetch(id).blocks.map { |target| "    #{node(id)} --> #{node(target)}" } }
        end

        # `related` is authored per-issue and not guaranteed symmetric, but the
        # relation it draws is undirected -- so a pair named from EITHER side
        # (or both) still draws exactly one dotted line, sorted by its own two
        # ids rather than by which issue happened to declare it.
        def related_edges
          pairs = ids.flat_map { |id| @graph.fetch(id).related.map { |target| [id, target].sort } }.uniq.sort
          pairs.map { |left, right| "    #{node(left)} -.- #{node(right)}" }
        end

        # `discovered_from` is provenance, one hop, and -- per {Epic::Lineage}
        # -- only ever resolvable while its target is still a LIVE issue: a
        # split removes the id its parts grew out of, so most of these point
        # past the edge of what this graph holds and drawing them would name a
        # node the diagram never declares. Live ones draw parent-to-child, the
        # direction lineage reads in.
        def discovered_from_edges
          ids.filter_map do |id|
            parent = @graph.fetch(id).discovered_from
            "    #{node(parent)} -.-> #{node(id)}" if parent && ids.include?(parent)
          end
        end

        def class_defs = Mermaid::CLASS_STYLES.map { |state, style| "    classDef #{state} #{style}" }

        def classes = ids.map { |id| "    class #{node(id)} #{state_of(id)}" }

        # Every stored status classes as itself except `pending`, which splits
        # on {Progress#ready} into the two states an author actually acts on:
        # nothing to do yet (`blocked`) versus free to start (`pending`).
        def state_of(id)
          issue = @graph.fetch(id)
          return issue.status unless issue.status == "pending"

          @ready_ids.include?(id) ? "pending" : "blocked"
        end

        def node(id) = @node_ids.fetch(id)

        # Sanitized independently per id and then claimed against the set of
        # ids ALREADY HANDED OUT -- not merely against other ids sharing this
        # one's sanitized base. A per-base counter alone is not injective: `"a
        # b"` and `"a.b"` both sanitize to `a_b` and correctly split into
        # `n_a_b`/`n_a_b_2`, but an id spelled `"a_b_2"` sanitizes to exactly
        # that second candidate's own literal text, and a counter that only
        # ever asks "how many ids share MY base" has no way to know the string
        # it is about to hand out is already somebody else's. Walked in
        # sorted-id order (`ids`, from {Graph}'s own ordering) with `taken`
        # threaded through one id at a time, so which candidate an id gets is
        # a pure function of the id set -- two renders of the same graph claim
        # in the same order and land on the same ids.
        def assign_node_ids
          taken = {}
          ids.to_h { |id| [id, claim("#{NODE_PREFIX}#{sanitized(id)}", taken)] }
        end

        def sanitized(id) = id.gsub(/[^A-Za-z0-9]/, "_")

        # The first of `base`, `base_2`, `base_3`, ... not already in `taken`.
        # Bounded by `taken`'s own size -- at most that many candidates can
        # already be spoken for -- so this always terminates.
        def claim(base, taken)
          candidate = base
          suffix = 2
          while taken.key?(candidate)
            candidate = "#{base}_#{suffix}"
            suffix += 1
          end
          taken[candidate] = true
          candidate
        end
      end
      private_constant :Renderer
    end
  end
end
