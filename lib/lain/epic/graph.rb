# frozen_string_literal: true

module Lain
  module Epic
    # The issue fields that name issues in THIS graph, and so must resolve.
    # `discovered_from` is deliberately absent: it is provenance, not an edge.
    # A split removes the issue its parts grew out of, and Progress folds that
    # id's transitions as inert history, so a `discovered_from` pointing outside
    # the current issue set is the designed state rather than drift.
    EDGE_FIELDS = %i[blocks related].freeze

    # One wording for "this edge names an id the graph does not hold", shared by
    # Graph's edge validation and by Blocking's inverse index -- the same failure
    # reached from two directions, and a message worth not drifting.
    DANGLING_EDGE = "unknown issue %<target>s named in the %<field>s edges of issue %<referrer>s -- " \
                    "the epic graph holds no such issue"
    private_constant :DANGLING_EDGE

    class MalformedGraph < Error; end
    class UnknownIssue < Error; end

    # One structural edit to an epic's issue set: the issues leaving, the issues
    # arriving in their place, and the edge rewrite that keeps every third party
    # naming something the graph still holds. Split, merge and add are all this
    # object with different arguments.
    #
    # The edge rewrite is the contract rather than a courtesy -- skipping it
    # leaves a third party pointing at an id the edit removed, which surfaces as
    # Graph's dangling-edge error and blames the author for a graph the operation
    # malformed.
    #
    # Nothing here validates. #apply hands its issues back to Graph.new, so
    # duplicate ids, dangling edges and cycles are refused by exactly the
    # construction that refuses them anywhere else.
    class Revision
      def initialize(removed, arriving, **overrides)
        refuse_edge_overrides!(overrides)
        @removed = removed
        @arriving = arriving
        @overrides = overrides
        @replacements = removed.to_h { |issue| [issue.id, arriving.map(&:id)] }.freeze
      end

      # What +issues+ becomes under this edit.
      def apply(issues)
        kept = issues.reject { |issue| @replacements.key?(issue.id) }
        (kept + @arriving.map { |arrival| inherit(arrival) }).map { |issue| substitute(issue) }
      end

      private

      # An override naming an edge field would race the rewrite: #rebuild splats
      # it after the computed edges, so it would win silently -- and swapping the
      # two splats would make it lose just as silently. No operation passes one,
      # so neither outcome would ever be caught. Refused as a Lain::Error for
      # Blocking's #dangling! reason: this file constructs the collaborator
      # directly, past Graph's own three operations.
      def refuse_edge_overrides!(overrides)
        clash = overrides.keys & EDGE_FIELDS
        return if clash.empty?

        raise MalformedGraph, "a revision override may not name an edge field (got #{clash.inspect}) -- " \
                              "edge sets come from the rewrite, never from an override"
      end

      # The one place the edge kinds are enumerated, so a third kind cannot be
      # forgotten at one of the two call sites below.
      def rebuild(issue, **overrides, &edges)
        issue.with(**EDGE_FIELDS.to_h { |field| [field, yield(field)] }, **overrides)
      end

      # Carrying the departing issues' edges alongside the arrival's own is what
      # preserves reachability across a split: whoever waited on the whole waits
      # on every part. Issue's constructor deduplicates and sorts each edge set,
      # so the union needs no help here.
      def inherit(arrival)
        rebuild(arrival, **@overrides) do |field|
          arrival.public_send(field) + @removed.flat_map { |issue| issue.public_send(field) }
        end
      end

      def substitute(issue)
        rebuild(issue) { |field| issue.public_send(field).flat_map { |target| replace(target, issue.id) } }
      end

      # The owner filter applies only on the replaced branch, because only there
      # did the REWRITE create the self-reference -- that is merge's "minus
      # self-references", and it is why a merged issue holds no edge to itself. A
      # self-edge the AUTHOR wrote is not in the map, passes through untouched,
      # and is refused as a one-hop cycle, which is the loud failure it deserves.
      def replace(target, owner)
        @replacements.key?(target) ? @replacements.fetch(target) - [owner] : [target]
      end
    end
    private_constant :Revision

    # An epic's issues as one deeply frozen, content-addressed value, ordered by
    # id so that equal issue sets are equal graphs whatever order they were built
    # in.
    #
    # Construction is total: duplicate ids, edges naming issues the graph does not
    # hold, and cycles in `blocks` are all refused here, which is what lets every
    # query below answer without a guard. A cycle is named by its path, so the
    # message says which edge to cut rather than that one exists.
    #
    # The queries are pure and deterministically ordered -- a wave plan is a value
    # an author diffs across runs, not a fresh shuffle each time. Pure Ruby on
    # purpose: this is per-session work over a handful of issues, so the Rust
    # binding test fails on rule 3 (hot per-turn) however graphy `#waves` looks.
    Graph = Data.define(:issues) do
      include Enumerable

      def initialize(issues: [])
        ordered = clean_issues(issues)
        refuse_duplicates!(ordered)
        refuse_dangling!(ordered)
        Blocking.new(ordered).acyclic!
        super(issues: ordered)
      end

      def each(&block) = issues.each(&block)

      def ids = issues.map(&:id).freeze

      def fetch(id)
        by_id.fetch(id) { raise UnknownIssue, "no issue #{id.inspect} in the epic graph" }
      end

      # Pending, and every blocker done. `ready` is DERIVED here rather than
      # carried on the Issue -- STORED_STATUSES refuses it by name, because a
      # status no author may write is a special case waiting to be forgotten.
      # `abandoned` is not `done`: an abandoned blocker still blocks, and
      # unblocking is an edge edit, not a status.
      def ready
        relation = Blocking.new(issues)
        finished = issues.select { |issue| issue.status == "done" }.map(&:id)
        issues.select do |issue|
          issue.status == "pending" && (relation.blockers_of(issue.id) - finished).empty?
        end.freeze
      end

      # The issues grouped into waves: each wave is a maximal set that may run
      # in parallel, and every wave's blockers are complete by the wave before.
      def waves
        index = by_id
        Blocking.new(issues).layers.map { |wave| wave.map { |id| index.fetch(id) }.freeze }.freeze
      end

      # The derived inverse of `blocks`: the ids that must finish before +id+.
      def blocked_by(id) = Blocking.new(issues).blockers_of(fetch(id).id)

      # {#blocked_by} and {#status} for EVERY id, each in one pass. This is a
      # frozen value, so neither the blocking relation nor the id index can be
      # memoized -- {#blocked_by} rebuilds the whole relation per call and
      # {#fetch} its own index, which makes asking either question once per
      # issue quadratic in the issue count. A caller walking every issue asks
      # for these two Hashes once instead.
      def blockers = Blocking.new(issues).blockers

      # @return [Hash{String=>String}] each id to its stored status
      def statuses = issues.to_h { |issue| [issue.id, issue.status] }.freeze

      # This graph plus +issue+. An addition removes nothing, so it is the
      # Revision whose rewrite is empty. The block, here and on the two
      # operations below, is offered the {GraphFiber} describing the edit.
      def add(issue, discovered_from: nil, &fiber)
        arrival = clean_issue(issue, "an added issue")
        # The fiber records the EFFECTIVE provenance, not the keyword as it
        # arrived: a replay reproduces this graph either way, and the resolved
        # value is the one a reader auditing lineage wants.
        provenance = discovered_from || arrival.discovered_from
        revise("add", { "issue" => arrival.canonical, "discovered_from" => provenance },
               [], [arrival], discovered_from: provenance, &fiber)
      end

      # +id+ replaced by +into+. Every edge anywhere that named the original comes
      # to name every part, so whoever waited on the whole of +id+ now waits on
      # all of it.
      def split(id, into:, &fiber)
        original = fetch(id)
        parts = clean_issues(into, "split parts")
        refuse_empty_split!(parts, id)
        revise("split", { "id" => original.id, "into" => parts.map(&:canonical) },
               [original], parts, discovered_from: original.id, &fiber)
      end

      # +left+ and +right+ replaced by +as+, which inherits both their edge sets on
      # top of its own. Provenance is whatever +as+ declares: a merge has two
      # parents and `discovered_from` holds one, so choosing here would be a guess
      # the lineage carries forever.
      def merge(left, right, as:, &fiber)
        refuse_self_merge!(left, right)
        arrival = clean_issue(as, "a merged issue")
        revise("merge", { "left" => left, "right" => right, "as" => arrival.canonical },
               [fetch(left), fetch(right)], [arrival], &fiber)
      end

      def digest = Canonical.digest(canonical)

      def canonical = { "issues" => issues.map(&:canonical) }

      private

      def by_id = issues.to_h { |issue| [issue.id, issue] }

      # Array-ness and member type are asserted rather than ducked. A Hash of
      # id => issue would otherwise reach `sort_by(&:id)` as a NoMethodError three
      # frames down instead of a rendered Lain::Error, and a lookalike answering
      # #canonical differently would hand back a digest that is not this epic's.
      def clean_issues(issues, what = "epic graph issues")
        unless issues.is_a?(Array)
          raise MalformedGraph,
                "#{what} must be an Array of Epic::Issue (got #{issues.inspect})"
        end

        stranger = issues.find { |issue| !issue.is_a?(Issue) }
        raise MalformedGraph, "#{what} must all be Epic::Issue (got #{stranger.inspect})" if stranger

        issues.sort_by(&:id).freeze
      end

      def clean_issue(value, what)
        raise MalformedGraph, "#{what} must be an Epic::Issue (got #{value.inspect})" unless value.is_a?(Issue)

        value
      end

      # Splitting into nothing is a deletion wearing a split's clothes: the
      # rewrite would resolve every edge naming +id+ to nothing at all and hand
      # back a graph that constructs cleanly, having quietly cut the dependencies
      # the epic is scheduled by.
      def refuse_empty_split!(parts, id)
        raise MalformedGraph, "split parts for issue #{id.inspect} cannot be empty" if parts.empty?
      end

      # Merging an issue with itself is a rename in a merge's clothes: every rule
      # merge states reads as a no-op, so it is refused rather than obliged.
      def refuse_self_merge!(left, right)
        raise MalformedGraph, "cannot merge an issue with itself (both sides name #{left.inspect})" if left == right
      end

      # The graph is what comes BACK, always -- a fiber is offered to a block and
      # never returned in the graph's place, so an operation reads the same to
      # every caller that does not care.
      #
      # Offered only when somebody is listening: the pair of content addresses is
      # real work over a revision nobody asked to audit. Built AFTER the new graph
      # exists, so a refused revision (a merge closing a cycle) yields nothing
      # rather than describing a graph that never existed.
      def revise(operation, arguments, removed, arriving, **overrides)
        revised = Graph.new(issues: Revision.new(removed, arriving, **overrides).apply(issues))
        yield GraphFiber.cut(operation:, arguments:, removed:, arriving:, from: self, to: revised) if block_given?
        revised
      end

      # An id is the graph's join key, so two issues sharing one make every
      # query silently answer for whichever was indexed last.
      def refuse_duplicates!(issues)
        repeated = issues.map(&:id).tally.select { |_id, count| count > 1 }.keys
        return if repeated.empty?

        raise MalformedGraph, "duplicate issue id(s) #{repeated.map(&:inspect).join(", ")} in the epic graph"
      end

      def refuse_dangling!(issues)
        known = issues.map(&:id)
        ghost = edges(issues).find { |_referrer, _field, target| !known.include?(target) }
        return if ghost.nil?

        referrer, field, target = ghost
        raise MalformedGraph, format(DANGLING_EDGE, target: target.inspect, field:, referrer: referrer.inspect)
      end

      def edges(issues)
        issues.flat_map do |issue|
          EDGE_FIELDS.flat_map { |field| issue.public_send(field).map { |target| [issue.id, field, target] } }
        end
      end
    end
  end
end
