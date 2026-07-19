# frozen_string_literal: true

require "async"

module Lain
  module Bench
    class DeciderSweep
      # Builds each arm's own {Compare::Run}: its {Oracle} tier, its
      # {Timeline} (own {Store}, per {DeciderSweep}'s Isolation section), the
      # {Ledger} entries its usage prices through, and the {Grader::Fixture}
      # grade its verdicts earn against the fixture's gold. {DeciderSweep}
      # itself only ranks and renders what this collaborator produces.
      class Arms
        # Only `inline` and `model_self_directed` inherit the fixture's
        # `base_conversation` -- see {DeciderSweep}'s Isolation section.
        TAIL_WARMING_ARMS = %w[inline model_self_directed].freeze
        private_constant :TAIL_WARMING_ARMS

        # @param fixture [DeciderSweep::Fixture]
        # @param price_book [Lain::PriceBook]
        def initialize(fixture:, price_book:)
          @fixture = fixture
          @price_book = price_book
        end

        # @param arm [String] one of {DeciderSweep::ARMS}
        # @return [Compare::Run]
        def run_for(arm)
          arm_build = built.fetch(arm)
          Compare::Run.from_timeline(
            name: arm, timeline: arm_build.fetch(:timeline), ledger: arm_build.fetch(:ledger),
            grade: grade_for(arm, arm_build.fetch(:verdicts)), degraded: Capability::DegradedSet.new([])
          )
        end

        # @return [Hash{String=>Lain::Timeline}]
        def timelines
          built.transform_values { |arm_build| arm_build.fetch(:timeline) }
        end

        # @param arm [String]
        # @return [Array<Float>] the fixture's recorded wall_clock values for
        #   this arm, one per case that carries one -- empty for an arm never
        #   live-timed (heuristic/inline/model_self_directed).
        def wall_clock_samples(arm)
          @fixture.cases.filter_map { |kase| kase.dig(arm, "wall_clock") }
        end

        private

        # Every arm built ONCE, memoized together: the Timeline, its Ledger,
        # and the verdicts collected while building it all come from the SAME
        # pass over the fixture, so a Ledger entry's digest can never drift
        # from the Timeline it prices.
        def built
          @built ||= DeciderSweep::ARMS.to_h { |arm| [arm, build_for(arm)] }
        end

        def build_for(arm)
          tier = tier_for(arm)
          state = { timeline: base_timeline(arm), ledger_entries: [], verdicts: {} }
          @fixture.cases.each { |kase| apply_case(state, tier, arm, kase) }
          { timeline: state.fetch(:timeline),
            ledger: Ledger.from_journal(state.fetch(:ledger_entries), price_book: @price_book),
            verdicts: state.fetch(:verdicts) }
        end

        # Mutates `state` in place -- an ordinary fold accumulator, not a
        # value object: {#build_for} owns its lifetime start to finish, and
        # nothing outside that one method ever sees it. Extracted purely to
        # keep build_for's own branching within the Metrics budget.
        def apply_case(state, tier, arm, kase)
          typed = ask(tier, kase)
          state.fetch(:verdicts)[kase.fetch("id")] = typed.stale
          state[:timeline] = commit_case(state.fetch(:timeline), arm, kase, typed)
          usage = arm_usage(arm, kase)
          return unless usage

          digest = state.fetch(:timeline).head_digest
          state.fetch(:ledger_entries) << turn_usage_record(digest, model: model_for(arm, kase), usage:)
        end

        # {Oracle::Definition#answer} always hands back an ALREADY-resolved
        # {Promise} (its own doc), so `#await` never truly parks -- `Sync` is
        # the degenerate synchronous case that machinery falls out of, the
        # same shape {Oracle::Recorded}'s own spec awaits through.
        def ask(tier, kase)
          Sync { tier.ask(**oracle_inputs(kase)).await }
        end

        # {Oracle::PruneScoring::TEMPLATE} pulls both slots through
        # {Prompt::LockedBinding}'s `render` helper, which re-evaluates a
        # slot's VALUE as nested ERB source (that is how a partial composes)
        # -- so every slot value must be a String, never a raw Integer, or
        # ERB's own `ERB.new` breaks on `#encoding` before Purity ever gets a
        # look. `content` was always a String; `age_turns` was not, because
        # no existing spec had rendered this template before this sweep
        # (only the heuristic tier, which skips #render entirely, was
        # exercised).
        def oracle_inputs(kase)
          { age_turns: kase.fetch("age_turns").to_s, content: kase.fetch("content") }
        end

        def commit_case(timeline, arm, kase, typed)
          timeline
            .commit(role: :user, content: text("prune-scoring question (#{arm}): #{kase.fetch("content")}"))
            .commit(role: :assistant, content: text(typed.reason.to_s))
        end

        # heuristic runs live (real, zero-cost predicate); every other arm is
        # replayed through {Oracle::Recorded}, fed this sweep's OWN
        # manufactured recordings ({#oracle_answer_records}) -- never a live
        # provider, by default.
        def tier_for(arm)
          return Oracle::PruneScoring.heuristic(stale_after_turns: @fixture.stale_after_turns) if arm == "heuristic"

          definition = Oracle::PruneScoring.definition(tier: arm.to_sym)
          Oracle::Recorded.from_journal(oracle_answer_records(arm, definition), definition:)
        end

        # One manufactured {Telemetry::OracleAnswer} journal record per case,
        # keyed on the SAME definition {#tier_for} builds the replaying
        # {Oracle::Recorded} from -- so the `(oracle_digest, question)` join
        # always hits, whatever this oracle's template happens to render.
        def oracle_answer_records(arm, definition)
          @fixture.cases.map do |kase|
            spec = kase.fetch(arm)
            Telemetry::OracleAnswer.new(
              oracle_digest: definition.digest,
              question: definition.render(**oracle_inputs(kase)),
              answer: spec.fetch("answer"), model: spec["model"], usage: spec.fetch("usage", {}),
              wall_clock: spec["wall_clock"] || 0.0
            ).to_journal
          end
        end

        # Only `inline` and `model_self_directed` inherit the fixture's
        # `base_conversation`. Every arm gets a FRESH Store: nothing here is
        # shared across arms.
        def base_timeline(arm)
          fresh = Timeline.empty(store: Store.new)
          return fresh unless TAIL_WARMING_ARMS.include?(arm)

          @fixture.base_conversation.inject(fresh) do |timeline, msg|
            timeline.commit(role: msg.fetch("role").to_sym, content: text(msg.fetch("text")))
          end
        end

        def text(str) = [{ "type" => "text", "text" => str }]

        def arm_usage(arm, kase)
          return nil if arm == "heuristic"

          kase.fetch(arm).fetch("usage", {})
        end

        def model_for(arm, kase)
          return nil if arm == "heuristic"

          kase.fetch(arm)["model"] || @fixture.main_model
        end

        def turn_usage_record(digest, model:, usage:)
          { "type" => "turn_usage", "digest" => digest, "model" => model, "usage" => usage }
        end

        def grade_for(arm, verdicts)
          Grader::Fixture.new("decider sweep -- #{arm}") do |f|
            @fixture.cases.each do |kase|
              f.check("#{kase.fetch("id")} stale verdict matches gold") do |_|
                verdicts.fetch(kase.fetch("id")) == kase.fetch("gold_stale")
              end
            end
          end.grade(nil)
        end
      end
      private_constant :Arms
    end
  end
end
