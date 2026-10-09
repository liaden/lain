# frozen_string_literal: true

module Lain
  module Isolation
    # How a landing judges a {Candidate} before its branch moves. A strategy is
    # chosen by the `isolation` table's `verifier` name, and every strategy
    # answers `call(candidate)` with a {LandingQueue::Verification}, so one
    # substitutes for another without its caller knowing which it holds.
    module Verifier
      STRATEGIES = {
        "command" => lambda do |isolation, paths:, shell_out_factory:|
          return Skipped if isolation.verify.empty?

          Command.new(isolation.verify, timeout: isolation.verify_timeout, lock: SuiteLock.for(paths:),
                                        shell_out_factory:)
        end
      }.freeze

      # @param isolation [Config::Isolation] names the strategy and its settings
      # @param paths [Lain::Paths] where the suite lock lives
      # @param shell_out_factory [#call] builds the subprocess runner
      # @param strategies [Hash{String=>#call}] strategy builders by name
      # @return [#call] `call(candidate)` answering a {LandingQueue::Verification}
      # @raise [KeyError] for a strategy name no builder is registered under
      # @raise [Paths::Unwritable] when the suite lock's directory cannot be made
      def self.from(isolation, paths:, shell_out_factory: Shell::Out.public_method(:new), strategies: STRATEGIES)
        strategies.fetch(isolation.verifier).call(isolation, paths:, shell_out_factory:)
      end
    end
  end
end
