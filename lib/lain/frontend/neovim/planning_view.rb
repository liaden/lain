# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # lain://planning: the roadmap sidebar of the planning tab, one row per
      # issue in graph order with its stage, its gate and what holds it. Like
      # {StatusView} it is folded from disk, because a gate answered by `lain
      # epic submit` in another terminal never reaches this Channel, and it
      # redraws only on the events that can move a row.
      #
      # Every row leads with the issue id between backticks: the runtime finds
      # the issue under the cursor by that, so a title is free to say anything.
      class PlanningView
        NAME = "lain://planning"

        # No TurnUsage: every refold reads each session journal of the project,
        # and a gate answered in another terminal shows on the next record of its own.
        REFOLD_TYPES = [Lain::Epic::IssueTransition, Lain::Epic::StageTransition, Lain::Epic::GateDecision,
                        Telemetry::AwaitingHuman].freeze

        # @!attribute [r] gate
        #   @return [String] draft, waiting, parked, approved (or approved at other bytes, or with its file gone),
        #     or held or denied with its note's first line
        Row = Data.define(:id, :title, :mark, :stage, :gate, :blockers) do
          def line
            held = blockers.empty? ? "" : " (blocked by #{blockers.map { |id| "`#{id}`" }.join(", ")})"
            "[#{mark}] `#{id}` #{title} -- #{stage}, #{gate}#{held}"
          end
        end

        # A line of the roadmap that is no issue's row, so it carries no id for the cursor to land on.
        Note = Data.define(:line)

        # A gate's stage is whichever of its records came last, and a wait
        # reopens it: a deferred wait is the one written after the decision that
        # parked the gate, so it reads as parked, as `lain epic status` counts
        # it. What a decision left is {Lain::Epic::GateView}'s phase for that
        # issue's partition, read against the artifact's digest now, so this row
        # and every other reader agree.
        module Roadmap
          GATE_TYPES = %w[gate_decision awaiting_human].freeze

          module_function

          # @param progress [Lain::Epic::Progress]
          # @param records [Enumerable<Hash>] journal records, oldest first
          # @param digests [#digest_now] reads each gate against its artifact's digest now ({CLI::Epic})
          # @return [Array<Row>]
          def rows(progress, records, digests:)
            gates = gates_of(records, progress.graph, progress.epic_slug, digests)
            blockage = Lain::Epic::Blockage.of(progress.graph)
            [*stage_notes(progress.epic_slug, records, digests),
             *progress.graph.map { |issue| row(issue, gates.fetch(issue.id, ["-", "draft"]), blockage) }]
          end

          # The epic-wide stages are not issue rows, so a plan approved before it was split shows here.
          def stage_notes(slug, records, digests)
            signoff = Lain::Epic::Signoff.from_journal(records)
            (Lain::Epic::STAGES - Lain::Epic::ISSUE_STAGES).filter_map do |stage|
              partition = Lain::Epic::SignoffQueue::Partition.new(epic_slug: slug, stage:)
              standing = signoff.standing(partition)
              current = digests.digest_now(partition, standing) if standing
              said = Lain::CLI::Epic.unsubmitted_note(stage, signoff.view(partition, current:))
              Note.new(line: said) if said
            end
          end

          def row(issue, gate, blockage)
            Row.new(id: issue.id, title: issue.title, mark: Lain::Epic::Document::STATUS_MARKS.fetch(issue.status),
                    stage: gate.first, gate: gate.last,
                    blockers: issue.status == "pending" ? blockage.holding(issue.id) : [])
          end

          def gates_of(records, graph, slug, digests)
            signoff = Lain::Epic::Signoff.from_journal(records)
            queue = Lain::Epic::SignoffQueue.from_journal(records)
            gated = records.select { |record| GATE_TYPES.include?(record["type"]) && record["epic_slug"] == slug }
                           .select { |record| record["issue_id"] && record.fetch("kind", "gate") == "gate" }
            newest = gated.to_h { |record| [record["issue_id"], record] }.slice(*graph.ids)
            newest.transform_values { |record| [record["stage"].to_s, state(record, signoff, queue, digests)] }
          end

          def state(record, signoff, queue, digests)
            return (record["deferred"] ? "parked" : "waiting") unless record["type"] == "gate_decision"

            partition = Lain::Epic::SignoffQueue::Partition.new(epic_slug: record["epic_slug"], stage: record["stage"],
                                                                issue_id: record["issue_id"])
            current = digests.digest_now(partition, signoff.standing(partition))
            phrase(signoff.view(partition, current:), held_note(queue, partition))
          end

          def phrase(view, held_note)
            case view.phase
            when :parked then "parked"
            when :held then "held: #{held_note}".strip
            when :approved then "approved"
            when :edited then "approved at other bytes"
            when :gone then "approved but its file is gone"
            when :denied then "denied: #{first_line(view.standing.verdict.note)}".strip
            else "waiting"
            end
          end

          def held_note(queue, partition)
            held = queue.held(partition.epic_slug, partition.stage, issue_id: partition.issue_id)
            first_line(held.find { |item| item.partition == partition }&.note)
          end

          def first_line(note) = note.to_s.lines.first.to_s.strip
        end

        # @param epic [#roadmap] {StatusView::Mounted}, or {StatusView::Unmounted}
        def initialize(epic: StatusView::Unmounted)
          @epic = epic
          @shown = nil
        end

        # @return [Array<String>]
        def initial = @shown = composed

        # @param event [Object] one Channel event
        # @return [Array<String>, nil] the whole buffer, or nil when nothing it shows moved
        def update(event)
          return nil unless REFOLD_TYPES.any? { |type| event.is_a?(type) }

          lines = composed
          return nil if lines == @shown

          @shown = lines
        end

        private

        def composed
          rows = @epic.roadmap
          return [] if rows.empty?

          ["# roadmap", "", *rows.map(&:line)]
        rescue StandardError => e
          ["# roadmap unavailable", "",
           "it failed with #{e.class}: #{Utf8.legible(e.message, "?").lines.first.to_s.strip}"]
        end
      end
    end
  end
end
