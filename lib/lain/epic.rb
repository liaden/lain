# frozen_string_literal: true

# Index for the epic/ unit (see CLAUDE.md, Requires). The epic tier is a
# content-addressed issue graph over {Epic::Issue}: blocking / related /
# discovered-from edges, stage gates, and the markdown artifact an author
# reviews. Issue carries the unit's STORED_STATUSES and grammar constants, so it
# loads first and every sibling added here can reopen the same Epic module
# cleanly. The unit sits after `plan` in lain.rb because Issue reads
# Gherkin::Criteria and Canonical.
require_relative "epic/issue"
require_relative "epic/graph"
require_relative "epic/stage"
require_relative "epic/document"
require_relative "epic/intake"
require_relative "epic/submission"
require_relative "epic/records"
require_relative "epic/progress"
require_relative "epic/home"
require_relative "epic/scribe"
