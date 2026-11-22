# frozen_string_literal: true

# A model only ever sees placeholders for the person and the box, so the paths
# and text it writes into a tool call carry them back. The call must reach the
# tool with the real values.
RSpec.describe Lain::Middleware::RestoreIdentity do
  subject(:layer) { described_class.new(identity:) }

  let(:identity) do
    Lain::Sensitivity::Secrets::Identity.current(env: { "HOME" => "/home/alice", "USER" => "alice" },
                                                 git: ->(_) {}, hostname: "wonder")
  end

  def call(input, name: "read_file") = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  def reached(effect)
    seen = nil
    layer.call({ effect:, context: nil }) { |env| (seen = env.fetch(:effect)) && env }
    seen
  end

  it "hands the tool the real path for a placeholder" do
    expect(reached(call({ "path" => "/home/<lain:user>/dev/app/README.md" })).input)
      .to eq({ "path" => "/home/alice/dev/app/README.md" })
  end

  it "restores file contents the model writes back" do
    effect = call({ "path" => "/home/<lain:user>/notes.txt", "content" => "notes live in /home/<lain:user>/notes\n" },
                  name: "write_file")

    expect(reached(effect).input["content"]).to eq("notes live in /home/alice/notes\n")
  end

  # An input is not only flat strings: a JSON content or an edit list nests
  # them, and every string leaf is restored wherever it sits.
  it "restores every string leaf of a nested input, and leaves other values alone" do
    input = { "edits" => [{ "old" => "<lain:user>@<lain:host>", "new" => "x" }], "limit" => 3,
              "deep" => { "on" => true } }

    expect(reached(call(input, name: "multi")).input)
      .to eq({ "edits" => [{ "old" => "alice@wonder", "new" => "x" }], "limit" => 3, "deep" => { "on" => true } })
  end

  it "restores the call inside an approval wrapper" do
    wrapped = Lain::Effect::Approval.new(effect: call({ "path" => "/home/<lain:user>/a" }))

    expect(reached(wrapped).effect.input).to eq({ "path" => "/home/alice/a" })
  end

  it "passes a call that names no placeholder through as the same object" do
    effect = call({ "path" => "/srv/app/a.rb" })

    expect(reached(effect)).to equal(effect)
  end
end
