# frozen_string_literal: true

module Lain
  # The diff-review surface: a changeset, the marks and notes a human leaves on
  # it, and the verdict that closes it.
  module Review
  end
end

# Vocabulary FIRST, aggregate LAST. The edges that actually bind are class-body
# reads: `Anchor::SIDES` derives from `Review::SIDES`, `verdict/policy` reads
# `Marks::REVIEWED`, and `session` names every record type in `Replay::TYPES`.
require_relative "review/vocabulary"
require_relative "review/wire"
require_relative "review/keying"
require_relative "review/anchor"
require_relative "review/hunk"
require_relative "review/marks"
require_relative "review/source"
require_relative "review/partition"
require_relative "review/changeset"
require_relative "review/lazy_file"
require_relative "review/bounds"
require_relative "review/surface"
require_relative "review/records"
# AFTER `records`: it builds an {AnnotationPlaced} out of an {Anchor}, so both
# have to exist by the time anything calls it.
require_relative "review/annotations"
require_relative "review/verdict"
require_relative "review/session"
# AFTER the aggregate it holds. Its two nulls are named from METHOD bodies only,
# so neither binds load order the way `annotations` above does.
require_relative "review/handover"
# AFTER `source`: `OpenedBanner::FILE_SIDE` selects the file's side out of
# `Source::HEAD_SIDE_ONLY` while its CLASS body runs.
require_relative "review/opened_banner"

# The tail is two independently deletable units, each one file plus its one
# require line.

# The whole of the GitHub write path. After the aggregate it reads; nothing else
# requires it and nothing reads it.
require_relative "review/submit"

# The docent is a ROLE, so removing it also takes the `:diff_docent` catalog
# entry, its role template, and `CLI::Wiring::ToolsetBuild`'s one `#docent` line.
# Catalog and shipped templates are pinned equal in BOTH directions, so deleting
# either alone is a red spec rather than a silent gap.
#
# After `changeset`, whose hunks and revisions it reads, and after `records`,
# whose {Wire} refusals its own guards use while their class bodies run.
require_relative "review/docent"
