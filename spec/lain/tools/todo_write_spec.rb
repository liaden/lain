# frozen_string_literal: true

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

    # An item carrying BOTH a String and a Symbol spelling of a key must
    # validate and store the SAME value: the validator resolves the schema's
    # String key, so a lookup that resolved the Symbol first (the old bug)
    # could store a value the validator never saw. Tool#dig fixes the
    # precedence so store == validated.
    it "stores the value the schema validated, not a different key spelling, on a mixed-key item" do
      mixed = { "content" => "canonical", :content => "shadow",
                "status" => "in_progress", :status => "completed" }

      result = tool.call({ "todos" => [mixed] }, invocation_with(session))

      expect(result.is_error).to be(false)
      expect(session.reminders).to eq(["Current todo list:\n- [in_progress] canonical"])
    end
  end

  # Scenario: A completed todo raises the need flag
  #
  # The seam T16 adds: Session cannot detect a status TRANSITION from an
  # overwrite alone (write_todos replaces the whole list, keeping no prior
  # state -- see Session#write_todos), so it now retains the prior
  # structured list IN MEMORY ONLY to compare against, exactly like the
  # existing read-/write-sets. That extra state is never appended to the
  # Timeline and never journaled beyond the existing whole-list
  # TodoSnapshot, so it cannot resurrect a todo on rewind -- it dies with
  # the Session, same as always.
  describe "the plan-step-completion signal" do
    let(:session) { Lain::Session.new }

    it "is false before any todo_write lands" do
      expect(session.plan_step_completed?).to be(false)
    end

    it "stays false while nothing transitions to completed" do
      tool.call({ todos: [{ content: "a", status: "pending" }] }, invocation_with(session))
      tool.call({ todos: [{ content: "a", status: "in_progress" }] }, invocation_with(session))

      expect(session.plan_step_completed?).to be(false)
    end

    it "raises when a subsequent write flips one item to completed" do
      tool.call({ todos: [{ content: "a", status: "in_progress" }, { content: "b", status: "pending" }] },
                invocation_with(session))

      tool.call({ todos: [{ content: "a", status: "completed" }, { content: "b", status: "pending" }] },
                invocation_with(session))

      expect(session.plan_step_completed?).to be(true)
    end

    it "does not re-raise on a later write that merely repeats the same completed item" do
      tool.call({ todos: [{ content: "a", status: "in_progress" }] }, invocation_with(session))
      tool.call({ todos: [{ content: "a", status: "completed" }] }, invocation_with(session))
      tool.call({ todos: [{ content: "a", status: "completed" }, { content: "b", status: "pending" }] },
                invocation_with(session))

      expect(session.plan_step_completed?).to be(false)
    end

    # Content-keyed matching masks a transition when two todos share wording:
    # both "dup" items are the SAME string, so a set of completed content
    # cannot tell "dup" (still in_progress) from "dup" (now completed) apart
    # -- a false negative the reviewer reproduced. The signal is COUNT-based
    # instead: it fires when the number of completed items goes up, which is
    # robust to duplicate content and to reordering.
    it "fires on a duplicate-content transition that a content-keyed diff would mask" do
      tool.call({ todos: [{ content: "dup", status: "in_progress" }, { content: "dup", status: "completed" }] },
                invocation_with(session))

      tool.call({ todos: [{ content: "dup", status: "completed" }, { content: "dup", status: "completed" }] },
                invocation_with(session))

      expect(session.plan_step_completed?).to be(true)
    end

    # Any increase in completed-count is a compaction-worthy plan-step signal
    # -- decided explicitly rather than left as an open question: a step
    # closing (whether newly completed or born already-done) is the seam
    # `cache-aware-compaction.md` names, so both fire.
    it "fires on the very first write when it already contains a completed item (count 0 -> 1)" do
      tool.call({ todos: [{ content: "a", status: "completed" }] }, invocation_with(session))

      expect(session.plan_step_completed?).to be(true)
    end

    it "fires when a later write adds a brand-new item that is already completed (count increases)" do
      tool.call({ todos: [{ content: "a", status: "in_progress" }] }, invocation_with(session))

      tool.call({ todos: [{ content: "a", status: "in_progress" }, { content: "b", status: "completed" }] },
                invocation_with(session))

      expect(session.plan_step_completed?).to be(true)
    end

    it "does not re-raise on an idempotent re-write of an already-completed list (count unchanged)" do
      tool.call({ todos: [{ content: "a", status: "completed" }] }, invocation_with(session))
      tool.call({ todos: [{ content: "a", status: "completed" }] }, invocation_with(session))

      expect(session.plan_step_completed?).to be(false)
    end

    it "feeds Compaction::Need, raising its need flag" do
      tool.call({ todos: [{ content: "a", status: "in_progress" }] }, invocation_with(session))
      tool.call({ todos: [{ content: "a", status: "completed" }] }, invocation_with(session))

      need = Lain::Compaction::Need.new(byte_threshold: 1_000_000, window_tokens: 1_000_000)
      result = need.check(plan_step_completed: session.plan_step_completed?)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:plan_step_completion)
    end

    it "does not raise on the Session::Null context" do
      invocation = invocation_with(Lain::Session::Null.instance)

      expect { tool.call({ todos: [{ content: "a", status: "completed" }] }, invocation) }.not_to raise_error
      expect(Lain::Session::Null.instance.plan_step_completed?).to be(false)
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

      timeline = Lain::Timeline.empty(store:).commit(role: :user, content: text("hi"))
      workspace = Lain::Workspace.empty.with(*session.reminders)
      request = context.render(timeline:, toolset: Lain::Toolset.new, workspace:)

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
      base = Lain::Timeline.empty(store:).commit(role: :user, content: text("turn 1"))

      tool.call({ todos: [{ content: "old todo", status: "completed" }] }, invocation_with(session))

      forked = base.commit(role: :assistant, content: text("ack"))
                   .commit(role: :user, content: text("turn 2"))

      tool.call({ todos: [{ content: "current todo", status: "in_progress" }] }, invocation_with(session))

      rewound = forked.rewind(2)
      expect(rewound).to eq(base)

      workspace = Lain::Workspace.empty.with(*session.reminders)
      request = context.render(timeline: rewound, toolset: Lain::Toolset.new, workspace:)

      tail_text = request.messages.last["content"].map { |block| block["text"] }.join
      expect(tail_text).to include("current todo")
      expect(tail_text).not_to include("old todo")
    end
  end
end
