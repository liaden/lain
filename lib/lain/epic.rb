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
  # namespace file is the one file guaranteed to have. Left in a child, the
  # only guarantee is the order the loader happens to walk a directory in.
  #
  # The unit already keeps a constant this way one level down -- `intake.rb`
  # holds KINDS for `intake/delta.rb`'s class body -- so this is that pattern
  # at the namespace's own level rather than a new one.
  module Epic
    # The stages an epic walks, in order. A CLOSED set, like
    # {STORED_STATUSES}: the order is the pipeline, so membership and position
    # are the same fact and neither may be spelled twice.
    STAGES = %w[research epic_plan issue_plan implementation].freeze

    # The stages whose artifact is about ONE issue, so their gates are opened,
    # parked and approved per issue. research and epic_plan are the epic's own
    # documents and stay epic-wide.
    ISSUE_STAGES = %w[issue_plan implementation].freeze

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

    # The three ways bytes an author wrote can fail to be an epic, gathered
    # here rather than beside the parsers that raise them because {Intake}'s
    # PARSE_FAILURES names all three in a class body -- it can only do that if
    # they are defined by the time it loads, and the namespace file is the one
    # file guaranteed to be. Each is a {Lain::Error}, so exe/lain renders it
    # instead of crashing.
    class MalformedDocument < Error; end
    class MalformedGraph < Error; end
    class MalformedIssue < Error; end
  end
end
