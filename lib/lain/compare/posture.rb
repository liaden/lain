# frozen_string_literal: true

module Lain
  class Compare
    # The posture a run was in, as a comparison AXIS -- the same kind of fact
    # {Capability::Guard} already refuses to cross. A `plan` run never saw
    # `edit_file` in its rendered schema and an `auto` run never stopped for a
    # human, so a distribution drawn across the two measures the ladder rung,
    # not the variable under study. So this refuses, exactly as that guard does.
    #
    # A posture is a TRAJECTORY, not a value: `/mode` can be switched mid-run,
    # and a scalar has no honest answer for a run that switched. Last-wins
    # credits the whole run to the rung it ended in, first-wins to the rung it
    # left, and either DESTROYS the path -- while "every run that ever touched
    # `auto`" is an ordinary query OVER trajectories. So `manual → auto` is its
    # own axis point, comparable only with a run that walked the same path. A
    # designed sweep FIXES its arm's posture and so records one-element
    # trajectories that compare exactly like scalars.
    #
    # A switch to the posture already in force is journaled on purpose (a
    # transcript has to show the redundant request), but nothing moved, so
    # consecutive duplicates collapse: the axis reports the run, the journal
    # reports the request. ORDER is recorded, never DURATION, which BOUNDS
    # mis-attribution rather than eliminating it -- weighting a rung by the
    # turns spent in it would need a per-turn posture on the Timeline.
    #
    # Absence is never a fifth rung. A recording made before modes existed and a
    # session that never switched both carry no `mode_switch` record;
    # {UNRECORDED} is the Null Object for that and agrees with EVERYTHING,
    # because an absent claim cannot contradict one. A guard that refused
    # `manual` against "not recorded" would have made absence a fifth posture
    # and failed every fixture in the repo. What absence must not do is go
    # unsaid -- {Compare#report} names it in as many words.
    module Posture
      # Raised when two runs ran under postures that are known to differ.
      class Mismatch < Lain::Error; end

      # Raised when a journal's `mode_switch` records do not chain -- a flip
      # away from a posture that was not in force. See {.from_journal}.
      class BrokenChain < Lain::Error; end

      # The journal discriminator {Telemetry::ModeSwitch} derives from its class
      # basename. Named here because {.from_journal} matches on it.
      RECORD_TYPE = "mode_switch"

      # No posture was recorded for this run. Agrees with every other posture,
      # including another unrecorded one, through both halves of the double
      # dispatch -- so no caller anywhere writes `if posture`.
      UNRECORDED = Class.new do
        def agrees_with?(_other) = true

        def agrees_with_trajectory?(_names) = true

        def to_s = "not recorded"

        # Named, because an anonymous singleton renders as `#<#<Class:0x…>:0x…>`
        # and this value rides into a comparison report.
        def inspect = "Lain::Compare::Posture::UNRECORDED"
      end.new.freeze

      # One run's path through the ladder, in the order it walked it.
      Recorded = Data.define(:names) do
        def initialize(names:)
          super(names: names.map { |name| named(name) }.chunk_while { |a, b| a == b }.map(&:first).freeze)
        end

        def to_s = names.join(" → ")

        # Double dispatch, so neither arm branches on which arm it holds and
        # agreement stays symmetric.
        def agrees_with?(other) = other.agrees_with_trajectory?(names)

        def agrees_with_trajectory?(other_names) = names == other_names

        private

        # `respond_to?(:to_sym)` before delegating: {Mode::Posture.for}'s roster
        # message is only reachable once `.to_sym` has succeeded, so a nil off a
        # damaged journal line would die a NoMethodError naming neither the
        # ladder nor what was wrong. Interning from the shared frozen Posture
        # rather than the caller's String is what keeps this `Ractor.shareable?`.
        def named(name)
          unless name.respond_to?(:to_sym)
            raise ArgumentError,
                  "unknown posture #{name.inspect}, expected one of #{Mode::Posture::NAMES.inspect}"
          end

          Mode::Posture.for(name).name
        end
      end

      # @param names [Array<Symbol, String, Array>] the postures the run was in,
      #   in order; one name for a run that never switched
      # @return [Posture] a {Recorded} trajectory, or {UNRECORDED} for NO names
      #   at all -- an empty list is absence, and a `Recorded` holding none
      #   would render as the empty String and refuse against every rung.
      # @raise [ArgumentError] on a name that is not on the ladder
      def self.for(*names)
        named = names.flatten
        named.empty? ? UNRECORDED : Recorded.new(names: named)
      end

      # The coercion boundary {Compare::Run} hands its `posture:` to, so a
      # caller may name the posture however it holds it.
      #
      # @param value [nil, Posture, Mode, Mode::Posture, Symbol, String, Array]
      # @return [Posture] {UNRECORDED} for nil
      def self.coerce(value)
        return UNRECORDED if value.nil?
        return value if value.respond_to?(:agrees_with?)
        return Posture.for(value.posture.name) if value.is_a?(Mode)
        return Posture.for(value.name) if value.is_a?(Mode::Posture)

        Posture.for(value)
      end

      # Where the first flip came FROM, then every flip's destination. That
      # first `from` is the only evidence a journal carries of the posture a
      # session STARTED in, which is why the walk begins there.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @return [Posture] {UNRECORDED} when no flip was recorded
      # @raise [BrokenChain] when the records do not chain
      def self.from_journal(entries)
        flips = Journal.records(entries, type: RECORD_TYPE).to_a
        return UNRECORDED if flips.empty?

        chain!(flips)
        Posture.for(flips.first["from"], flips.map { |flip| flip["to"] })
      end

      # Each flip must leave the posture the previous flip arrived at. A chain
      # that says otherwise is a damaged line or two sessions' records
      # interleaved on one fd -- ordinary under fan-out. Without this the walk
      # reads only the `to`s after the first record and answers a plausible
      # trajectory that never happened: a silent wrong answer on the record.
      def self.chain!(flips)
        flips.each_cons(2) { |previous, flip| chained!(previous, flip) }
      end
      private_class_method :chain!

      def self.chained!(previous, flip)
        return true if flip["from"].to_s == previous["to"].to_s

        raise BrokenChain, "mode_switch records do not chain: a run in " \
                           "#{previous["to"]} cannot switch from #{flip["from"]}"
      end
      private_class_method :chained!

      # @return [true] when the two runs may be compared
      # @raise [Mismatch] when both postures are recorded and differ
      def self.guard!(one, other)
        return true if one.agrees_with?(other)

        raise Mismatch, "cannot compare runs under different postures: #{one} vs #{other}"
      end
    end
  end
end
