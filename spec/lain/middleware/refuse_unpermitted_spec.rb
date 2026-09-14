# frozen_string_literal: true

# The refusal a child renders the shared union behind: the model may ATTEMPT a
# tool it sees but was not attenuated to, and is told no. Enforcement over a
# union schema is honest because tools are capabilities -- what refuses is the
# stack, not the schema.
RSpec.describe Lain::Middleware::RefuseUnpermitted do
  let(:journal) { [] }
  let(:layer) { described_class.new(allowed: %w[read_file], journal:) }

  def call(name, id: "tu_1") = Lain::Effect::ToolCall.new(tool_use_id: id, name:, input: {})

  def through(effect)
    reached = []
    env = layer.call({ effect:, tool: Lain::Toolset::Unheld.new("unused"), context: nil }) do |inner|
      reached << inner.fetch(:effect)
      inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
    end
    [env.fetch(:result), reached]
  end

  it "refuses a call the child was not permitted, naming the tool, and nothing reaches downstream" do
    result, reached = through(call("bash"))

    expect(result).to have_attributes(is_error: true, content: 'subagent is not permitted to call "bash"')
    expect(reached).to be_empty
  end

  it "journals the refusal as an attributed record" do
    through(call("bash", id: "tu_3"))

    expect(journal.map(&:to_journal)).to eq([{ "type" => "refused", "tool_use_id" => "tu_3", "name" => "bash" }])
  end

  it "passes a permitted call downstream untouched, and journals nothing" do
    effect = call("read_file")

    expect(through(effect)).to eq([Lain::Tool::Result.ok("downstream ran"), [effect]])
    expect(journal).to be_empty
  end

  it "passes an effect that is not a tool call" do
    effect = Lain::Effect::ModelCall.new(request: nil)

    expect(through(effect).last).to eq([effect])
  end
end
