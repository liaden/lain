# frozen_string_literal: true

module Lain
  # A content-addressed issue graph over {Epic::Issue} -- blocking / related /
  # discovered-from edges, stage gates, and the markdown artifact an author
  # reviews.
  #
  # This file is the namespace's own, so it holds the constants that belong to
  # the UNIT rather than to any one file in it. A sibling naming one in its
  # CLASS BODY -- {Epic::Contracts} reads four of these and {Epic::Intake} a
  # fifth -- can only do so if the definition has already run, and the
  # namespace file is the one file guaranteed to have. Left in a child, that
  # guarantee is the require manifest's order: true today and alphabetical luck
  # the moment a loader is doing the requiring.
  #
  # The unit already keeps a constant this way one level down -- `intake.rb`
  # holds KINDS for `intake/delta.rb`'s class body -- so this is that pattern
  # at the namespace's own level rather than a new one.
  module Epic
    # The statuses an issue may CARRY. `ready` is deliberately not a member: it
    # is a predicate the graph derives (pending with every blocker done), and a
    # closed set holding a value no author may write is a special case waiting
    # to be forgotten. Refusing it by name, with the reason, is what keeps the
    # set closed and the derivation discoverable.
    STORED_STATUSES = %w[pending in_flight done abandoned].freeze
    DERIVED_STATUSES = %w[ready].freeze

    # What can happen TO a stage. Closed the way {STAGES} and {STORED_STATUSES}
    # are, and for the same reason: `event` is folded on, so a third spelling
    # would read as neither started nor completed and contribute nothing.
    STAGE_EVENTS = %w[started completed].freeze

    # The four artifacts a {Home} holds, as the journal names them. Closed so a
    # reader joining a `doc_written` record back to a file knows which of the
    # four layouts the path came from; a fifth spelling would join to nothing.
    DOC_KINDS = %w[research epic issue plan].freeze

    # The structural edits a revision may name, keyed by the operation it
    # journals and valued by the arguments that operation replays FROM. Sorted,
    # because {Canonical.normalize} sorts the keys a fiber carries. ONE
    # declaration -- {Contracts::GraphRevision} and {GraphFiber}'s argument check
    # both read it -- so an operation nothing can replay is exactly an operation
    # no fiber may carry, with no second copy to drift beside the journal.
    #
    # The replay itself is `replay_<operation>` on {GraphFiber}: that naming
    # contract is what lets the vocabulary and the dispatch be one table.
    #
    # Every level frozen, as an epic record's own nested values are: a frozen
    # Hash over mutable Arrays is not `Ractor.shareable?`, which is this
    # codebase's mechanical statement of "no reachable mutable state".
    REVISION_OPS = { "add" => %w[discovered_from issue], "split" => %w[id into],
                     "merge" => %w[as left right] }.transform_values(&:freeze).freeze

    # Bytes an author wrote that are not an issue. A {Lain::Error}, so exe/lain
    # renders it instead of crashing, and one of {Intake}'s PARSE_FAILURES.
    class MalformedIssue < Error; end
  end
end

# Index for the epic/ unit. It sits after `plan` in lain.rb because Issue reads
# Gherkin::Criteria and Canonical. Contracts loads first: {Epic::Submission}
# reopens it, so the file the module's docstring lives in has to be the file
# that defines it.
require_relative "epic/contracts"
require_relative "epic/issue"
require_relative "epic/blocking"
require_relative "epic/graph"
require_relative "epic/graph_fiber"
require_relative "epic/stage"
require_relative "epic/document"
require_relative "epic/intake"
require_relative "epic/submission"
require_relative "epic/issue_transition"
require_relative "epic/stage_transition"
require_relative "epic/doc_written"
require_relative "epic/graph_revision"
require_relative "epic/wire_integer"
require_relative "epic/review_claim"
require_relative "epic/review_opened"
require_relative "epic/review_closed"
require_relative "epic/annotation_value"
require_relative "epic/annotation"
require_relative "epic/review/annotations"
require_relative "epic/review"
require_relative "epic/progress"
require_relative "epic/mermaid"
require_relative "epic/home"
require_relative "epic/scribe"
require_relative "epic/in_flight"
require_relative "epic/advance"
