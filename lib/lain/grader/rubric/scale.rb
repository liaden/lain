# frozen_string_literal: true

module Lain
  module Grader
    class Rubric
      # The shape of the answer a {Rubric} asks its judge for: the prompt's first paragraph, how a
      # parsed reply becomes a 0..1 score, and the score at which a {Refuter} lets a finding survive.
      # The shapes are compared on labelled findings by {Bench::JudgeScale}; {Unit} is the one every
      # recorded verdict was made under, so its prompt and threshold must not move.
      class Scale
        NAMES = %i[unit binary three deduction].freeze

        VERDICT_REPLY = <<~PROMPT
          You are a strict grader. Decide whether the answer below satisfies the criteria.
          Reply with ONE JSON object and nothing else:
        PROMPT

        VERDICT_SHAPE = %({"verdict": %s, "why": "<one sentence explaining the verdict>"}\n)

        # @param name [Symbol, String] one of {NAMES}
        # @return [Scale]
        # @raise [ArgumentError] on a name outside {NAMES}
        def self.fetch(name)
          INSTANCES.fetch(name.to_sym) do
            raise ArgumentError, "unknown judge scale #{name.inspect}; one of #{NAMES.join(", ")}"
          end
        end

        # @return [String] the system prompt's first paragraph
        def instruction = raise(NotImplementedError, "#{self.class} must define #instruction")

        # @param verdict [Hash] the judge's parsed reply
        # @return [Float] a score in 0..1
        # @raise [Unparseable] on a reply shape this scale does not know
        def score(verdict) = raise(NotImplementedError, "#{self.class} must define #score")

        # @param verdict [Hash]
        # @return [String] the explanation the {Grade} requires
        def why(verdict) = verdict["why"].to_s

        # @return [Float] the score at or above which a {Refuter} lets a finding survive
        def survives_at = 1.0

        # @return [Boolean] whether the score is a probability, and so may be scored by Brier
        def probability? = false

        private

        def unparseable!(message) = raise(Unparseable, message)

        # The scale today's judge answers on: a number between 0 and 1.
        class Unit < Scale
          def instruction = INSTRUCTION

          # Passed through untouched so a malformed number fails in {Grade} as it always did.
          def score(verdict) = verdict.fetch("score", 0)

          def survives_at = 0.5

          def probability? = true
        end

        # A judge that must pick a word, never a number, so it cannot hedge at 0.5.
        class Binary < Scale
          WORDS = { "holds" => 1.0, "fails" => 0.0 }.freeze

          def instruction = "#{VERDICT_REPLY}#{VERDICT_SHAPE % '"holds" or "fails"'}"

          def score(verdict)
            words = self.class::WORDS
            words.fetch(verdict["verdict"]) do
              unparseable!("judge verdict must be one of #{words.keys.join(", ")}, got #{verdict["verdict"].inspect}")
            end
          end
        end

        # Binary plus a middle answer; only "holds" survives, so doubt refutes.
        class Three < Binary
          WORDS = { "holds" => 1.0, "unsure" => 0.5, "fails" => 0.0 }.freeze

          def instruction = "#{VERDICT_REPLY}#{VERDICT_SHAPE % '"holds", "unsure" or "fails"'}"
        end

        # The judge lists defects instead of scoring; the score is arithmetic on the list.
        class Deduction < Scale
          PER_DEFECT = 0.25

          def instruction
            <<~PROMPT
              You are a strict grader. List every defect that keeps the answer below from satisfying the criteria.
              Reply with ONE JSON object and nothing else:
              {"defects": ["<one short defect>", ...], "why": "<one sentence summing up>"}
            PROMPT
          end

          def score(verdict) = [1.0 - (PER_DEFECT * defects(verdict).size), 0.0].max

          def why(verdict)
            named = defects(verdict)
            parts = [named.empty? ? nil : "defects: #{named.join("; ")}", verdict["why"].to_s]
            parts.compact_blank.join(" - ").then { |text| text.empty? ? "no defects named" : text }
          end

          # At most one defect.
          def survives_at = 0.75

          private

          def defects(verdict)
            list = verdict["defects"]
            unless list.is_a?(Array) && list.all? { _1.is_a?(String) && !Blankness.blank?(_1) }
              unparseable!("judge defects must be a list of non-blank strings, got #{list.inspect}")
            end
            if list.uniq.size < list.size
              unparseable!("judge defects must not repeat a defect, got #{list.inspect} (duplicate)")
            end

            list
          end
        end

        INSTANCES = { unit: Unit.new, binary: Binary.new, three: Three.new, deduction: Deduction.new }.freeze
        private_constant :INSTANCES
      end
    end
  end
end
