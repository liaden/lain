# frozen_string_literal: true

RSpec.describe Lain::Provider::HTTP::Connection::MiddlewareStack do
  let(:url) { "https://api.anthropic.com/v1/messages" }
  let(:seen) { [] }
  let(:recorder) do
    log = seen
    Class.new(Faraday::Middleware) do
      define_method(:call) do |env|
        log << env.body.class
        @app.call(env)
      end
    end
  end

  def build_connection(http_middleware:, max_retries: 0)
    config = zero_retry_config(max_retries:)
    config.anthropic_api_key = "sk-ant-test"
    config.http_middleware = http_middleware
    provider = Lain::Provider::HTTP::Providers::Anthropic.new(config)
    Lain::Provider::HTTP::Connection.new(provider, config)
  end

  it "runs entries around every retry attempt" do
    stub_request(:post, url).to_return({ status: 503 }, { status: 503 },
                                       { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } })

    build_connection(http_middleware: [[recorder, {}]], max_retries: 2).post("/v1/messages", { a: 1 })

    expect(seen.size).to eq(3)
  end

  it "sends a usage-quota 429 once, however many retries are allowed" do
    stub_request(:post, url).to_return(status: 429, body: { error: { message: "session usage limit reached" } }.to_json,
                                       headers: { "Content-Type" => "application/json" })

    expect { build_connection(http_middleware: [], max_retries: 2).post("/v1/messages", { a: 1 }) }
      .to raise_error(Lain::Provider::HTTP::QuotaError, /usage limit/)
    expect(a_request(:post, url)).to have_been_made.once
  end

  it "retries a per-minute rate limit and completes" do
    limited = { status: 429, body: { error: { message: "rate limit: input tokens per minute" } }.to_json,
                headers: { "Content-Type" => "application/json" } }
    stub_request(:post, url).to_return(limited,
                                       { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } })

    build_connection(http_middleware: [], max_retries: 2).post("/v1/messages", { a: 1 })

    expect(a_request(:post, url)).to have_been_made.twice
  end

  it "shows entries the body before JSON encoding" do
    stub_request(:post, url).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

    build_connection(http_middleware: [[recorder, {}]]).post("/v1/messages", { a: 1 })

    expect(seen).to eq([Hash])
  end

  it "shows an entry appended after another the body before JSON encoding too" do
    stub_request(:post, url).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    ahead = Class.new(Faraday::Middleware)

    build_connection(http_middleware: [[ahead, {}], [recorder, {}]]).post("/v1/messages", { a: 1 })

    expect(seen).to eq([Hash])
  end

  it "builds the stack from today's handlers when there are no entries" do
    handlers = build_connection(http_middleware: []).connection.builder.handlers.map(&:name)

    expect(handlers).to eq(
      %w[Faraday::Response::Logger Faraday::Retry::Middleware
         Lain::Provider::HTTP::Connection::MiddlewareStack::StallProtection
         Faraday::Request::Json Faraday::Response::Json
         Lain::Provider::Anthropic::WalResponseTee Lain::Provider::HTTP::ErrorMiddleware]
    )
  end

  it "builds when the config does not respond to http_middleware" do
    config = instance_double(Lain::Provider::HTTP::Configuration,
                             request_timeout: 5, log_regexp_timeout: nil, max_retries: 0, retry_interval: 0,
                             retry_interval_randomness: 0, retry_backoff_factor: 0, retry_block: nil,
                             exhausted_retries_block: nil, rate_limit_reset_header: nil, header_parser_block: nil,
                             http_proxy: nil)
    provider = instance_double(Lain::Provider::HTTP::Provider, api_base: "https://example.test")

    expect(described_class.new(provider, config, sink: Lain::Sink::Null.new, log_level: :info).build)
      .to be_a(Faraday::Connection)
  end
end
