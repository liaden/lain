# frozen_string_literal: true

module Lain
  # The diff-review surface: a changeset, the marks and notes a human leaves on
  # it, and the verdict that closes it.
  module Review
  end
end

# Vocabulary FIRST, and the AGGREGATE last: every guard in `records` cites a
# closed set and a refusal message while its class body runs, and `Anchor::SIDES`
# derives from `Review::SIDES` at class-body time too. `vocabulary` and `wire`
# are mutually independent; records-before-session and marks-before-verdict are
# what actually bind -- `verdict/policy` reads `Marks::REVIEWED` in its class
# body, and `session` names every record type in `Replay::TYPES` in its.
require_relative "review/vocabulary"
require_relative "review/wire"
require_relative "review/keying"
require_relative "review/anchor"
require_relative "review/hunk"
require_relative "review/marks"
require_relative "review/placement"
require_relative "review/source"
require_relative "review/delta"
require_relative "review/changeset"
require_relative "review/bounds"
require_relative "review/surface"
require_relative "review/records"
require_relative "review/verdict"
require_relative "review/session"

# The ONE wiring line the diagnostics capability costs, and it is nested rather
# than routed through a `projection.rb` index on purpose: an index whose only
# member is deletable is a second file that has to be deleted along with it,
# and this capability's whole premise is that removal is one file and one line.
# `Epic` already requires `epic/review/annotations` the same way. Last, because
# `Projection::Diagnostics` cites `ANNOTATION_KINDS` while its class body runs.
require_relative "review/projection/diagnostics"
