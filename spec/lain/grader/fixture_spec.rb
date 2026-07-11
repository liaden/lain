# frozen_string_literal: true

require "lain/grader/fixture"

require "lain/bench/dry_replay"
require "lain/context"
require "lain/toolset"

# A Grader::Fixture is a deterministic task: a named bundle of HARD assertions
# over some subject, scored pass/fail with no model in the loop. Its verdict is
# a pure function of the subject, so scoring the same subject twice is the same
# Grade -- which is what lets Compare treat a fixture score as a real metric and
# speculative branching argmax over it.
RSpec.describe Lain::Grader::Fixture do
  # A tiny subject so the fixture's own behavior is visible without dragging a
  # whole run in.
  subject_struct = Struct.new(:steps, :identical)

  def fixture
    described_class.new("byte-stable replay") do |f|
      f.check("reconstructs two model calls") { |s| s.steps == 2 }
      f.check("replays byte-identically", &:identical)
    end
  end

  it "scores 1.0 and passes when every criterion holds" do
    grade = fixture.grade(subject_struct.new(2, true))

    expect(grade.score).to eq(1.0)
    expect(grade).to be_pass
  end

  it "scores the fraction met and fails when any criterion misses" do
    grade = fixture.grade(subject_struct.new(2, false))

    expect(grade.score).to eq(0.5)
    expect(grade).not_to be_pass
  end

  it "explains itself: #why names each failing criterion" do
    grade = fixture.grade(subject_struct.new(3, false))

    expect(grade.why).to include("replays byte-identically")
    expect(grade.why).to include("reconstructs two model calls")
  end

  it "is deterministic: the same subject scores the same Grade twice" do
    subject = subject_struct.new(2, true)
    expect(fixture.grade(subject)).to eq(fixture.grade(subject))
  end

  it "counts a criterion that raises as a failure rather than crashing" do
    exploding = described_class.new("boom") do |f|
      f.check("touches a missing method", &:no_such_method)
    end

    grade = exploding.grade(subject_struct.new(1, true))
    expect(grade).not_to be_pass
    expect(grade.why).to match(/NoMethodError|boom|touches a missing method/)
  end

  describe "over a real DryReplay output" do
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

    let(:dry_replay) do
      agent, provider = record_run([tool_response(["t1", "echo", { "text" => "hi" }]), text_response("ok")],
                                   toolset: toolset, context: context, prompt: "echo hi")
      Lain::Bench::DryReplay.new(timeline: agent.timeline, baseline: provider.requests, toolset: toolset)
    end

    it "asserts byte-identity under the recording's own Context" do
      grade = described_class.new("identity holds") do |f|
        f.check("byte-identical under identity") { |dr| dr.diff(context).identical? }
      end.grade(dry_replay)

      expect(grade).to be_pass
    end
  end
end
