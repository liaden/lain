# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module Epic
    # The provenance a graph's LIVE issues declare, and the two questions the
    # fold asks of an id: is it CURRENT, and if not, is it HISTORY?
    #
    # That distinction is the superseded-id rule. {Graph#split} removes the issue
    # its parts grew out of and stamps each part's `discovered_from` with the id
    # that left, so a journal recorded before the split still names an id the
    # graph no longer holds: designed state, not drift, folding as inert history
    # that touches no live issue's status. An absent id nothing declares IS
    # drift, and drift is an error rather than a shrug.
    #
    # The set is `{issue.discovered_from : issue live}` and reaches exactly ONE
    # hop -- `discovered_from` resolves to a live issue only while that issue
    # survives, and every live issue's own link is already in the set, so
    # following one could never add an id the first pass missed. An earlier draft
    # recursed; it was provably incapable of adding an element, and the two specs
    # guarding it (multi-hop reach, cycle termination) both passed vacuously.
    #
    # History goes unreadable when a structural edit removes the LAST live issue
    # whose link names the id. {Graph#merge} reaches that in ONE edit: with
    # `discovered_from` single-valued, declaring one parent always orphans the
    # other, and a genuinely historical transition past that boundary is refused
    # as drift. Loud beats a silently wrong status, but it IS a false positive
    # and the fix belongs in the lineage a {Graph} carries. Specs pin both sides.
    #
    # Held apart from {Progress}: Progress is the frozen VALUE, this is a mutable
    # index built to answer it, and one ivar of this would cost
    # `Ractor.shareable?(progress)`.
    class Lineage
      def initialize(graph)
        @by_id = graph.to_h { |issue| [issue.id, issue] }
        @superseded = graph.filter_map(&:discovered_from).to_set
      end

      def current?(id) = @by_id.key?(id)

      def superseded?(id) = @superseded.include?(id)
    end
    private_constant :Lineage

    # The fold itself: journal records in, a frozen {Progress} out. Held apart
    # from Progress for {Lineage}'s reason, and because its three passes
    # (statuses, stage, sign-offs) are one responsibility each, none the value's.
    #
    # The graph arrives at {#call}, not at construction, because the stage pass
    # never reads it: research is approved before epic.md exists, and where the
    # epic stands has to be answerable then.
    class Refold
      # The record types this epic's PRESENCE in a journal is judged by, and a
      # CLOSED set: scanning every record for an `epic_slug` key would let an
      # unrelated tier's record vouch for an epic. `gate_decision` counts,
      # because a gate parked before any issue moved is a real state.
      SLUG_TYPES = [IssueTransition::JOURNAL_TYPE, StageTransition::JOURNAL_TYPE,
                    Approval::SignoffQueue::JOURNAL_TYPE].freeze

      def initialize(entries, epic_slug:)
        # Materialized once rather than left lazy: the fold enumerates three
        # times and a one-shot Enumerator would silently fold to empty on the
        # second pass -- the trap {Event::Projection} documents for its own log.
        # An epic is a handful of issues and a day's records, so three passes
        # over an Array is the cheap answer.
        records = Journal.records(entries).to_a
        @epic_slug = -epic_slug.to_s
        refuse_foreign_journal!(records)
        @records = records.select { |record| mine?(record) }
      end

      # @param graph [Graph] the parsed document's issue graph
      # @return [Progress]
      def call(graph)
        stage = self.stage
        Progress.new(graph: overlaid(graph), stage:, epic_slug: @epic_slug, parked: parked_at(stage))
      end

      # The last stage STARTED, or the first when nothing has. A completion
      # advances nothing: inventing the successor would claim work began that no
      # record shows, and an epic can sit between stages for days. Every record
      # is checked, completions included -- a malformed one is unreadable about
      # which stage it names either way.
      #
      # @return [Stage]
      def stage
        started = of_type(StageTransition::JOURNAL_TYPE).filter_map { |record| checked_start(record) }
        started.to_a.last || Stage.new(STAGES.first)
      end

      private

      # A record naming ANOTHER epic is not ours and is dropped. A record naming
      # NO epic is KEPT, so its own contract refuses it downstream -- a filter that
      # swallowed the unattributable line would silently skip exactly the record
      # that most needs refusing.
      def mine?(record)
        slug = record["epic_slug"].to_s
        slug.strip.empty? || slug == @epic_slug
      end

      # A journal that names epics, none of them ours, is refused. Silence is
      # fine -- a fresh epic has journaled nothing yet, and that folds to the
      # document's own statuses -- but "this journal is about other work" and
      # "nothing has happened here" are different facts, and only one of them
      # should read as an untouched epic. Naming the slug rather than deriving it
      # turns a typo into that silent "nothing happened"; this closes it.
      def refuse_foreign_journal!(records)
        named = named_epics(records)
        return if named.empty? || named.include?(@epic_slug)

        # The journal handed to {Progress.fold} names other epics and never the one
        # it was asked to fold. Loud rather than folded to "nothing happened here":
        # a typo'd slug and the wrong journal both land exactly there, and both
        # would report a live epic as untouched. Said for what it IS rather than
        # for "mixed epics", which is neither necessary (one foreign epic is enough)
        # nor sufficient (this epic's records beside another's are partitioned away).
        raise Error, "no record in this journal names epic #{@epic_slug.inspect} -- it names " \
                     "#{named.map(&:inspect).join(", ")} instead (wrong journal, or a misspelled slug)"
      end

      # Sorted, so the refusal above names the epics in an order that is a
      # function of the records rather than of which was journaled first.
      def named_epics(records)
        records.select { |record| SLUG_TYPES.include?(record["type"].to_s) }
               .map { |record| record["epic_slug"].to_s }
               .reject { |slug| slug.strip.empty? }.uniq.sort
      end

      # Handed back to {Graph.new} so `#ready`, `#waves`, and the edge and cycle
      # validation are the graph's own answers over the effective statuses rather
      # than a second implementation of them here.
      def overlaid(graph)
        lineage = Lineage.new(graph)
        statuses = of_type(IssueTransition::JOURNAL_TYPE).inject(document_statuses(graph)) do |carried, record|
          moved = moved_id(record, lineage)
          moved ? carried.merge(moved => record["to_status"].to_s) : carried
        end
        Graph.new(issues: graph.map { |issue| issue.with_status(statuses.fetch(issue.id)) })
      end

      def document_statuses(graph) = graph.to_h { |issue| [issue.id, issue.status] }

      # The live id this transition moves, or nil when it moves an id that is
      # inert history. Checked against the same {Contracts::IssueTransition} the
      # WRITE side uses: a record that cannot be read whole aborts the fold, because
      # skipping it would leave its issue reading at the document's stale status
      # -- which is the very answer the Journal exists to override.
      def moved_id(record, lineage)
        Contracts::IssueTransition.check!(epic_slug: record["epic_slug"], issue_id: record["issue_id"],
                                          from_status: record["from_status"], to_status: record["to_status"])
        id = record["issue_id"].to_s
        return id if lineage.current?(id)
        return nil if lineage.superseded?(id)

        raise Error, unknown_message(id)
      end

      # Says what to DO, not what the walk failed to find, because the id can
      # have got here two ways: the document drifted, or a structural edit
      # dropped the provenance that made it legible. A merge reaches the second
      # in one edit, so it is not the rare path the machinery makes it sound.
      def unknown_message(id)
        "journaled issue_transition names unknown issue #{id.inspect} in epic #{@epic_slug.inspect} -- " \
          "no live issue carries that id or declares it as `discovered_from`. Re-journal the transition " \
          "under the id that carries the work now, or declare the missing provenance on the live issue."
      end

      def checked_start(record)
        Contracts::StageTransition.check!(epic_slug: record["epic_slug"], event: record["event"])
        stage = Stage.new(record["stage"].to_s)
        stage if record["event"].to_s == STAGE_EVENTS.first
      end

      # The rebuild NEVER degrades to an empty queue on failure, so there is no
      # rescue here and must not be one: an empty queue reads as drained, and
      # drained opens the next stage over work nobody signed off.
      def parked_at(stage)
        queue = Approval::SignoffQueue.from_journal(@records)
        watched(stage).flat_map { |shown| queue.parked(@epic_slug, shown.name) }
      end

      # An issue-scoped verdict moves no epic-wide stage, so once the epic is
      # planning its issues the stage reads the first issue-scoped one for the
      # rest of the run -- and from there every issue-scoped partition is this
      # epic's current business.
      def watched(stage) = stage.issue_scoped? ? Stage.all.select(&:issue_scoped?) : [stage]

      def of_type(type) = Journal.records(@records, type:)
    end
    private_constant :Refold

    # Where one epic actually stands: the Journal's runtime truth folded over
    # the document an author wrote.
    #
    # `graph` is the parsed graph with the journal's statuses laid over it, so it
    # IS the effective view and there is no second copy to disagree with it.
    # `#ready` is the graph's own derivation asked of that view rather than
    # reimplemented, which keeps "an abandoned blocker still blocks" one rule. A
    # pure offline refold in {Event::Projection}'s shape: same records and same
    # graph, same answer, no accumulated state, deeply frozen and
    # `Ractor.shareable?`.
    #
    # Note {Graph#waves} is deliberately status-blind -- a finished first wave
    # still reports as wave 1, which is correct as a DAG layering. Remaining
    # work is computed from these effective statuses, never from wave output.
    Progress = Data.define(:graph, :stage, :epic_slug, :parked) do
      # `epic_slug` is REQUIRED as a safety rule, not an ergonomic slip. A
      # {Graph} carries no slug, so a slug derived from the records could never
      # be checked against the issues it is about: a journal holding only another
      # epic's transitions would derive THAT epic and fold its work onto these
      # issues, reporting progress on work that never happened.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @param graph [Graph] the parsed document's issue graph
      # @param epic_slug [String] the epic to fold; a journal naming only OTHER
      #   epics is refused, naming the epics it does hold
      # @return [Progress]
      def self.fold(entries, graph:, epic_slug:)
        Refold.new(entries, epic_slug:).call(graph)
      end

      # Where the epic stands, folded from the records alone: the same stage
      # {.fold} reads, answerable before the epic's document is written.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @param epic_slug [String] the epic to fold, refused as {.fold} refuses it
      # @return [Stage]
      def self.stage(entries, epic_slug:) = Refold.new(entries, epic_slug:).stage

      def initialize(graph:, stage:, epic_slug:, parked:)
        slug = named_epic(epic_slug)
        super(graph:, stage:, epic_slug: slug, parked: signoffs(parked, slug))
      end

      # One issue's effective status.
      # @raise [Error] for an id this epic does not hold
      def status(id) = graph.fetch(id).status

      # Pending, with every blocker done -- {Graph#ready} over the overlay.
      def ready = graph.ready

      # The one line an author scans.
      def summary
        "stage #{stage} — #{tally("done")}/#{graph.count} done, #{tally("in_flight")} in flight, " \
          "#{parked.size} #{"gate".pluralize(parked.size)} parked"
      end

      private

      def tally(status) = graph.count { |issue| issue.status == status }

      # Member type asserted rather than ducked: `Data` freezes the instance and
      # `Array#freeze` is shallow, so this value is deeply frozen -- and
      # `Ractor.shareable?` -- only because every member is itself frozen. Copied
      # before freezing, so the caller keeps ownership of the array it passed.
      def signoffs(parked, slug)
        refuse_stranger!(parked) unless parked.is_a?(Array)
        stranger = parked.find { |item| !item.is_a?(Approval::SignoffQueue::Item) }
        refuse_stranger!(stranger) if stranger
        foreign = parked.find { |item| item.epic_slug != slug }
        refuse_foreign!(foreign, slug) if foreign

        parked.dup.freeze
      end

      def refuse_stranger!(offender)
        raise ArgumentError,
              "parked must be an Array of #{Approval::SignoffQueue::Item} values (got #{offender.inspect})"
      end

      def refuse_foreign!(item, slug)
        raise Error, "progress for epic #{slug.inspect} was handed a sign-off parked in epic " \
                     "#{item.epic_slug.inspect} (#{item.artifact_digest}) -- one epic's fold never " \
                     "carries another's"
      end

      # Interned first, so the check judges the bytes that get stored: a slug
      # object whose #to_s is blank passes a naive presence test and then names a
      # partition nothing can match -- the reason {Approval::SignoffQueue}'s own
      # Partition interns before its contract.
      def named_epic(epic_slug)
        slug = -epic_slug.to_s
        refuse_unnamed!(epic_slug) if slug.strip.empty?

        slug
      end

      def refuse_unnamed!(offender)
        # A {Progress} asked to describe no epic at all. A {Lain::Error}, so
        # `exe/lain` reports it rather than printing a backtrace.
        raise Error, "epic_slug must name the epic this progress is about (got #{offender.inspect})"
      end
    end
  end
end
