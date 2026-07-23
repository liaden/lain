# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::Command::Model do
  subject(:model) { described_class.new }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:switch) { Lain::Context::ModelSwitch.new("claude-opus-4-8", journal:) }
  let(:env) { instance_double(Lain::CLI::Command::Env, model_switch: switch) }

  def switches
    Lain::Journal.records(journal_io.string.lines, type: "model_switch").to_a
  end

  it "registers as /model with a one-line usage" do
    expect(model.name).to eq("model")
    expect(model.usage).to include("/model")
  end

  describe "/model <id>" do
    it "switches the slot the next render reads" do
      model.call("claude-haiku-4-5", env)
      expect(switch.current).to eq("claude-haiku-4-5")
    end

    it "returns rendered text naming both models, never printing" do
      text = nil
      expect { text = model.call("claude-haiku-4-5", env) }.not_to output.to_stdout
      expect(text).to include("claude-opus-4-8").and include("claude-haiku-4-5")
    end

    it "journals the change" do
      model.call("claude-haiku-4-5", env)
      expect(switches).to contain_exactly(
        a_hash_including("from" => "claude-opus-4-8", "to" => "claude-haiku-4-5", "surface" => "tty")
      )
    end

    it "passes an unknown id VERBATIM -- dispatch fails loudly, never a silent fallback" do
      model.call("totally-bogus-model", env)
      expect(switch.current).to eq("totally-bogus-model")
    end

    it "strips the surrounding whitespace the invocation grammar leaves" do
      model.call("  claude-haiku-4-5  ", env)
      expect(switch.current).to eq("claude-haiku-4-5")
    end
  end

  describe "bare /model" do
    it "reports the model in force without switching or journaling" do
      expect(model.call("", env)).to include("claude-opus-4-8")
      expect(switch.current).to eq("claude-opus-4-8")
      expect(switches).to be_empty
    end
  end
end
