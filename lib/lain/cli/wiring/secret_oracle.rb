# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What `--secret-oracle` builds: no oracle, the local judge, or the cloud
      # judge behind a lain gateway. Its provider is chosen by {Oracle::SecretRead},
      # never by `--provider` or `--summarizer-provider`, and it carries the same
      # egress guard as the run's own providers, holding for the human under
      # `--supervise-egress oracle` or `all`.
      class SecretOracle
        MODES = %w[off local cloud].freeze
        UNKNOWN = "unknown --secret-oracle %<mode>p, expected off, local or cloud"
        NO_GATEWAY = "--secret-oracle cloud asks its model only through a lain gateway: start " \
                     "`lain gateway --upstream URL` and pass the URL it prints as --gateway"
        NO_MODEL = "--secret-oracle cloud needs --secret-oracle-model, a model the gateway's upstream serves"
        STRAY_GATEWAY = "--gateway is read only under --secret-oracle cloud, not %<mode>s"
        STRAY_MODEL = "--secret-oracle-model is read only under --secret-oracle local or cloud, not off"

        # Refused here, at construction, so a bad flag stops the launch before
        # a terminal opens or a model is asked. The gateway itself is proven
        # later, in {#tier}, after the terminal is up.
        #
        # @param options [Hash] the parsed CLI options
        # @option options [String] :secret_oracle one of {MODES}; nil is off
        # @option options [String] :secret_oracle_model the judge's model
        # @option options [String] :gateway http://127.0.0.1:<port>, the URL `lain gateway` printed
        # @raise [Lain::Error] for a mode outside {MODES}, for cloud with no model, and for a
        #   --gateway or --secret-oracle-model the mode does not read
        # @raise [Oracle::SecretRead::NotAGateway] for cloud with a missing or off-loopback gateway
        def initialize(options)
          @mode = (options[:secret_oracle] || "off").to_s
          raise Error, format(UNKNOWN, mode: @mode) unless MODES.include?(@mode)

          @model = options[:secret_oracle_model]
          refuse_stray(options[:gateway])
          @link = cloud? ? gateway_link(options[:gateway]) : nil
        end

        # @return [Boolean]
        def on? = @mode != "off"

        # The cloud tier's gateway is proven here, so a listener that is not one
        # stops the launch, and again before every question.
        #
        # @param backend [Backend] the run's egress literals and hold, and the local judge's sampler options
        # @param journal [#<<] where the oracle's answers, round trips and guard records land
        # @return [Oracle::Recorded::Journaling]
        # @raise [Oracle::SecretRead::NotAGateway] when the gateway does not prove itself
        def tier(backend, journal)
          http_middleware = [guard(backend, journal)]
          return local_tier(backend, journal, http_middleware) unless cloud?

          @link.prove!(Oracle::SecretRead.gateway_path(@model))
          Oracle::SecretRead.cloud_tier(model: @model, gateway: @link, journal:, http_middleware:)
        end

        private

        def cloud? = @mode == "cloud"

        # A flag the mode ignores would read as though it did something.
        def refuse_stray(gateway)
          raise Error, format(STRAY_GATEWAY, mode: @mode) if !cloud? && !gateway.to_s.empty?
          raise Error, STRAY_MODEL if !on? && !@model.to_s.empty?
        end

        # The token is read from the gateway's token file, never from the URL.
        def gateway_link(url)
          raise Oracle::SecretRead::NotAGateway, NO_GATEWAY if url.to_s.empty?
          raise Error, NO_MODEL if @model.to_s.empty?

          Oracle::SecretRead::GatewayLink.from_url(url)
        end

        def guard(backend, journal)
          Provider::HTTP::EgressGuard.entry(literals: backend.egress_literals, journal:,
                                            hold: backend.egress_hold.for(Backend::EgressHold::ORACLE))
        end

        # The judge's model is named once here, so the options asked for and the
        # model they ride to cannot come to disagree.
        def local_tier(backend, journal, http_middleware)
          model = @model || Provider::Ollama::DEFAULT_MODEL
          options = backend.arm_tier_options(model, arm: Backend::OllamaTier::LOCAL)
          Oracle::SecretRead.tier(model:, journal:, options:, http_middleware:)
        end
      end
    end
  end
end
