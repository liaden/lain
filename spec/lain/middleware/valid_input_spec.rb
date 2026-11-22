# frozen_string_literal: true

# A call whose input cannot validate is refused before any approval rung is asked about it,
# so a human is never parked on a call that will run nothing.
RSpec.describe Lain::Middleware::ValidInput do
  let(:journal) { [] }
  let(:layer) { described_class.new(journal:) }
  let(:tool) { Lain::Tools::Bash.new }

  def call(input, name: "bash") = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  def through(effect, with: tool)
    reached = []
    env = layer.call({ effect:, tool: with, context: nil }) do |inner|
      reached << inner.fetch(:effect)
      inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
    end
    [env.fetch(:result), reached]
  end

  it "refuses a bash call without a command, naming the field, and nothing reaches downstream" do
    result, reached = through(call({ "name" => "pin-check" }))

    expect(result).to have_attributes(is_error: true, content: /invalid input for bash.*command/i)
    expect(reached).to be_empty
  end

  it "journals the refusal as a decline naming the tool, never quoting the input" do
    through(call({ "name" => "secret-value" }))

    expect(journal.map(&:to_journal)).to eq([{ "type" => "write_refused", "tool_use_id" => "tu_1",
                                               "pattern" => "decline:invalid_input:bash" }])
  end

  it "passes input the tool's own call coerces: a numeric string and a null optional" do
    effect = call({ "command" => "ls", "timeout" => "30", "cwd" => nil })

    expect(through(effect)).to eq([Lain::Tool::Result.ok("downstream ran"), [effect]])
  end

  it "passes a null optional on a tool with a boolean field" do
    grep = Lain::Tools::Grep.new
    effect = call({ "pattern" => "x", "path" => ".", "case_insensitive" => nil }, name: "grep")

    expect(through(effect, with: grep).last).to eq([effect])
  end

  it "names the missing field but never echoes an unknown key or a value back" do
    key = %w[AKIAZZZ 1234567890AB].join
    value = "sk-live-9f8e7d6c5b4a3210"
    result, = through(call({ key => value, "timeout" => value }))

    expect(result.content).to include("1 unknown key")
    expect(result.content).to include("command")
    expect(result.content).not_to include(key, value)
    expect(journal.map(&:to_journal).to_s).not_to include(key, value)
  end

  it "refuses through an approval wrapper too" do
    result, reached = through(Lain::Effect::Approval.new(effect: call({})))

    expect(result.error?).to be(true)
    expect(reached).to be_empty
  end

  it "passes a valid call downstream untouched" do
    effect = call({ "command" => "ls" })

    expect(through(effect)).to eq([Lain::Tool::Result.ok("downstream ran"), [effect]])
    expect(journal).to be_empty
  end

  it "leaves a call to a tool this set does not hold to the runner's own refusal" do
    effect = call({}, name: "ghost")

    expect(through(effect, with: Lain::Toolset::Unheld.new("ghost")).last).to eq([effect])
  end

  it "passes an effect that is not a tool call" do
    effect = Lain::Effect::ModelCall.new(request: nil)

    expect(through(effect).last).to eq([effect])
  end
end
