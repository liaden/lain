# frozen_string_literal: true

module Lain
  module QA
    # Whether one rung's verdict on one criterion IS the answer, or whether a
    # stronger model has to look.
    #
    # Code rather than prose in a skill, because an escalation is spend and a
    # spend nobody can audit cannot be tuned: every {Decision} names the rule
    # that produced it, and the report carries that name. {RULES} is ordered and
    # the first match wins, so each rule reads as an exception to the ones below
    # it; the last one is unconditional, and every row answers over an empty
    # sample set, so no row rests on another having run first.
    #
    # == What each of the three inputs buys
    #
    # The tension is the user's. A weak model is cheap per call but a false
    # positive it hands an implementer costs a whole fix round, while climbing on
    # every doubt spends the strong model the ladder exists to save. So:
    #
    # - `strong` -- whether the RUNG's voice may settle a pass -- is what makes a
    #   unanimous pass evidence rather than agreement. Measured: one acceptance
    #   item was called correct by three cheap models unanimously and caught only
    #   by the fit ones.
    # - `risk` buys CORROBORATION and never a veto. One voice is not enough on a
    #   high-risk criterion; {MIN_CORROBORATION} agreeing voices are. An earlier
    #   cut escalated every high-risk criterion unconditionally, which spent every
    #   rung and then owed a manual pass -- the gate refusing to conclude on
    #   exactly the cards it exists for.
    # - `executed` is the model's claim about ITSELF, so it is believed on the
    #   same terms in both directions: a verdict-holding rung alone, or
    #   {MIN_CORROBORATION} executions agreeing. A cheap rung may no more file a
    #   blocker off one self-report than it may accept a pass off one.
    class Escalation
      # How many agreeing voices stand in for a voice declared fit: two, the
      # two, because one reply is not a measurement. A rung is ONE model, so these
      # are two samples of it and NOT two opinions -- what keeps a cheap unanimity
      # from passing is `no-strong-voice`, and this clause only stops a fit model
      # settling a high-risk criterion off a single roll. It is also what an
      # executed failure needs from a rung whose voice cannot settle a pass alone.
      MIN_CORROBORATION = 2

      # The mean confidence below which a unanimous pass is still not believed.
      DEFAULT_CONFIDENCE = 0.7

      # One rung's sample of one criterion.
      #
      # `executed` is whether the evidence is a command the rung ran and watched,
      # rather than something it read and inferred. Fitness to give a verdict is
      # NOT here: it is a fact about the rung, identical across one rung's whole
      # sample set, so a per-sample copy of it could represent sets no rung can
      # produce.
      Sample = Data.define(:verdict, :confidence, :executed) do
        # @param answer [Answer] one rung's reply, already read
        # @return [Sample]
        def self.of(answer)
          new(verdict: answer.verdict, confidence: answer.confidence, executed: answer.executed)
        end

        def initialize(verdict:, confidence:, executed: false)
          super(verdict: spelled(verdict), confidence: ranked(confidence), executed: executed == true)
        end

        def executed_fail? = executed && verdict == "fail"

        private

        # {Answer} is the one reader of a model's words and already settles an
        # unspelled verdict as `unverified`, so a sample's word came from there.
        # Normalising again here would be a second definition of "said nothing",
        # which is the hazard this namespace exists to hold at one.
        def spelled(verdict)
          word = verdict.to_s
          raise ArgumentError, "verdict #{word.inspect} is not one of #{VERDICTS.join("/")}" unless
            VERDICTS.include?(word)

          -word
        end

        # Clamped rather than refused, for the reason {Answer} states about a
        # self-reported rank: a model claiming 5 has said "as sure as I get".
        def ranked(confidence) = (Float(confidence, exception: false) || 0.0).clamp(0.0, 1.0)
      end

      # Everything one decision is made from, as one value: a rung's samples, the
      # criterion's risk, that rung's fitness to settle a pass, and the
      # confidence floor. Public because {RULES} is, and a row's predicate reads
      # this -- a row applied to it standalone must answer rather than raise.
      Judgement = Data.define(:samples, :risk, :strong, :floor) do
        def initialize(samples:, risk:, strong:, floor:)
          wrong = samples.grep_v(Sample).map(&:class).uniq
          raise ArgumentError, "a judgement's samples must all be samples, got #{wrong.join(", ")}" unless wrong.empty?

          super(samples: samples.dup.freeze, risk: -risk.to_s, strong: strong == true, floor: Float(floor))
        end

        # @return [Array<String>] the distinct verdicts, so `["pass"]` is unanimity
        def verdicts = samples.map(&:verdict).uniq

        def unanimously?(verdict) = verdicts == [verdict]

        def executed_fails = samples.count(&:executed_fail?)

        def corroborated? = samples.size >= MIN_CORROBORATION

        # Zero over no samples, so the row that reads it answers instead of
        # dividing by nothing.
        def mean_confidence = samples.empty? ? 0.0 : samples.sum(&:confidence) / samples.size
      end

      # One named rule: what it decides, what a report calls it, and the
      # predicate over a {Judgement}. It holds a callable, so it is a table row
      # rather than one of this namespace's frozen values.
      Rule = Data.define(:action, :name, :applies)

      # The ladder's whole policy, in the order it is tried. The QA skill's prose
      # is pinned to these names rather than restating them, so a rule renamed
      # here cannot go on reading the old way in a prompt.
      RULES = [
        Rule.new(action: :escalate, name: "nothing-asked", applies: ->(judged) { judged.samples.empty? }),
        Rule.new(action: :report, name: "executed-fail",
                 applies: ->(judged) { judged.strong && judged.executed_fails.positive? }),
        Rule.new(action: :report, name: "corroborated-executed-fail",
                 applies: ->(judged) { judged.executed_fails >= MIN_CORROBORATION }),
        Rule.new(action: :escalate, name: "risk-high-uncorroborated",
                 applies: ->(judged) { judged.risk == "high" && !judged.corroborated? }),
        Rule.new(action: :escalate, name: "unverified",
                 applies: ->(judged) { judged.verdicts.include?("unverified") }),
        Rule.new(action: :escalate, name: "disagreement", applies: ->(judged) { judged.verdicts.size > 1 }),
        Rule.new(action: :escalate, name: "unconfirmed-fail", applies: ->(judged) { judged.unanimously?("fail") }),
        Rule.new(action: :escalate, name: "no-strong-voice", applies: ->(judged) { !judged.strong }),
        Rule.new(action: :escalate, name: "low-confidence",
                 applies: ->(judged) { judged.mean_confidence < judged.floor }),
        Rule.new(action: :accept, name: "unanimous-pass", applies: ->(_judged) { true })
      ].freeze

      Decision = Data.define(:action, :rule) do
        # Interned HERE rather than in a factory, because `.new` and `#with` go
        # nowhere near one: a member left as the caller's String is reachable
        # mutable state, and a later mutation would follow the decision into the
        # report that quotes it.
        def initialize(action:, rule:)
          raise ArgumentError, "action #{action.inspect} is not one of #{Decision::ACTIONS.join("/")}" unless
            Decision::ACTIONS.include?(action)

          super(action:, rule: -rule.to_s)
        end

        def accept? = action == :accept

        def report? = action == :report

        def escalate? = action == :escalate

        def to_s = "#{action} (#{rule})"
      end

      # `action` is what the ladder does next; `rule` is the name a report
      # records, so one decision reads the same way wherever it is audited.
      #
      # Reopened for the trap a constant inside the `Data.define` block hits: it
      # would land on {Escalation} rather than here, and the one docstring YARD
      # keeps is the reopen's.
      class Decision
        # Closed, because the ladder branches on all three and a fourth would
        # fall through its `else` as a climb nobody asked for.
        ACTIONS = %i[accept report escalate].freeze
      end

      # How many samples a rung takes is the RUNG's, not this object's: one
      # value, on the thing that spends it.
      def initialize(confidence: DEFAULT_CONFIDENCE)
        @confidence = Float(confidence)
        freeze
      end

      # @param samples [Array<Sample>] every sample one rung took of one criterion
      # @param risk [String] the card's risk, one of {RISKS}
      # @param strong [Boolean] whether that rung's voice may settle a pass
      # @return [Decision]
      # @raise [ArgumentError] for a risk outside {RISKS}
      def call(samples, risk:, strong:)
        judged = Judgement.new(samples:, risk: known_risk(risk), strong:, floor: @confidence)
        rule = RULES.find { |candidate| candidate.applies.call(judged) }
        Decision.new(action: rule.action, rule: rule.name)
      end

      private

      def known_risk(risk)
        word = risk.to_s
        raise ArgumentError, "risk #{word.inspect} is not one of #{RISKS.join("/")}" unless RISKS.include?(word)

        -word
      end
    end
  end
end
