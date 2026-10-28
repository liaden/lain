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
                        prompt_tokens: 12_011, window_tokens: 2048, stands_on: "blake3:below", **overrides)
  end

  # The turn the refused count is believed on, so a live view reading the
  # record tags it exactly as the Agent does. nil is the empty chain, which
  # every chain extends, and is a value rather than an absence.
  it "carries the turn the refused count stands on, nil for the empty chain" do
    expect(pressure.stands_on).to eq("blake3:below")
    expect(pressure(stands_on: nil).stands_on).to be_nil
    expect(JSON.parse(JSON.generate(pressure(stands_on: nil).to_journal))).to include("stands_on" => nil)
  end

  # Whose prompt it was. The run's own ask names no spawn, and a child's names
  # the one it was spawned as, so a reader folding these into a run's reading
  # can tell a count taken against this chain's window from one taken against a
  # child's -- without inferring it from which journal the record arrived on.
  it "names the spawn whose prompt was refused, and nobody for the run's own ask" do
    expect(pressure.spawn).to be_nil
    expect(pressure(spawn: "diff_critic").spawn).to eq("diff_critic")
    expect(pressure(spawn: "diff_critic").to_journal).to include("spawn" => "diff_critic")
  end

  it "refuses a record that does not say what the count stands on" do
    expect do
      described_class.new(kind: :over_window, source: "ollama", model: "qwen3:4b", request_digest: "blake3:abc",
                          prompt_tokens: 12_011, window_tokens: 2048)
    end.to raise_error(ArgumentError, /stands_on/)
  end

  it "carries the provider's exact prompt count, its context size, and who said so" do
    expect(pressure).to have_attributes(kind: :over_window, source: "ollama", model: "qwen3:4b",
                                        request_digest: "blake3:abc", prompt_tokens: 12_011, window_tokens: 2048)
  end

  it "is a frozen, Ractor-shareable value with structural equality" do
    twin = pressure(source: +"ollama", model: +"qwen3:4b", request_digest: +"blake3:abc")

    expect(pressure).to eq(twin)
    expect(pressure).to be_deeply_frozen
    expect(pressure).to be_deeply_frozen
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

  describe "journal bytes" do
    it "journals every field" do
      expect(JSON.generate(pressure(model: "qwen3:4b", spawn: "sp1").to_journal)).to eq(
        '{"type":"window_pressure","kind":"over_window","source":"ollama","model":"qwen3:4b",' \
        '"request_digest":"blake3:abc","prompt_tokens":12011,"window_tokens":2048,"stands_on":"blake3:below",' \
        '"spawn":"sp1"}'
      )
    end

    it "journals an absent spawn and a nil model as null" do
      expected = '{"type":"window_pressure","kind":"over_window","source":"ollama","model":null,' \
                 '"request_digest":"blake3:abc","prompt_tokens":12011,"window_tokens":2048,"stands_on":null,' \
                 '"spawn":null}'
      expect(JSON.generate(pressure(stands_on: nil, model: nil).to_journal)).to eq(expected)
      expect(JSON.generate(pressure(stands_on: nil, model: nil, spawn: nil).to_journal)).to eq(expected)
    end

    it "interns every name across equal records" do
      first = pressure(source: +"ollama", model: +"m", request_digest: +"blake3:abc", stands_on: +"blake3:below",
                       spawn: +"sp1")
      second = pressure(source: +"ollama", model: +"m", request_digest: +"blake3:abc", stands_on: +"blake3:below",
                        spawn: +"sp1")
      %i[source model request_digest stands_on spawn].each do |field|
        expect(first.public_send(field)).to equal(second.public_send(field))
      end
    end

    it "refuses a keyword it does not declare" do
      expect { pressure(stray: 1) }.to raise_error(ArgumentError, /stray/)
    end
  end

  describe "blank names" do
    it "refuses source given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect do
          pressure(source: blank)
        end.to raise_error(ArgumentError, /source must name the provider that refused the prompt/)
      end
    end

    it "refuses request_digest given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect do
          pressure(request_digest: blank)
        end.to raise_error(ArgumentError,
                           /request_digest must name the request that was refused/)
      end
    end
  end

  describe "post-settle conversions" do
    it "journals numeric-string token counts as Integers" do
      record = pressure(prompt_tokens: "9000", window_tokens: "2048")
      expect([record.prompt_tokens, record.window_tokens]).to eq([9000, 2048])
    end
  end
end
