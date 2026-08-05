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
# AFTER `records`: it builds an {AnnotationPlaced} out of an {Anchor}, so both
# have to exist by the time anything calls it.
require_relative "review/annotations"
require_relative "review/verdict"
require_relative "review/session"
# AFTER the aggregate it holds. Its two nulls name {Frontend::Neovim::ReviewView}
# and {Review::Docent} -- both from METHOD bodies only, so neither binds load
# order the way `annotations` above does.
require_relative "review/handover"

# The ONE wiring line the diagnostics capability costs, and it is nested rather
# than routed through a `projection.rb` index on purpose: an index whose only
# member is deletable is a second file that has to be deleted along with it,
# and this capability's whole premise is that removal is one file and one line.
# `Epic` already requires `epic/review/annotations` the same way. Last, because
# `Projection::Diagnostics` cites `ANNOTATION_KINDS` while its class body runs.
require_relative "review/projection/diagnostics"

# The second and last line the diagnostics capability costs, and it is here for
# the same reason its sibling above has no index: `Review::Prefill` is deletable,
# and deleting `projection/diagnostics` forces deleting it too -- its rank map
# derives from that one's while its class body runs, so it must load after.
require_relative "review/prefill"

# The whole of the GitHub write path, and the third deletable unit in this tail:
# this line plus `review/submit.rb` are all of it (the chunk's deletion map).
# After the aggregate it reads; nothing else requires it and nothing reads it.
require_relative "review/submit"

# The docent (T24), and the fourth deletable unit in this tail. This line plus
# `review/docent.rb` are all of it HERE, but not all of it: the docent is a
# ROLE, so removal also takes the `:diff_docent` entry in `role/catalog.rb`, the
# `diff-docent.md` role template, the name in `role_spec.rb`'s roll call, and
# `CLI::Wiring::ToolsetBuild`'s one `#docent` line (the chunk's deletion map).
# The catalog and the shipped templates are pinned equal in BOTH directions, so
# deleting either alone is a red spec rather than a silent gap.
#
# After `changeset`, whose hunks and revisions it reads, and after `records`,
# whose {Wire} refusals its own guards use while their class bodies run.
require_relative "review/docent"
