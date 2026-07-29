# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    class DeciderSweep
      # Owns loading and validating the committed YAML: everything from
      # "read the file" to "every case's required fields are present" --
      # kept separate from arm-building/scoring/reporting (DeciderSweep
      # proper), the same single-responsibility split {Sweep::Embeddings}
      # draws around its own fixture concern.
      class Fixture
        # heuristic runs the real, live, zero-cost predicate ({DeciderSweep}'s
        # own header comment) -- it is the one arm that answers without a
        # recorded transcript, so it is the one arm this fixture's cases
        # never carry a block for.
        EXCLUDED_FROM_FIXTURE = %w[heuristic].freeze
        private_constant :EXCLUDED_FROM_FIXTURE

        def initialize(path)
          @path = path
        end

        def cases
          @cases ||= raw.fetch("cases").map { |raw_case| build_case(raw_case) }
        end

        def base_conversation
          @base_conversation ||= raw.fetch("base_conversation", [])
        end

        def stale_after_turns
          @stale_after_turns ||= Integer(raw.fetch("stale_after_turns"))
        end

        def main_model
          @main_model ||= raw.fetch("main_model")
        end

        private

        def raw
          @raw ||= YAML.safe_load_file(existing!)
        end

        # Every `#fetch` a malformed case could trip -- its own top-level
        # fields and each of its per-arm blocks -- happens IN THIS METHOD,
        # inside the one `rescue KeyError`, so every shape of malformed case
        # gets the same named-and-located {MalformedCase} rather than a bare,
        # case-less `KeyError` surfacing later at score time (the same
        # reasoning {DisclosureSweep#build_task} documents). The required-arm
        # list is DERIVED from {ARMS} (minus {EXCLUDED_FROM_FIXTURE}), never
        # a second hand-maintained literal -- so an arm {ARMS} gains is
        # required here for free, and a case missing its block raises this
        # same {MalformedCase} at load, not a bare `KeyError` at replay.
        def build_case(raw_case)
          { "id" => -raw_case.fetch("id").to_s, "age_turns" => Integer(raw_case.fetch("age_turns")),
            "content" => -raw_case.fetch("content").to_s, "gold_stale" => raw_case.fetch("gold_stale"),
            **arm_blocks(raw_case) }
        rescue KeyError => e
          raise MalformedCase,
                "decider fixture case #{raw_case["id"].inspect} at #{@path} is missing #{e.key.inspect}"
        end

        # Split out of {#build_case} to keep its own ABC size within the
        # Metrics budget (CLAUDE.md: never loosen the limit) -- the required
        # arm list stays DERIVED from {ARMS} (minus {EXCLUDED_FROM_FIXTURE}),
        # never a second hand-maintained literal, so an arm {ARMS} gains is
        # required here for free.
        def arm_blocks(raw_case)
          (ARMS - EXCLUDED_FROM_FIXTURE).to_h { |arm| [arm, validated_arm(raw_case, arm)] }
        end

        # `answer` is the one field every downstream use of an arm block
        # requires (DeciderSweep#oracle_answer_records); `usage`/`model`/
        # `wall_clock` all carry defaults there, so only `answer`'s absence
        # must raise HERE, inside {#build_case}'s one rescue, rather than
        # surfacing as a bare KeyError later at replay time.
        def validated_arm(raw_case, arm)
          spec = raw_case.fetch(arm)
          spec.fetch("answer")
          spec
        end

        def existing!
          raise MissingFixture, "no decider sweep fixture at #{@path}" unless File.file?(@path)

          @path
        end
      end
      private_constant :Fixture
    end
  end
end
