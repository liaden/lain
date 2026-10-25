# frozen_string_literal: true

RSpec.describe Lain::Agent::Progress do
  def call_turn(timeline, name, input, id)
    timeline.commit(role: :assistant,
                    content: [{ "type" => "tool_use", "id" => id, "name" => name, "input" => input }])
  end

  def result_turn(timeline, id, text)
    timeline.commit(role: :user, content: [{ "type" => "tool_result", "tool_use_id" => id, "content" => text }])
  end

  def run_steps(calls)
    start = CoreGraph.timeline.commit(role: :user, content: "go")
    calls.each_with_index.inject(start) do |timeline, ((name, input, text), i)|
      result_turn(call_turn(timeline, name, input, "tu_#{i}"), "tu_#{i}", text)
    end
  end

  it "defaults to 3 repeats and 8 stale steps" do
    expect(described_class::DEFAULT).to have_attributes(repeats: 3, stale_steps: 8)
  end

  it "is a frozen value" do
    expect(Ractor.shareable?(described_class::DEFAULT)).to be(true)
  end

  it "raises :stuck naming the tool and the count when the same call repeats" do
    timeline = run_steps(Array.new(3) { ["bash", { "command" => "ls" }, "out"] })

    expect { described_class::DEFAULT.check!(timeline) }
      .to raise_error(Lain::Budget::Exceeded, /bash.*3 times/) { |e| expect(e.kind).to eq(:stuck) }
  end

  it "lets 2 repeats of a call through" do
    timeline = run_steps(Array.new(2) { ["bash", { "command" => "ls" }, "out"] })

    expect(described_class::DEFAULT.check!(timeline)).to be_nil
  end

  it "does not count the same tool with different input as a repeat" do
    timeline = run_steps(Array.new(3) { |i| ["bash", { "command" => "ls #{i}" }, "out #{i}"] })

    expect(described_class::DEFAULT.check!(timeline)).to be_nil
  end

  it "raises :stuck when 8 steps bring no new result" do
    timeline = run_steps(Array.new(8) { |i| [i.even? ? "bash" : "grep", { "n" => i % 2 }, "same #{i % 2}"] })

    expect { described_class::DEFAULT.check!(timeline) }
      .to raise_error(Lain::Budget::Exceeded, /8 steps/) { |e| expect(e.kind).to eq(:stuck) }
  end

  it "never calls 20 reads of different paths stuck" do
    timeline = run_steps(Array.new(20) { |i| ["read_file", { "path" => "f#{i}" }, "body #{i}"] })

    expect(described_class::DEFAULT.check!(timeline)).to be_nil
  end

  it "does not call a repeated call stuck while its results change" do
    timeline = run_steps(Array.new(8) { |i| ["bash", { "command" => "make status" }, "progress #{i}"] })

    expect(described_class::DEFAULT.check!(timeline)).to be_nil
  end

  it "does not call distinct calls stuck because each returns the same ok" do
    timeline = run_steps(Array.new(8) { |i| ["edit_file", { "path" => "f#{i}" }, "ok"] })

    expect(described_class::DEFAULT.check!(timeline)).to be_nil
  end

  it "starts a fresh window at each human turn" do
    first = run_steps(Array.new(2) { ["bash", { "command" => "ls" }, "out"] })
    asked = first.commit(role: :assistant, content: [{ "type" => "text", "text" => "done" }])
                 .commit(role: :user, content: "again")
    timeline = 2.times.inject(asked) do |tl, i|
      result_turn(call_turn(tl, "bash", { "command" => "ls" }, "n#{i}"), "n#{i}", "out")
    end

    expect(described_class::DEFAULT.check!(timeline)).to be_nil
  end

  it "walks a bounded number of turns however long the session is" do
    turn = Struct.new(:role, :content).new("assistant", [{ "type" => "text", "text" => "hi" }])
    walk = Enumerator.new do |yielder|
      3000.times do |i|
        raise "walked past turn #{i}" if i > 30

        yielder << turn
      end
    end
    timeline = Struct.new(:ancestors).new(walk)

    expect(described_class::DEFAULT.check!(timeline)).to be_nil
  end

  it "is not stuck when only some of the newer half repeats the older half" do
    steps = Array.new(4) { |i| ["bash", { "n" => i }, "r#{i}"] } +
            [["bash", { "n" => 0 }, "r0"], ["bash", { "n" => 1 }, "r1"], ["bash", { "n" => 2 }, "r2"],
             ["bash", { "n" => 9 }, "r9"]]

    expect(described_class::DEFAULT.check!(run_steps(steps))).to be_nil
  end

  it "is inert when a threshold is nil" do
    timeline = run_steps(Array.new(9) { ["bash", { "command" => "ls" }, "out"] })

    expect(described_class.new(repeats: nil, stale_steps: nil).check!(timeline)).to be_nil
  end
end
