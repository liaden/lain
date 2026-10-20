# frozen_string_literal: true

module Spike
  ABSTAIN = Ractor.make_shareable(Object.new.tap { |o| o.define_singleton_method(:inspect) { "ABSTAIN" } })

  Fault = Data.define(:rung, :error, :message)

  # decision nil means nobody decided; by names the LEAF rung that decided.
  Outcome = Data.define(:decision, :by, :faults) do
    def decided? = !decision.nil?
    def faulted? = !faults.empty?
    def allow? = decided? && decision.allow?
    def deny? = decided? && decision.deny?
  end

  # First decisive rung wins. Faults are carried in the value, never reported
  # from inside, so a nested ladder cannot lose them. Poisoning is NOT here.
  Ladder = Data.define(:rungs, :names) do
    def self.[](*rungs) = new(rungs: rungs)

    def initialize(rungs: [], names: nil)
      rungs = rungs.to_a.freeze
      super(rungs:, names: (names || rungs.map { -(_1.respond_to?(:name) ? _1.name.to_s : _1.class.name) }).freeze)
    end

    def call(input)
      faults = []
      hit = rungs.zip(names).lazy.filter_map { |rung, name| consult(rung, name, input, faults) }.first
      Outcome.new(decision: hit&.first, by: hit&.last, faults: faults.freeze)
    end

    def name = "ladder"

    private

    def consult(rung, name, input, faults)
      answer = rung.call(input)
      case answer
      when Outcome
        faults.concat(answer.faults)
        [answer.decision, answer.by] if answer.decided?
      when ABSTAIN, nil then nil
      else [answer, name]
      end
    rescue StandardError => e
      faults << Fault.new(rung: name, error: e.class.name, message: e.message)
      nil
    end
  end

  # Edge projection: an allow reached over a fault becomes "nobody decided",
  # unless exempt (Escalation's human authority). Apply ONCE, outermost.
  Poisoning = Data.define(:ladder, :exempt) do
    NEVER = Ractor.make_shareable(->(_decision) { false })
    def initialize(ladder:, exempt: NEVER) = super

    def call(input)
      outcome = ladder.call(input)
      return outcome unless outcome.faulted? && outcome.allow? && !exempt.call(outcome.decision)

      outcome.with(decision: nil, by: outcome.faults.first.rung)
    end

    def name = "poisoning"
  end
end
