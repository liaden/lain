# frozen_string_literal: true

module Lain
  class Arm
    # Magentic-One's dual ledger as ONE deeply frozen value: the Task ledger
    # (`facts` gathered + `plan` laid out) and the Progress ledger (`progress`
    # made + the single `next_subtask` to attempt). The {DualLedger} arm carries
    # it sent-not-stored in the {Workspace} and swaps it for a new value each
    # step, so `Ractor.shareable?` stays true and two runs over the same inputs
    # render byte-identical prompts.
    #
    # NOT {Lain::Ledger}, which is the COST ledger. The collision is only in the
    # English word.
    #
    # {#signature} is the stall detector's whole input: two consecutive states
    # with the same signature made no progress. It is derived from progress
    # COUNT and the pending subtask, not the facts/plan, because replanning
    # rewrites the plan without advancing progress -- and a stall is precisely
    # "the plan changed but nothing got done".
    LedgerState = Data.define(:facts, :plan, :progress, :next_subtask) do
      # The seed ledger: the task itself is the first fact, nothing planned or
      # done yet, no subtask chosen.
      def self.initial(task:)
        new(facts: ["Task: #{task}"], plan: [], progress: [], next_subtask: nil)
      end

      # `Canonical.normalize` deep-freezes the Arrays and interns the Strings, so
      # every reachable node is frozen and shareable; `next_subtask` is an
      # interned String or nil (nil IS "no subtask chosen", a value not an
      # absence).
      def initialize(facts:, plan:, progress:, next_subtask: nil)
        super(
          facts: Canonical.normalize(Array(facts)),
          plan: Canonical.normalize(Array(plan)),
          progress: Canonical.normalize(Array(progress)),
          next_subtask: next_subtask.nil? ? nil : -next_subtask.to_s
        )
      end

      # The sent-not-stored projection the {Workspace} carries. Sections are
      # always present, even when empty, so the shape is stable across steps: a
      # disappearing "Progress:" heading would read as a different prompt.
      def to_reminder
        [
          "Task/Progress ledger",
          section("Facts", facts),
          section("Plan", plan),
          section("Progress", progress),
          "Next subtask: #{next_subtask || "(none chosen)"}"
        ].join("\n")
      end

      def advanced(note:, next_subtask: nil)
        self.class.new(facts:, plan:, progress: progress + [note.to_s], next_subtask:)
      end

      # Progress is RETAINED across a replan -- the work done survives it -- and
      # the signature changes only because `next_subtask` moved, which is what
      # lets the stall detector's counter reset after the arm reacts.
      def replanned(plan:, next_subtask: nil)
        self.class.new(facts:, plan: Array(plan), progress:, next_subtask:)
      end

      # Frozen -- an Array of an Integer and a frozen String or nil -- so it is a
      # safe Hash and comparison key.
      def signature
        [progress.size, next_subtask].freeze
      end

      private

      def section(heading, items)
        "#{heading}: #{items.empty? ? "(none)" : items.join("; ")}"
      end
    end
  end
end
