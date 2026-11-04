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
        #   @return [String] draft, waiting, parked, approved, or held or denied with its note's first line
        Row = Data.define(:id, :title, :mark, :stage, :gate, :blockers) do
          def line
            held = blockers.empty? ? "" : " (blocked by #{blockers.map { |id| "`#{id}`" }.join(", ")})"
            "[#{mark}] `#{id}` #{title} -- #{stage}, #{gate}#{held}"
          end
        end

        # A gate's stage is whichever of its records came last, and a wait
        # reopens it: a deferred wait is the one written after the denial that
        # closed the gate, so it reads as parked, as `lain epic status` counts
        # it. What a decision left is the sign-off queue's answer for that
        # issue, so this row and every other reader agree.
        module Roadmap
          GATE_TYPES = %w[gate_decision awaiting_human].freeze

          module_function

          # @param progress [Lain::Epic::Progress]
          # @param records [Enumerable<Hash>] journal records, oldest first
          # @return [Array<Row>]
          def rows(progress, records)
            gates = gates_of(records, progress.epic_slug)
            blockage = Lain::Epic::Blockage.of(progress.graph)
            progress.graph.map { |issue| row(issue, gates.fetch(issue.id, ["-", "draft"]), blockage) }
          end

          def row(issue, gate, blockage)
            Row.new(id: issue.id, title: issue.title, mark: Lain::Epic::Document::STATUS_MARKS.fetch(issue.status),
                    stage: gate.first, gate: gate.last,
                    blockers: issue.status == "pending" ? blockage.holding(issue.id) : [])
          end

          def gates_of(records, slug)
            queue = Lain::Epic::SignoffQueue.from_journal(records)
            records.select { |record| GATE_TYPES.include?(record["type"]) && record["epic_slug"] == slug }
                   .select { |record| record["issue_id"] && record.fetch("kind", "gate") == "gate" }
                   .to_h { |record| [record["issue_id"], [record["stage"].to_s, state(record, queue)]] }
          end

          def state(record, queue)
            return (record["deferred"] ? "parked" : "waiting") unless record["type"] == "gate_decision"

            decided(Lain::Epic::SignoffQueue::Partition.new(epic_slug: record["epic_slug"], stage: record["stage"],
                                                            issue_id: record["issue_id"]),
                    record["artifact_digest"].to_s, queue)
          end

          def decided(partition, digest, queue)
            address = [partition.epic_slug, partition.stage]
            issue_id = partition.issue_id
            held = queue.held(*address, issue_id:).find { |item| exact?(item, partition, digest) }
            return "held: #{first_line(held.note)}".strip if held
            return "parked" if queue.parked(*address, issue_id:).any? { |item| exact?(item, partition, digest) }

            settled(queue.standing(*address, issue_id:))
          end

          def settled(standing)
            return "waiting" if standing.nil?
            return "approved" if standing.verdict.approved?

            "denied: #{first_line(standing.verdict.note)}".strip
          end

          def exact?(item, partition, digest) = item.partition == partition && item.artifact_digest == digest

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
