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
        # fields and each of its four per-arm blocks -- happens IN THIS
        # METHOD, inside the one `rescue KeyError`, so every shape of
        # malformed case gets the same named-and-located {MalformedCase}
        # rather than a bare, case-less `KeyError` surfacing later at score
        # time (the same reasoning {DisclosureSweep#build_task} documents).
        def build_case(raw_case)
          arm_blocks = %w[ollama haiku inline model_self_directed].to_h do |arm|
            [arm, validated_arm(raw_case, arm)]
          end
          { "id" => -raw_case.fetch("id").to_s, "age_turns" => Integer(raw_case.fetch("age_turns")),
            "content" => -raw_case.fetch("content").to_s, "gold_stale" => raw_case.fetch("gold_stale"),
            **arm_blocks }
        rescue KeyError => e
          raise MalformedCase,
                "decider fixture case #{raw_case["id"].inspect} at #{@path} is missing #{e.key.inspect}"
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
