# frozen_string_literal: true

module Lain
  module Bench
    class OracleCalibration
      # Where the calibrated oracle comes from: a journal of its earlier answers, or the chat's own
      # secret-oracle wiring asked live, with every answer journaled so a recording can re-score it.
      module Source
        NEEDS_MODEL = "--oracle cloud needs --model, a model the gateway's upstream serves"

        # @param oracle [String] "local" or "cloud", the tier whose address the recording is read at
        # @param file [String] a journal of `oracle_answer` records
        # @return [Oracle::Recorded]
        def self.recorded(oracle, file)
          definition = Oracle::SecretRead.definition(tier: oracle == "cloud" ? :cloud : :model)
          Oracle::Recorded.from_journal(File.foreach(file), definition:)
        end

        # Yields the oracle built by {Lain::CLI::Wiring::SecretOracle}, so the judge is sampled, guarded and
        # gateway-proven exactly as in a chat. The journal is closed however the block ends.
        #
        # @param oracle [String] "local" or "cloud"
        # @param model [String, nil]
        # @param gateway [String, nil]
        # @param journal [String] where the answers land
        # @param state [Lain::Paths]
        # @yieldparam tier [#ask]
        # @return [Object] the block's value
        # @raise [CLI::Refusal] when a flag the tier needs is missing or does not belong
        def self.live(oracle:, model:, gateway:, journal:, state:)
          wiring = wiring_for(oracle, model, gateway)
          Journal.open(journal, paths: state) { |sink| Sync { yield wiring.tier(backend, sink) } }
        end

        # @param state [Lain::Paths]
        # @return [String] a timestamped file under the state home's `bench` directory
        def self.default_journal(state)
          stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
          File.join(state.state_home, "bench", "oracle-calibration-#{stamp}-#{Process.pid}.ndjson")
        end

        def self.wiring_for(oracle, model, gateway)
          if oracle == "cloud"
            raise CLI::Refusal, "--oracle cloud asks only through a lain gateway: pass --gateway" if gateway.to_s.empty?
            raise CLI::Refusal, NEEDS_MODEL if model.to_s.empty?
          elsif !gateway.to_s.empty?
            raise CLI::Refusal, "--gateway is read only with --oracle cloud"
          end

          Lain::CLI::Wiring::SecretOracle.new(secret_oracle: oracle, secret_oracle_model: model, gateway:)
        end

        # The smallest Backend the wiring asks for: no flags, so no supervision and no chat runner to share.
        # The bench calibrates the default configuration; it does not take the chat's ollama runner options
        # (num_ctx, num_batch, keep_alive from LAIN_PROVIDER, LAIN_NUM_CTX and the like).
        def self.backend = Lain::CLI::Backend.new({}, root: Dir.pwd).tap { _1.egress_literals.bind_env }

        private_class_method :wiring_for, :backend
      end
    end
  end
end
