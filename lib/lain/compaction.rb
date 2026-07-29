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
  end
end
