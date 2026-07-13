# frozen_string_literal: true

require "lain/tools/todo_write"
require "lain/session"
require "lain/tool/invocation"
require "lain/context"
require "lain/workspace"
require "lain/timeline"
require "lain/store"
require "lain/toolset"

RSpec.describe Lain::Tools::TodoWrite do
  subject(:tool) { described_class.new }

  def invocation_with(session)
    Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
  end

  def text(body) = [{ "type" => "text", "text" => body }]

  it "has a model-facing name and description" do
    expect(tool.name).to eq("todo_write")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "declares a required array of content/status items" do
    schema = tool.input_schema
    expect(schema["required"]).to eq(["todos"])
    items = schema["properties"]["todos"]["items"]
    expect(items["required"]).to eq(%w[content status])
    expect(items["properties"]["status"]["enum"]).to eq(%w[pending in_progress completed])
  end

  it "does not care about the invocation it is handed" do
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    result = tool.call({ todos: [{ content: "a", status: "pending" }] }, invocation)
    expect(result.is_error).to be(false)
  end

  describe "writing to the session" do
    let(:session) { Lain::Session.new }

    it "replaces the session's whole todo list in one call" do
      tool.call({ todos: [{ content: "ship T13", status: "in_progress" }] }, invocation_with(session))

      expect(session.reminders).to eq(["Current todo list:\n- [in_progress] ship T13"])
    end

    # Scenario: replacement is total
    it "replaces rather than merges: a second call drops everything from the first" do
      tool.call({ todos: [{ content: "a", status: "pending" }, { content: "b", status: "pending" }] },
                invocation_with(session))

      tool.call({ todos: [{ content: "c", status: "completed" }] }, invocation_with(session))

      expect(session.reminders).to eq(["Current todo list:\n- [completed] c"])
    end

    it "reports success naming the item count" do
      result = tool.call({ todos: [{ content: "a", status: "pending" }, { content: "b", status: "pending" }] },
                         invocation_with(session))

      expect(result.is_error).to be(false)
      expect(result.content).to include("2")
    end

    it "records nothing into a Session::Null context without raising" do
      invocation = invocation_with(Lain::Session::Null.instance)

      result = tool.call({ todos: [{ content: "a", status: "pending" }] }, invocation)

      expect(result.is_error).to be(false)
    end
  end

  describe "rejecting a malformed status" do
    let(:session) { Lain::Session.new }

    it "reports an error Result rather than writing, when status is not one of the allowed values" do
      result = tool.call({ todos: [{ content: "a", status: "done" }] }, invocation_with(session))

      expect(result).to have_attributes(is_error: true, content: /status/)
      expect(session.reminders).to eq([])
    end
  end

  describe "riding the request tail" do
    let(:session) { Lain::Session.new }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
    let(:store) { Lain::Store.new }

    # Scenario: todos ride the request tail, never the Timeline
    it "reaches the rendered request tail via the session's reminders channel, and never the Timeline" do
      tool.call({ todos: [{ content: "ship T13", status: "in_progress" }] }, invocation_with(session))

      timeline = Lain::Timeline.empty(store: store).commit(role: :user, content: text("hi"))
      workspace = Lain::Workspace.empty.with(*session.reminders)
      request = context.render(timeline: timeline, toolset: Lain::Toolset.new, workspace: workspace)

      tail_text = request.messages.last["content"].map { |block| block["text"] }.join
      expect(tail_text).to include("ship T13")

      timeline_blocks = timeline.to_a.flat_map(&:content)
      expect(timeline_blocks.map { |block| block["text"] }).not_to include(/ship T13/)
    end

    # Scenario: todos do not resurrect on rewind
    it "renders the session's CURRENT list, not a historical one, after the Timeline is rewound" do
      # Reminder (the pipeline stage that injects the Workspace tail) only
      # rides the LAST message when its role is "user" -- the shape every real
      # render sees, since the Agent only renders right after a user turn
      # lands (the initial ask, or a tool-result turn). So `base` must end in
      # a user turn for this render to be representative of the real seam.
      base = Lain::Timeline.empty(store: store).commit(role: :user, content: text("turn 1"))

      tool.call({ todos: [{ content: "old todo", status: "completed" }] }, invocation_with(session))

      forked = base.commit(role: :assistant, content: text("ack"))
                   .commit(role: :user, content: text("turn 2"))

      tool.call({ todos: [{ content: "current todo", status: "in_progress" }] }, invocation_with(session))

      rewound = forked.rewind(2)
      expect(rewound).to eq(base)

      workspace = Lain::Workspace.empty.with(*session.reminders)
      request = context.render(timeline: rewound, toolset: Lain::Toolset.new, workspace: workspace)

      tail_text = request.messages.last["content"].map { |block| block["text"] }.join
      expect(tail_text).to include("current todo")
      expect(tail_text).not_to include("old todo")
    end
  end
end
