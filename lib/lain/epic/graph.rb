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
    # Graph's edge validation and by Blocking's inverse index -- the same
    # failure reached from two directions, and a message worth not drifting.
    DANGLING_EDGE = "unknown issue %<target>s named in the %<field>s edges of issue %<referrer>s -- " \
                    "the epic graph holds no such issue"
    private_constant :DANGLING_EDGE

    class MalformedGraph < Error; end
    class UnknownIssue < Error; end

    # The `blocks` relation over a set of issues, as a DAG: the forward map, its
    # inverse, the cycle path that would make it not a DAG, and the wave
    # layering. Held apart from {Graph} because Graph is the VALUE (identity,
    # digest, statuses) while this is the relation algebra over it, and only one
    # of the two is content-addressed.
    #
    # Built fresh per query rather than memoized on the Graph: the walk is cheap
    # at epic scale, and an ivar holding these mutable indices would cost
    # `Ractor.shareable?(graph)`, which is the mechanical statement that a Graph
    # has no reachable mutable state.
    #
    # Where totality stops: #cycle_path and #depth both recurse, one frame per
    # link, so a long enough `blocks` CHAIN raises SystemStackError -- which is
    # not a Lain::Error and so escapes exe/lain's renderer. Measured on this
    # build: a 2000-long chain validates, a 2200-long one does not. An epic is
    # authored by a human in one markdown file, so that is two orders of
    # magnitude past the shape this serves, and an iterative rewrite would cost
    # the walk its readability for a case nobody can reach. Said plainly rather
    # than left implied, because the Graph below claims construction is total
    # and this is the asterisk on that claim.
    class Blocking
      def initialize(issues)
        @blocked = issues.to_h { |issue| [issue.id, issue.blocks] }.freeze
        @blockers = invert(@blocked)
        @depth = {}
      end

      def ids = @blocked.keys

      # The ids that must finish before +id+ may start.
      def blockers_of(id) = @blockers.fetch(id)

      # Every id in the earliest wave its blockers permit -- the longest-path
      # layering, which is what makes each wave a MAXIMAL antichain rather than
      # the one-per-wave chain a plain topological order would emit.
      def layers
        acyclic!
        ids.group_by { |id| depth(id) }.sort.map { |_depth, wave| wave.freeze }
      end

      # Self, once the relation is known to be a DAG; otherwise the cycle, named
      # by its path so the message says which edge to cut. #layers asserts it
      # too, so the depth recursion cannot be entered on a relation that would
      # never bottom out.
      def acyclic!
        path = cycle_path
        raise MalformedGraph, "the blocks edges form a cycle: #{path.join(" -> ")}" unless path.empty?

        self
      end

      # The first cycle a depth-first walk finds, as a closed path
      # (`%w[a b c a]`), or an empty path when the relation is a DAG -- so no
      # caller writes a nil check.
      #
      # The three walk registers are allocated ONCE and threaded through every
      # starting id. Rebuilding `settled` per start is what turns one linear
      # walk into one walk per node: a 1600-long chain took over ten seconds to
      # validate, against milliseconds now.
      def cycle_path
        path = []
        on_path = Set.new
        settled = Set.new
        ids.inject([]) { |found, id| found.empty? ? walk(id, path, on_path, settled) : found }
      end

      private

      def invert(blocked)
        inverse = blocked.transform_values { [] }
        blocked.each do |id, targets|
          targets.each { |target| inverse.fetch(target) { dangling!(target, id) } << id }
        end
        inverse.transform_values { |ids| ids.sort.freeze }.freeze
      end

      # Graph refuses dangling edges before it ever builds a Blocking, so this
      # is unreachable through the unit's own API -- but Blocking is constructed
      # directly inside this file, and a bare KeyError from the inverse index is
      # not a Lain::Error and would escape exe/lain's renderer.
      def dangling!(target, referrer)
        raise MalformedGraph,
              format(DANGLING_EDGE, target: target.inspect, field: :blocks, referrer: referrer.inspect)
      end

      # 0 for an unblocked id, otherwise one past its deepest blocker. Memoized
      # because the diamond shape this exists to layer is exactly the shape that
      # makes the naive recursion exponential.
      def depth(id)
        @depth[id] ||= blockers_of(id).map { |blocker| depth(blocker) }.max&.succ || 0
      end

      # `path` is the route walked to reach +id+ and `on_path` is its O(1)
      # membership test, so finding +id+ on it IS the cycle; both are pushed and
      # popped in place, because copying the path at every hop makes a chain
      # quadratic. `settled` holds ids whose whole subtree came back clean and
      # is marked on the way OUT, so an id still on the path never counts as
      # explored -- and only when `found` is empty, so a member of a discovered
      # cycle is never recorded as clean now that the set outlives one start id.
      # Short-circuiting on `found.empty?` rather than `break` keeps the walk
      # one expression.
      def walk(id, path, on_path, settled)
        return rotate(path.drop(path.index(id))) if on_path.include?(id)
        return [] if settled.include?(id)

        enter(id, path, on_path)
        found = @blocked.fetch(id).inject([]) do |cycle, target|
          cycle.empty? ? walk(target, path, on_path, settled) : cycle
        end
        leave(id, path, on_path)
        settled << id if found.empty?
        found
      end

      # The path registers, pushed and popped as a named pair so the symmetry is
      # visible rather than four bare mutations in a row. Both return before the
      # recursive descent begins, so neither costs the walk any stack depth.
      def enter(id, path, on_path)
        path.push(id)
        on_path.add(id)
      end

      def leave(id, path, on_path)
        path.pop
        on_path.delete(id)
      end

      # The same cycle is discoverable from any of its members, so the raw walk
      # order would make the error message depend on which id happened to be
      # visited first. Rotating to the lexicographically smallest member makes
      # the message a function of the graph alone.
      def rotate(cycle)
        smallest = cycle.min
        (cycle.rotate(cycle.index(smallest)) << smallest).freeze
      end
    end
    # Graph's collaborator, not the unit's API. Graph validates dangling edges
    # before it builds one, and a Blocking constructed out of that order answers
    # for a relation the graph never agreed to.
    private_constant :Blocking

    # One structural edit to an epic's issue set: the issues leaving, the issues
    # arriving in their place, and the edge rewrite that keeps every third party
    # naming something the graph still holds. Split, merge, and add are all this
    # object with different arguments.
    #
    # Held apart from {Graph} for the reason {Blocking} is: Graph is the VALUE,
    # and this is an operation over it. That rewrite is the contract rather than
    # a courtesy -- skipping it leaves a third party pointing at an id the edit
    # removed, which surfaces as Graph's dangling-edge error and blames the
    # author for a graph the operation malformed.
    #
    # Nothing here validates. #apply hands its issues back to Graph.new, so
    # duplicate ids, dangling edges, and cycles are refused by exactly the
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
      # it after the computed edges, so it would win silently -- and swapping
      # those two splats would make it lose just as silently. No operation passes
      # one, so neither outcome would ever be caught. Unreachable through Graph's
      # three operations and refused as a Lain::Error anyway, for the reason
      # Blocking's #dangling! is: this file constructs the collaborator directly.
      def refuse_edge_overrides!(overrides)
        clash = overrides.keys & EDGE_FIELDS
        return if clash.empty?

        raise MalformedGraph, "a revision override may not name an edge field (got #{clash.inspect}) -- " \
                              "edge sets come from the rewrite, never from an override"
      end

      # +issue+ with every edge field rebuilt by the block, plus any overrides.
      # The one place the edge kinds are enumerated, so a third kind cannot be
      # missed by being forgotten at one of the two call sites below.
      def rebuild(issue, **overrides, &edges)
        issue.with(**EDGE_FIELDS.to_h { |field| [field, yield(field)] }, **overrides)
      end

      # An arrival carrying the departing issues' edges alongside its own, which
      # is what preserves reachability across a split: whoever waited on the
      # whole waits on every part. Issue's constructor deduplicates and sorts
      # each edge set, so the union needs no help here.
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
    # id so that equal issue sets are equal graphs whatever order they were
    # built in.
    #
    # Construction is total: duplicate ids, edges naming issues the graph does
    # not hold, and cycles in `blocks` are all refused here, which is what lets
    # every query below answer without a guard. A cycle is named by its path, so
    # the message says which edge to cut rather than that one exists.
    #
    # The queries are pure and deterministically ordered -- a wave plan is a
    # value an author diffs across runs, not a fresh shuffle each time. Pure
    # Ruby on purpose: this is per-session work over a handful of issues, so the
    # Rust binding test fails on rule 3 (hot per-turn) regardless of how graphy
    # `#waves` looks.
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

      # Pending, and every blocker done. `ready` is derived here rather than
      # carried on the Issue -- STORED_STATUSES refuses it by name,
      # because a status no author may write is a special case waiting to be
      # forgotten. Note that `abandoned` is not `done`: an abandoned blocker
      # still blocks, and unblocking is an edge edit, not a status.
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

      # This graph plus +issue+, carrying +discovered_from+ when one is named and
      # the issue's own provenance otherwise. An addition removes nothing, so it
      # is the Revision whose rewrite is empty.
      def add(issue, discovered_from: nil)
        arrival = clean_issue(issue, "an added issue")
        revise([], [arrival], discovered_from: discovered_from || arrival.discovered_from)
      end

      # +id+ replaced by +into+. Every part inherits the original's outbound
      # edges and names it as provenance, and every edge anywhere that named the
      # original comes to name every part -- so whoever waited on the whole of
      # +id+ now waits on all of it.
      def split(id, into:)
        original = fetch(id)
        parts = clean_issues(into, "split parts")
        refuse_empty_split!(parts, id)
        revise([original], parts, discovered_from: id)
      end

      # +left+ and +right+ replaced by +as+, which inherits both their edge sets
      # on top of its own. Provenance is whatever +as+ declares -- a merge has two
      # parents and `discovered_from` holds one, so choosing between them here
      # would be a guess the lineage carries forever.
      def merge(left, right, as:)
        refuse_self_merge!(left, right)
        revise([fetch(left), fetch(right)], [clean_issue(as, "a merged issue")])
      end

      def digest = Canonical.digest(canonical)

      def canonical = { "issues" => issues.map(&:canonical) }

      private

      def by_id = issues.to_h { |issue| [issue.id, issue] }

      # Array-ness and member type are asserted rather than ducked. A Hash of
      # id => issue would otherwise reach `sort_by(&:id)` as a NoMethodError
      # three frames down instead of a rendered Lain::Error, and a lookalike
      # that answers #canonical differently would hand back a digest that is not
      # this epic's -- the graph is defined over Issue values specifically.
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

      def revise(removed, arriving, **overrides)
        Graph.new(issues: Revision.new(removed, arriving, **overrides).apply(issues))
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
