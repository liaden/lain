# frozen_string_literal: true

require "json"

# The record a prompt leaves when its provider refused it for not fitting the
# context. The EMITTER is {Lain::Middleware::RequestBudget} and is spec'd there;
# what is asserted here is the VALUE -- the provider's exact figures, where they
# came from, and the refusals that keep a record from claiming a measurement it
# does not carry.
RSpec.describe Lain::Telemetry::WindowPressure do
  def pressure(**overrides)
    described_class.new(kind: :over_window, source: "ollama", model: "qwen3:4b", request_digest: "blake3:abc",
                        prompt_tokens: 12_011, window_tokens: 2048, **overrides)
  end

  it "carries the provider's exact prompt count, its context size, and who said so" do
    expect(pressure).to have_attributes(kind: :over_window, source: "ollama", model: "qwen3:4b",
                                        request_digest: "blake3:abc", prompt_tokens: 12_011, window_tokens: 2048)
  end

  it "is a frozen, Ractor-shareable value with structural equality" do
    twin = pressure(source: +"ollama", model: +"qwen3:4b", request_digest: +"blake3:abc")

    expect(pressure).to eq(twin)
    expect(pressure).to be_deeply_frozen
    expect(Ractor.shareable?(pressure)).to be(true)
  end

  it "accepts a kind spelled as a String, as a replayed record spells it" do
    expect(pressure(kind: "over_window").kind).to eq(:over_window)
  end

  describe "#to_journal" do
    it "tags itself window_pressure and round-trips through JSON" do
      line = JSON.parse(JSON.generate(pressure.to_journal))

      expect(line).to include("type" => "window_pressure", "kind" => "over_window", "source" => "ollama",
                              "request_digest" => "blake3:abc", "prompt_tokens" => 12_011, "window_tokens" => 2048)
    end
  end

  describe "refusals" do
    it "refuses a kind outside the closed set" do
      expect { pressure(kind: :truncated) }.to raise_error(ArgumentError, /kind must be/)
    end

    it "refuses a record that cannot name the request it describes" do
      expect { pressure(request_digest: nil) }.to raise_error(ArgumentError, /request_digest must name/)
    end

    it "refuses a record that cannot say who refused the prompt" do
      expect { pressure(source: nil) }.to raise_error(ArgumentError, /source must name/)
    end

    it "refuses a prompt count that is not one" do
      expect { pressure(prompt_tokens: nil) }.to raise_error(ArgumentError, /prompt_tokens must be/)
    end

    it "refuses a context size that could not have refused anything" do
      expect { pressure(window_tokens: 0) }.to raise_error(ArgumentError, /window_tokens must be/)
    end
  end
end
