# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module Epic
    # The journal handed to {Progress.fold} names other epics and never the one
    # it was asked to fold. Loud rather than folded to "nothing happened here":
    # a typo'd slug and the wrong journal both land exactly there, and both
    # would report a live epic as untouched.
    #
    # Named for what it IS -- a journal belonging to other work -- rather than
    # for "mixed epics", which is neither necessary (one foreign epic is enough)
    # nor sufficient (this epic's records sitting beside another's are fine, and
    # are simply partitioned away).
    class ForeignJournal < Error; end

    # The provenance a graph's LIVE issues declare, and the two questions the
    # fold asks of an id: is it CURRENT, and if not, is it HISTORY?
    #
    # The distinction is the whole superseded-id rule. {Graph#split} removes the
    # issue its parts grew out of and stamps each part's `discovered_from` with
    # the id that left, so a journal recorded before the split still names an id
    # the graph no longer holds. That is the designed state, not drift: those
    # transitions fold as inert history and touch no live issue's status. An
    # absent id nothing declares is a drifted document, and drift is an error
    # rather than a shrug.
    #
    # == It reaches exactly ONE hop
    #
    # The set is `{issue.discovered_from : issue live}` and nothing more. There
    # is no chain to walk: `discovered_from` resolves to a live issue only while
    # that issue survives, and every live issue's own link is already in the set
    # -- so following one would never add an id the first pass missed. An
    # earlier draft here recursed; it was provably incapable of adding an
    # element, and the two specs guarding it (multi-hop reach, cycle
    # termination) both passed vacuously because of it.
    #
    # The boundary that follows: history goes unreadable the moment a structural
    # edit removes the LAST live issue whose link names the id. {Graph#merge}
    # reaches it in ONE edit -- it passes no provenance override, so an arrival
    # declaring none orphans both parents at once, and since `discovered_from`
    # is single-valued, declaring one always orphans the other (merge's own
    # comment concedes exactly this). Splitting is gentler: parts are stamped
    # automatically, so a lineage stays readable while any sibling survives.
    # Past that boundary a genuinely historical transition is refused as drift.
    # Loud beats a silently wrong status, so the direction is right, but it IS a
    # false positive and the fix belongs in the lineage a {Graph} carries -- one
    # link cannot express two parents, and nothing inherits provenance forward.
    # Specs pin both sides.
    #
    # Held apart from {Progress} because Progress is the frozen VALUE and this
    # is a mutable index built to answer it -- one ivar of this would cost
    # `Ractor.shareable?(progress)`, the mechanical statement that the fold's
    # answer has no reachable mutable state.
    class Lineage
      def initialize(graph)
        @by_id = graph.to_h { |issue| [issue.id, issue] }
        @superseded = graph.filter_map(&:discovered_from).to_set
      end

      def current?(id) = @by_id.key?(id)

      def superseded?(id) = @superseded.include?(id)
    end
    private_constant :Lineage

    # The fold itself: journal records in, a frozen {Progress} out.
    #
    # Held apart from Progress for {Lineage}'s reason -- Progress is the value,
    # this is the machinery -- and because the three passes it makes (statuses,
    # stage, sign-offs) are one responsibility each, none of them the value's.
    class Refold
      # The record types that name an epic, and so the ones this epic's
      # PRESENCE in a journal is judged by. Deliberately closed: scanning every
      # record for an `epic_slug` key would let an unrelated tier's record vouch
      # for an epic. `gate_decision` counts, because a gate parked before any
      # issue moved is a real state.
      SLUG_TYPES = [IssueTransition::JOURNAL_TYPE, StageTransition::JOURNAL_TYPE,
                    Approval::SignoffQueue::JOURNAL_TYPE].freeze

      def initialize(entries, graph:, epic_slug:)
        # Materialized once rather than left lazy: the fold enumerates three
        # times and a one-shot Enumerator would silently fold to empty on the
        # second pass -- the trap {Event::Projection} documents for its own log.
        # An epic is a handful of issues and a day's records, so three passes
        # over an Array is the cheap answer; nothing here earns StatusFeed's
        # incremental machinery.
        records = Journal.records(entries).to_a
        @graph = graph
        @epic_slug = -epic_slug.to_s
        refuse_foreign_journal!(records)
        @records = records.select { |record| mine?(record) }
        @lineage = Lineage.new(graph)
      end

      # @return [Progress]
      def call
        stage = current_stage
        Progress.new(graph: overlaid, stage:, epic_slug: @epic_slug, parked: parked_at(stage))
      end

      private

      # A record naming ANOTHER epic is not ours and is dropped. A record naming
      # NO epic is KEPT, so its own guard refuses it downstream -- a filter that
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
      # should read as an untouched epic.
      #
      # This is the residual of the derivation this fold used to do. Deriving
      # the slug turned a typo'd name or the wrong journal into a confident
      # answer about another epic's work; naming it turns the same mistake into
      # a silent "nothing happened". Refusing here is what closes that.
      def refuse_foreign_journal!(records)
        named = named_epics(records)
        return if named.empty? || named.include?(@epic_slug)

        raise ForeignJournal, "no record in this journal names epic #{@epic_slug.inspect} -- it names " \
                              "#{named.map(&:inspect).join(", ")} instead (wrong journal, or a misspelled slug)"
      end

      # Sorted, so the refusal above names the epics in an order that is a
      # function of the records rather than of which was journaled first.
      def named_epics(records)
        records.select { |record| SLUG_TYPES.include?(record["type"].to_s) }
               .map { |record| record["epic_slug"].to_s }
               .reject { |slug| slug.strip.empty? }.uniq.sort
      end

      # The document's statuses with every journaled transition laid over them,
      # handed back to {Graph.new} so `#ready`, `#waves`, and the edge and cycle
      # validation are the graph's own answers over the effective statuses
      # rather than a second implementation of them here.
      def overlaid
        statuses = of_type(IssueTransition::JOURNAL_TYPE).inject(document_statuses) do |carried, record|
          moved = moved_id(record)
          moved ? carried.merge(moved => record["to_status"].to_s) : carried
        end
        Graph.new(issues: @graph.map { |issue| issue.with_status(statuses.fetch(issue.id)) })
      end

      def document_statuses = @graph.to_h { |issue| [issue.id, issue.status] }

      # The live id this transition moves, or nil when it moves an id that is
      # inert history. Guarded on the same {Guards::IssueTransition} the WRITE
      # side uses: a record that cannot be read whole aborts the fold, because
      # skipping it would leave its issue reading at the document's stale status
      # -- which is the very answer the Journal exists to override.
      def moved_id(record)
        Guards::IssueTransition.check!(epic_slug: record["epic_slug"], issue_id: record["issue_id"],
                                       from_status: record["from_status"], to_status: record["to_status"])
        id = record["issue_id"].to_s
        return id if @lineage.current?(id)
        return nil if @lineage.superseded?(id)

        raise UnknownIssue, unknown_message(id)
      end

      # Says what to DO, not what the walk failed to find. The two remedies are
      # the two ways the id can have got here: the document drifted (re-journal
      # the transition under the id that carries the work now), or a structural
      # edit dropped the provenance that made it legible (declare
      # `discovered_from` on the live issue that inherited it). A merge reaches
      # the second case in one edit, so it is not the rare path the machinery
      # makes it sound.
      def unknown_message(id)
        "journaled issue_transition names unknown issue #{id.inspect} in epic #{@epic_slug.inspect} -- " \
          "no live issue carries that id or declares it as `discovered_from`. Re-journal the transition " \
          "under the id that carries the work now, or declare the missing provenance on the live issue."
      end

      # The last stage STARTED, or the first stage when nothing has started.
      # A completion advances nothing: inventing the successor would claim work
      # began that no record shows, and an epic can sit between stages for days.
      # Every record is guarded, completions included -- a malformed one is
      # unreadable about which stage it names either way.
      def current_stage
        started = of_type(StageTransition::JOURNAL_TYPE).filter_map { |record| checked_start(record) }
        started.to_a.last || Stage.new(STAGES.first)
      end

      def checked_start(record)
        Guards::StageTransition.check!(epic_slug: record["epic_slug"], event: record["event"])
        stage = Stage.new(record["stage"].to_s)
        stage if record["event"].to_s == STAGE_EVENTS.first
      end

      # The rebuild NEVER degrades to an empty queue on failure. There is no
      # rescue here and there must not be one: {Approval::Gate::Policy::Drained}
      # legitimizes "this session has no queue", never "this rebuild failed",
      # and an empty queue reads as drained while drained opens the next stage
      # over work nobody signed off.
      def parked_at(stage)
        Approval::SignoffQueue.from_journal(@records).parked(@epic_slug, stage.name)
      end

      def of_type(type) = Journal.records(@records, type:)
    end
    private_constant :Refold

    # Where one epic actually stands: the Journal's runtime truth folded over
    # the document an author wrote.
    #
    # `graph` is the parsed graph with the journal's statuses laid over it, so
    # it IS the effective view and there is no second copy of the statuses to
    # disagree with it. `#ready` is the graph's own derivation asked of that
    # view rather than reimplemented, which is what keeps "an abandoned blocker
    # still blocks" a single rule.
    #
    # A pure offline refold, in {Event::Projection}'s shape: same records and
    # same graph, same answer, no accumulated state. Deeply frozen and
    # `Ractor.shareable?`, so it can be handed to a renderer or another thread
    # as the settled fact it is.
    #
    # Note {Graph#waves} is deliberately status-blind -- a finished first wave
    # still reports as wave 1, which is correct as a DAG layering. Remaining
    # work is computed from these effective statuses, never from wave output.
    Progress = Data.define(:graph, :stage, :epic_slug, :parked) do
      # `epic_slug` is REQUIRED, and that is the safety rule rather than an
      # ergonomic slip. A {Graph} carries no slug, so a slug derived from the
      # records could never be checked against the issues it is about: a journal
      # holding only another epic's transitions would derive THAT epic and fold
      # its work onto these issues, reporting progress on work that never
      # happened. Every caller knows the slug -- it read the document the graph
      # came from.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @param graph [Graph] the parsed document's issue graph
      # @param epic_slug [String] the epic to fold; a journal naming only OTHER
      #   epics is refused as {ForeignJournal}
      # @return [Progress]
      def self.fold(entries, graph:, epic_slug:)
        Refold.new(entries, graph:, epic_slug:).call
      end

      def initialize(graph:, stage:, epic_slug:, parked:)
        super(graph:, stage:, epic_slug: named_epic(epic_slug), parked: signoffs(parked))
      end

      # One issue's effective status.
      # @raise [UnknownIssue] for an id this epic does not hold
      def status(id) = graph.fetch(id).status

      # Pending, with every blocker done -- {Graph#ready} over the overlay.
      def ready = graph.ready

      # The one line an author scans: where the epic is, how much is finished,
      # how much is moving, and how much is waiting on a human.
      def summary
        "stage #{stage} — #{tally("done")}/#{graph.count} done, #{tally("in_flight")} in flight, " \
          "#{parked.size} #{"gate".pluralize(parked.size)} parked"
      end

      private

      def tally(status) = graph.count { |issue| issue.status == status }

      # Member type asserted rather than ducked, for {Graph#clean_issues}'
      # reason. `Data` freezes the instance and `Array#freeze` is shallow, so
      # this value is deeply frozen -- and `Ractor.shareable?` -- only because
      # every member is itself a frozen value. {Refold} always supplies Items,
      # but this constructor is public, so it says so instead of hoping. Copied
      # before freezing, so the caller keeps ownership of the array it passed.
      def signoffs(parked)
        refuse_stranger!(parked) unless parked.is_a?(Array)
        stranger = parked.find { |item| !item.is_a?(Approval::SignoffQueue::Item) }
        refuse_stranger!(stranger) if stranger

        parked.dup.freeze
      end

      def refuse_stranger!(offender)
        raise ArgumentError,
              "parked must be an Array of #{Approval::SignoffQueue::Item} values (got #{offender.inspect})"
      end

      # Interned first, so the check judges the bytes that get stored: a slug
      # object whose #to_s is blank passes a naive presence test and then names
      # a partition nothing can match -- the reason {Approval::SignoffQueue}'s
      # own Partition interns before its guard. Asserted here for the reason the
      # member type above is: this constructor is public, and every other member
      # of this value is refused when it cannot do its job.
      def named_epic(epic_slug)
        slug = -epic_slug.to_s
        refuse_unnamed!(epic_slug) if slug.strip.empty?

        slug
      end

      def refuse_unnamed!(offender)
        raise ArgumentError, "epic_slug must name the epic this progress is about (got #{offender.inspect})"
      end
    end
  end
end
