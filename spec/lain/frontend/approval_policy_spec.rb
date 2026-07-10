# frozen_string_literal: true

require "stringio"
require "lain/frontend/approval_policy"
require "lain/effect"

RSpec.describe Lain::Frontend::ApprovalPolicy do
  let(:output) { StringIO.new }
  let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { command: "rm -rf /tmp/x" }) }

  def policy_for(answer)
    described_class.new(output: output, input: StringIO.new(answer))
  end

  it "asks the question, naming the tool and its input" do
    policy_for("y\n").call(effect, nil)

    expect(output.string).to include("bash").and include("rm -rf /tmp/x")
  end

  %w[y yes Y YES Yes].each do |answer|
    it "approves on #{answer.inspect}" do
      expect(policy_for("#{answer}\n").call(effect, nil)).to be(true)
    end
  end

  %w[n no N garbage].each do |answer|
    it "denies on #{answer.inspect}" do
      expect(policy_for("#{answer}\n").call(effect, nil)).to be(false)
    end
  end

  it "denies on a bare newline (the default is refusal, not consent)" do
    expect(policy_for("\n").call(effect, nil)).to be(false)
  end

  it "denies on EOF rather than raising" do
    expect(policy_for("").call(effect, nil)).to be(false)
  end
end
