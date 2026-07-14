# frozen_string_literal: true

# ModelCaller owns the model round trip and ITS middleware phase. These pin the
# env in/out contract that phase carries: the caller passes a plain hash, the
# Stack boundary wraps it into an Env, `:request` goes in and `:response` comes
# back out.
RSpec.describe Lain::Agent::ModelCaller do
  let(:response) do
    Lain::Response.new(content: [{ "type" => "text", "text" => "hi" }], stop_reason: :end_turn)
  end
  let(:provider) { Lain::Provider::Mock.new(responses: [response]) }
  # ModelCaller only fetches :request and hands it to the provider; the Mock
  # records it without inspecting its shape, so a bare marker suffices.
  let(:request) { :the_request }

  it "returns the provider's Response for the request" do
    expect(described_class.new(provider:).call(request)).to be(response)
  end

  it "hands the fetched request to the provider unchanged" do
    described_class.new(provider:).call(request)
    expect(provider.last_request).to eq(request)
  end

  it "wraps the caller's hash into an Env exposing :request in and :response out" do
    seen_in = nil
    seen_out = nil
    probe = Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        seen_in = env
        seen_out = downstream.call(env)
      end
    end.new
    stack = Lain::Middleware::Stack.new.use(probe)

    described_class.new(provider:, middleware: stack).call(request)

    expect(seen_in).to be_a(Lain::Middleware::Env)
    expect(seen_in.request).to eq(request)
    expect(seen_out.response).to be(response)
  end
end
