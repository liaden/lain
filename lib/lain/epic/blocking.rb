# frozen_string_literal: true

module Lain
  module Epic
    # The `blocks` relation over a set of issues, as a DAG. Held apart from
    # {Graph} because Graph is the VALUE (identity, digest, statuses) while this
    # is the relation algebra over it, and only one of the two is
    # content-addressed.
    #
    # Built fresh per query rather than memoized on the Graph: the walk is cheap
    # at epic scale, and an ivar holding these mutable indices would cost
    # `Ractor.shareable?(graph)`, the mechanical statement that a Graph has no
    # reachable mutable state.
    #
    # Where totality stops: #cycle_path and #depth both recurse, one frame per
    # link, so a long enough `blocks` CHAIN raises SystemStackError -- not a
    # Lain::Error, so it escapes exe/lain's renderer. Measured on this build, a
    # 2000-long chain validates and a 2200-long one does not. An epic is authored
    # by a human in one markdown file, two orders of magnitude short of that, and
    # an iterative rewrite would cost the walk its readability for a case nobody
    # can reach. Said plainly because the Graph below claims construction is
    # total, and this is the asterisk on that claim.
    class Blocking
      def initialize(issues)
        @blocked = issues.to_h { |issue| [issue.id, issue.blocks] }.freeze
        @blockers = invert(@blocked)
        @depth = {}
      end

      def ids = @blocked.keys

      # The ids that must finish before +id+ may start.
      def blockers_of(id) = @blockers.fetch(id)

      # The whole relation, each id to the ids that must finish before it.
      attr_reader :blockers

      # Every id in the earliest wave its blockers permit -- the longest-path
      # layering, which is what makes each wave a MAXIMAL antichain rather than
      # the one-per-wave chain a plain topological order would emit.
      def layers
        acyclic!
        ids.group_by { |id| depth(id) }.sort.map { |_depth, wave| wave.freeze }
      end

      # Self, once the relation is known to be a DAG; otherwise the cycle, named
      # by its path so the message says which edge to cut. #layers asserts it too,
      # so the depth recursion cannot be entered on a relation that never bottoms
      # out.
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
      # starting id. Rebuilding `settled` per start turns one linear walk into one
      # walk per node: a 1600-long chain took over ten seconds to validate,
      # against milliseconds now.
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
      # membership test, so finding +id+ on it IS the cycle. Both are pushed and
      # popped in place, because copying the path at every hop makes a chain
      # quadratic. `settled` is marked on the way OUT, so an id still on the path
      # never counts as explored -- and only when `found` is empty, so a member of
      # a discovered cycle is never recorded as clean now that the set outlives
      # one start id.
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

      # Both return before the recursive descent begins, so neither costs the
      # walk any stack depth.
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

    # What holds an issue back, answered for a WHOLE graph at once. {Blocking}
    # is private, so this is the public shape of the same question -- and it is
    # a pair rather than two loose Hashes because every caller needs both and
    # they must describe the same fold.
    #
    # A {Graph} is a frozen value, so neither the relation nor its id index can
    # be memoized there: {Graph#blocked_by} rebuilds the whole relation per call
    # and {Graph#fetch} its own index, which makes asking either question once
    # per issue quadratic in the issue count. A caller walking every issue
    # builds one of these instead.
    Blockage = Data.define(:relation, :statuses) do
      # @param graph [Graph] the fold to index
      def self.of(graph) = new(relation: graph.blockers, statuses: graph.statuses)

      # Whether every id blocking +id+ has finished. An abandoned blocker still
      # blocks -- {Graph#ready}'s rule, so the two cannot disagree about stuck.
      def clear?(id) = relation.fetch(id).all? { |blocker| statuses.fetch(blocker) == DONE }

      # @return [Array<String>] the blockers of +id+ that have NOT finished
      def holding(id) = relation.fetch(id).reject { |blocker| statuses.fetch(blocker) == DONE }
    end
  end
end
