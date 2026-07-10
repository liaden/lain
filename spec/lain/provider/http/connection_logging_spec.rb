# frozen_string_literal: true

require "lain/provider/http"

# Adapted from ruby_llm 1.16.0 (2cf34b9), spec/ruby_llm/connection_logging_spec.rb.
# Upstream tests the Faraday `Response::Logger` built from a real `::Logger`
# (`RubyLLM.logger`), whose level toggles body logging. Leak site 1 replaces
# that with {Lain::Provider::HTTP::Logging::SinkLogger}, an injected
# `Lain::Sink` with no notion of a Ruby `Logger` level, so `Connection.new`
# now takes `log_level:` directly instead of reading a global. What upstream
# actually asserts survives unchanged: bodies are logged only at `:debug`,
# the configured Faraday adapter is honored, and (via `logging_regexp`,
# untouched by this port) base64/embeddings blobs are filtered before
# anything is logged.
RSpec.describe Lain::Provider::HTTP::Connection do
  describe "logging middleware configuration" do
    let(:provider) do
      instance_double(
        Lain::Provider::HTTP::Provider,
        api_base: "https://example.com",
        configured?: true,
        headers: {}
      )
    end

    let(:config) do
      instance_double(
        Lain::Provider::HTTP::Configuration,
        request_timeout: 300,
        max_retries: 3,
        retry_interval: 0.1,
        retry_interval_randomness: 0.5,
        retry_backoff_factor: 2,
        http_proxy: nil,
        log_regexp_timeout: 1.0,
        faraday_adapter: :net_http
      )
    end

    def logger_middleware(connection)
      handler = connection.builder.handlers.find { |h| h.klass == Faraday::Response::Logger }
      handler.build(->(_env) { Faraday::Response.new })
    end

    def bodies_option(connection)
      logger_middleware(connection).instance_variable_get(:@formatter).instance_variable_get(:@options)[:bodies]
    end

    it "disables body logging at the default log level" do
      connection = described_class.new(provider, config).connection

      expect(bodies_option(connection)).to be(false)
    end

    it "enables body logging at :debug" do
      connection = described_class.new(provider, config, log_level: :debug).connection

      expect(bodies_option(connection)).to be(true)
    end

    it "routes log lines to the injected Sink, never to a Logger or $stdout" do
      sink = Lain::Sink::Null.new
      connection = described_class.new(provider, config, sink: sink, log_level: :debug).connection
      formatter = logger_middleware(connection).instance_variable_get(:@formatter)
      logger = formatter.instance_variable_get(:@logger)

      expect(logger).to be_a(Lain::Provider::HTTP::Logging::SinkLogger)
      expect { logger.debug { "probe" } }.not_to raise_error
    end

    it "filters base64 and embeddings-shaped blobs before they would be logged" do
      sink_calls = []
      sink = Object.new
      sink.define_singleton_method(:puts) { |msg| sink_calls << msg }

      connection = described_class.new(provider, config, sink: sink, log_level: :debug).connection
      formatter = logger_middleware(connection).instance_variable_get(:@formatter)

      formatter.send(:log_body, "request", "A" * 120)
      formatter.send(:log_body, "request", (["0.123456"] * 20).join(", "))

      expect(sink_calls.join).to include("[BASE64 DATA]")
      expect(sink_calls.join).to include("[EMBEDDINGS ARRAY]")
    end

    it "uses the configured Faraday adapter" do
      allow(config).to receive(:faraday_adapter).and_return(:test)

      connection = described_class.new(provider, config).connection

      expect(connection.builder.adapter).to eq(Faraday::Adapter::Test)
    end
  end
end
