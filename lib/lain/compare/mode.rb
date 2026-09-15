# frozen_string_literal: true

module Lain
  class Compare
    # The mode a run was in, as a comparison AXIS -- the same kind of fact
    # {Capability::Guard} already refuses to cross. An `auto` run never stopped
    # for a human, so a distribution drawn across it and an `ask` run measures
    # the approval level, not the variable under study. So this refuses, exactly
    # as that guard does. A point on the axis is a scope and an approval level,
    # written `checkout/ask`; layers are not part of it.
    #
    # A mode is a TRAJECTORY, not a value: `/mode` can be switched mid-run, and
    # a scalar has no honest answer for a run that switched. Last-wins credits
    # the whole run to the point it ended in, first-wins to the point it left,
    # and either DESTROYS the path -- while "every run that ever touched `auto`"
    # is an ordinary query OVER trajectories. So `checkout/ask → checkout/auto`
    # is its own axis point, comparable only with a run that walked the same
    # path. A designed sweep FIXES its arm's mode and so records one-element
    # trajectories that compare exactly like scalars.
    #
    # A flip that moves only a layer is journaled but leaves the point where it
    # was, so consecutive duplicates collapse: the axis reports the run. ORDER is
    # recorded, never DURATION, which BOUNDS mis-attribution rather than
    # eliminating it -- weighting a point by the turns spent in it would need a
    # per-turn mode on the Timeline.
    #
    # Absence is never another point. A session that never switched carries no
    # `mode_switch` record; {UNRECORDED} is the Null Object for that and agrees
    # with EVERYTHING, because an absent claim cannot contradict one. What
    # absence must not do is go unsaid -- {Compare#report} names it in as many
    # words.
    #
    # ⚠️ This module SHADOWS the top-level {Lain::Mode} for everything lexically
    # inside `class Compare`. Root-qualify there.
    module Mode
      # The journal discriminator {Telemetry::ModeSwitch} derives from its class
      # basename. Named here because {.from_journal} matches on it.
      RECORD_TYPE = "mode_switch"

      # The two members of a point, in the order a point is written.
      AXES = [::Lain::Mode::Scope, ::Lain::Mode::Approval].freeze
      private_constant :AXES

      SEPARATOR = "/"

      # No mode was recorded for this run. Agrees with every other trajectory,
      # including another unrecorded one, through both halves of the double
      # dispatch -- so no caller anywhere writes `if mode`.
      UNRECORDED = Class.new do
        def agrees_with?(_other) = true

        def agrees_with_trajectory?(_names) = true

        def to_s = "not recorded"

        # Named, because an anonymous singleton renders as `#<#<Class:0x…>:0x…>`
        # and this value rides into a comparison report.
        def inspect = "Lain::Compare::Mode::UNRECORDED"
      end.new.freeze

      # One run's path through the modes, in the order it walked it.
      Recorded = Data.define(:names) do
        def initialize(names:)
          super(names: names.map { |name| Mode.point(name) }.chunk_while { |a, b| a == b }.map(&:first).freeze)
        end

        def to_s = names.join(" → ")

        # Double dispatch, so neither arm branches on which arm it holds and
        # agreement stays symmetric.
        def agrees_with?(other) = other.agrees_with_trajectory?(names)

        def agrees_with_trajectory?(other_names) = names == other_names
      end

      # @param name [String, Mode] a point written `scope/approval`, or a Mode
      # @return [String] the point, interned, each half checked against its roster
      # @raise [ArgumentError] on a point that is not written as one, or names a
      #   scope or level that is not declared
      def self.point(name)
        return point([name.scope.name, name.approval.name].join(SEPARATOR)) if name.is_a?(::Lain::Mode)

        -AXES.zip(halves(name)).map { |axis, half| axis.for(half).name }.join(SEPARATOR)
      end

      def self.halves(name)
        halves = name.respond_to?(:to_str) ? name.to_str.split(SEPARATOR, -1) : []
        return halves if halves.size == AXES.size

        raise ArgumentError, "unknown mode #{name.inspect}, expected scope#{SEPARATOR}approval " \
                             "from #{AXES.map { |axis| axis::NAMES.inspect }.join(" and ")}"
      end
      private_class_method :halves

      # @param names [Array<String, Mode, Array>] the points the run was in, in
      #   order; one for a run that never switched
      # @return [Mode] a {Recorded} trajectory, or {UNRECORDED} for NO names
      #   at all -- an empty list is absence, and a `Recorded` holding none
      #   would render as the empty String and refuse against every point.
      # @raise [ArgumentError] on a name that is not a declared point
      def self.for(*names)
        named = names.flatten
        named.empty? ? UNRECORDED : Recorded.new(names: named)
      end

      # The coercion boundary {Compare::Run} hands its `mode:` to, so a
      # caller may name the mode however it holds it.
      #
      # @param value [nil, Mode, Lain::Mode, String, Array]
      # @return [Mode] {UNRECORDED} for nil
      def self.coerce(value)
        return UNRECORDED if value.nil?
        return value if value.respond_to?(:agrees_with?)

        Mode.for(value)
      end

      # Where the first flip came FROM, then every flip's destination. That
      # first `from` is the only evidence a journal carries of the mode a session
      # STARTED in, which is why the walk begins there.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @return [Mode] {UNRECORDED} when no flip was recorded
      # @raise [Error] when the records do not chain, or a record lacks a side
      def self.from_journal(entries)
        flips = Journal.records(entries, type: RECORD_TYPE).to_a
        return UNRECORDED if flips.empty?

        chain!(flips)
        Mode.for(side(flips.first, "from"), flips.map { |flip| side(flip, "to") })
      end

      # One side of a flip as a point. A record missing either half is refused
      # by name, never read as a blank that happens to split.
      def self.side(flip, end_name)
        halves = %w[scope approval].map { |axis| flip["#{end_name}_#{axis}"] }
        raise Error, "a #{RECORD_TYPE} record carries no #{end_name}_scope and #{end_name}_approval" if
          halves.any?(&:nil?)

        halves.join(SEPARATOR)
      end
      private_class_method :side

      # Each flip must leave the point the previous flip arrived at. A chain
      # that says otherwise is a damaged line or two sessions' records
      # interleaved on one fd -- ordinary under fan-out. Without this the walk
      # reads only the `to`s after the first record and answers a plausible
      # trajectory that never happened: a silent wrong answer on the record.
      def self.chain!(flips)
        flips.each_cons(2) { |previous, flip| chained!(previous, flip) }
      end
      private_class_method :chain!

      def self.chained!(previous, flip)
        arrived = side(previous, "to")
        left = side(flip, "from")
        return true if left == arrived

        # Raised when a journal's `mode_switch` records do not chain -- a flip
        # away from a mode that was not in force. See {.from_journal}.
        raise Error, "mode_switch records do not chain: a run in #{arrived} cannot switch from #{left}"
      end
      private_class_method :chained!

      # @return [true] when the two runs may be compared
      # @raise [Error] when both trajectories are recorded and differ
      def self.guard!(one, other)
        return true if one.agrees_with?(other)

        # Raised when two runs ran under modes that are known to differ.
        raise Error, "cannot compare runs under different modes: #{one} vs #{other}"
      end
    end
  end
end
