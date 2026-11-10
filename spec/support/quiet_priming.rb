# frozen_string_literal: true

# Only an example tagged :primes starts the background `git` listings a wiring's `prime` begins, and each is
# joined before the example ends, so none outlives it.
module QuietPriming
  # Held on an object so the module carries no mutable state.
  class Ledger
    attr_writer :allowed

    def initialize(timeout: 5)
      @timeout = timeout
      @allowed = false
      @started = []
    end

    def allowed? = @allowed

    def started(thread) = @started << thread

    def join_started(label)
      @started.shift(@started.size).each { |thread| join(thread, label) }
    end

    private

    def join(thread, label)
      return if finished?(thread)

      thread.kill
      raise "a priming thread outlived #{@timeout}s in #{label}"
    end

    def finished?(thread)
      thread.join(@timeout)
    rescue StandardError
      true # a prime that raised is the example's own assertion, not a leak
    end
  end

  LEDGER = Ledger.new

  # Prepended, so the class's own `prime` is what runs when an example asks for it.
  module Prime
    def prime
      return self unless LEDGER.allowed?

      super.tap do
        unless instance_variable_defined?(:@priming)
          raise "#{self.class} no longer holds its priming thread in @priming"
        end

        LEDGER.started(@priming)
      end
    end
  end
end

Lain::Confine::MaskList.prepend(QuietPriming::Prime)
Lain::Sensitivity::HistoryLiterals.prepend(QuietPriming::Prime)

RSpec.configure do |config|
  config.before { QuietPriming::LEDGER.allowed = false }
  config.before(:each, :primes) { QuietPriming::LEDGER.allowed = true }
  config.after { |example| QuietPriming::LEDGER.join_started(example.full_description) }
end
