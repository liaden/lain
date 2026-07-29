# frozen_string_literal: true

require_relative "compaction/boundary"
require_relative "compaction/head"
require_relative "compaction/need"
require_relative "compaction/cold"
require_relative "compaction/scheduler"
require_relative "compaction/prepared"
require_relative "compaction/summary_snapshot"
require_relative "compaction/strategy"
require_relative "compaction/derivation"
require_relative "compaction/derivation_audit"
require_relative "compaction/source"

module Lain
  # Whether a compaction is warranted, where it cuts, what collapses the span,
  # and how the collapse is recorded. Eleven members, in the order a turn meets
  # them: {Need} detects (the signal bank), {Cold} tracks cache warmth,
  # {Scheduler} decides when to spend one, {Head} and {Boundary} locate the cut,
  # {SummarySnapshot} freezes the eager tier for the turn, {Strategy} collapses
  # a span, {Derivation} writes the collapse into the Store, {DerivationAudit}
  # reads it back, {Source} is the live per-turn seam the Agent asks, and
  # {Prepared} belongs to the older design below.
  #
  # TWO COMPACTION DESIGNS SHIP AND ONLY ONE IS ON THE CHAT PATH. The shipped
  # one is the DERIVED chain: {Source} builds a {Source::Derived}
  # (`source.rb:152`), which materializes a second lineage in the session's own
  # Store and replays `Derivation.projected` as the rendered messages
  # (`source/derived.rb:126`). {Context::Compact} -- the render-time projection
  # most of this module's doc comments were written against -- is now a BENCH
  # ARM: its only two constructors are offline (`plan/linear_rewrite.rb:106`,
  # `bench/plan_sweep/driver.rb:157`), and chunk 16 ruled explicitly against
  # retiring it. {Prepared} was built to pair with it and has no caller at all.
  #
  # So read {Head}'s and {Boundary}'s references to {Context::Compact} as the
  # arm, not as the caller: theirs is `Source#decide`.
  module Compaction
    # The `keep_last` rule, on the module because THREE objects consult it:
    # {Boundary}, {Context::Compact} and {Source}, each of which takes the number
    # at construction. It lived on {Head}, was copied onto {Boundary} under a
    # comment promising to mirror it "line for line", and was reached by the other
    # two through a THROWAWAY Head or Boundary built over an empty message list
    # purely for its constructor's refusal. Three doors onto one refusal is three
    # chances for one of them to relax.
    #
    # {Head} is deliberately NOT a fourth door. It builds a {Boundary} as its
    # first statement, so the refusal already fires before it reads a message; a
    # call of its own was unreachable by construction, and a mutation deleting it
    # left the whole suite green -- including the example named for Head's door,
    # which was a Boundary test wearing Head's name.
    #
    # Both degenerate values USED TO diverge silently, which is why they are
    # refused rather than measured (panel probe, 2026-07-25):
    #
    #   0 -- `messages[0...0]` and `messages.last(0)` are both empty, so above
    #     threshold a collapse replaced the ENTIRE history with a summary of ZERO
    #     messages while the head reported nothing droppable. Total history loss,
    #     and the disagreement ran opposite to the one {Head} exists to delete.
    #   negative -- the head sliced happily; `messages.last(-1)` raised
    #     `ArgumentError: negative array size` inside `Compact#call`, which means
    #     inside `Context#render`.
    #
    # Every consumer applies it at CONSTRUCTION, never from inside a `#call`:
    # {Boundary}'s own doc argues that raising inside `Context#render` is worse
    # than not compacting at all, so a bad wiring must fail at wiring time.
    #
    # @param keep_last [Object] whatever the caller was configured with
    # @return [Integer] the coerced, positive value
    # @raise [ArgumentError] on zero, on a negative, and on a String `Integer()`
    #   cannot read (`"several"`)
    # @raise [TypeError] on a value `Integer()` will not convert at all -- `nil`,
    #   an Array, a boolean. Deliberately not caught and re-raised as an
    #   ArgumentError: `Integer()`'s own refusal names the offending value and its
    #   type, which is more than a uniform error class would say.
    def self.validate_keep_last(keep_last)
      integer = Integer(keep_last)
      raise ArgumentError, "keep_last must be positive, got #{integer}" unless integer.positive?

      integer
    end
  end
end
