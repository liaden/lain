# frozen_string_literal: true

module Lain
  class Arm
    # The fan-in half of the orchestrator-worker topology: folds N worker
    # outcomes into ONE synthesized turn on the lead's Timeline, writing the
    # FIRST multi-parent causal Event any arm has produced. The fold turn's
    # `causal_parents` name the worker result turns it folded (event.rb:37, "a
    # synthesis event names the N results it folded"); its single `render_parent`
    # is the lead, so the render/first-parent walk is untouched and only the
    # causal edge records the fan-in.
    #
    # PRICING REACHABILITY (arm.rb's REACHABILITY CONTRACT, at this grain). The
    # Ledger prices the turns REACHABLE from a Run's head, and reachability there
    # is RENDER ancestry ({Timeline#ancestors}) -- which a fresh-root worker's
    # turns are not on, however the synthesis names them causally. So the fold
    # RE-ATTRIBUTES each worker's spend onto the synthesis turn's digest, the one
    # reachable head, exactly the {Bench::DeciderSweep::Arms} accounting pattern
    # (usage keyed to the spine turn it prices through). The event still NAMES
    # every worker head (the causal record is intact), while every worker's
    # tokens price through the reachable fold turn -- so a Run over the returned
    # head sees ALL of them and never undercounts.
    class Synthesis
      # One worker's outcome. A FAILED worker is a named input, not an omission
      # (B8 escalation): its error is kept and folded, so a failure is visible in
      # the synthesis rather than silently dropped.
      Result = Data.define(:head_digest, :text, :error, :usage_records) do
        # @param head_digest [String] the worker's final turn, a valid causal parent
        # @param usage_records [Array<Hash>] the worker's journal turn_usage records
        def self.ok(head_digest:, text:, usage_records: [])
          new(head_digest:, text: text.to_s, error: nil, usage_records:)
        end

        # A worker that never settled: no head to name causally, its error kept.
        # Any partial spend it journaled before failing still rides `usage_records`.
        def self.failed(error:, usage_records: [])
          new(head_digest: nil, text: nil, error: error.to_s, usage_records:)
        end

        def failed? = !error.nil?
        def rendered = failed? ? "[failed] #{error}" : text
      end

      # The fold's product: the synthesized Timeline (its head reaches the fold
      # turn) and the journal entries a {Ledger} prices the workers through.
      Folded = Data.define(:timeline, :ledger_entries)

      # @param lead [Timeline] the orchestrator's Timeline; its Store must already
      #   hold every worker head (the workers ran over it), or {Timeline#commit}'s
      #   referential-integrity check raises when the causal edge dangles
      # @param results [Array<Result>] one per subtask, in subtask order
      # @return [Folded]
      def fold(lead, results)
        content = [{ "type" => "text", "text" => combined(results) }]
        timeline = lead.commit(role: :assistant, content:, causal_parents: causal_parents(results))
        Folded.new(timeline:, ledger_entries: reattributed(timeline.head_digest, results))
      end

      private

      # Only committed heads become causal edges. A worker that settled no turn
      # (a failure) has a nil head and is simply not a causal parent -- but a
      # NON-nil head the Store never saw is NOT dropped: it flows to
      # {Timeline#commit}, which raises {Store::MissingObject}, the fail-loud the
      # escalation trigger demands over silently discarding a dangling parent.
      def causal_parents(results) = results.filter_map(&:head_digest)

      def combined(results)
        results.each_with_index.map { |result, index| "worker #{index + 1}: #{result.rendered}" }.join("\n\n")
      end

      # Re-key every worker turn_usage onto the reachable fold turn, but keep the
      # record HONEST: a bare re-key would claim the no-model-call synthesis turn
      # incurred N native payments and lose which worker spent what. So the moved
      # `"digest"` (the Ledger join) rides alongside `"reattributed" => true` and
      # `"attributed_from" => <worker head>`, so an auditor recovers per-worker
      # spend and tells re-attributed usage apart from native. Each keeps its own
      # model, so per-worker/per-model cost still prices; non-usage records pass
      # through untouched (they carry no digest join).
      def reattributed(digest, results)
        results.flat_map do |result|
          result.usage_records.map { |record| relabel(record, onto: digest, from: result.head_digest) }
        end
      end

      def relabel(record, onto:, from:)
        return record unless record["type"] == "turn_usage"

        record.merge("digest" => onto, "reattributed" => true, "attributed_from" => from)
      end
    end
  end
end
