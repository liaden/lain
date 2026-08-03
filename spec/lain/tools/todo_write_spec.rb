# frozen_string_literal: true

RSpec.describe Lain::Tools::TodoWrite do
  subject(:tool) { described_class.new }

  def invocation_with(session)
    Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
  end

  def text(body) = [{ "type" => "text", "text" => body }]

  # Scenario: the emitted schema is unchanged by the migration
  #
  # Pinned as literal bytes rather than as a handful of probes: every tool's
  # schema folds into {Oracle::Definition}'s Canonical.digest and the tools
  # block is the prompt-cache prefix, so a re-emission that moved one key or
  # dropped one nested description would break every cached prefix in the
  # bench while passing any spec that only asked about `required` and `enum`.
  describe "the schema the model sees" do
    let(:emitted) do
      {
        "type" => "object",
        "properties" => {
          "todos" => {
            "type" => "array",
            "description" => "The complete replacement todo list, in the order it should be shown.",
            "items" => {
              "type" => "object",
              "properties" => {
                "content" => { "type" => "string", "description" => "What the todo is." },
                "status" => {
                  "type" => "string",
                  "description" => "One of pending, in_progress, completed.",
                  "enum" => %w[pending in_progress completed]
                }
              },
              "required" => %w[content status],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["todos"],
        "additionalProperties" => false
      }
    end

    it "is byte-identical to what it promised before the field-DSL migration, key order included" do
      expect(tool.input_schema.to_json).to eq(emitted.to_json)
    end

    it "comes from a Tool::Input declaration, so the wire schema and the local check cannot drift" do
      expect(described_class.input_model).to be < Lain::Tool::Input
    end
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

    # An item carrying BOTH a String and a Symbol spelling of a key used to be
    # RESOLVED, by matching Tool#dig's precedence to the raw-schema validator's
    # so the stored value was the validated one. Under {Tool::Input} the
    # ambiguity is refused outright instead -- the same call {Lain::Canonical}
    # makes -- because nothing justifies preferring either spelling, and a rule
    # nobody remembers is worse than a loud failure. Renegotiated with T3.
    it "refuses a mixed-key item rather than picking a spelling, naming the element by index" do
      mixed = { "content" => "canonical", :content => "shadow",
                "status" => "in_progress", :status => "completed" }

      expect { tool.call({ "todos" => [mixed] }, invocation_with(session)) }
        .to raise_error(Lain::Tool::InvalidInput, /todos\[0\].*content/)
      expect(session.reminders).to eq([])
    end

    # Scenario: perform receives coerced items rather than a raw Hash
    it "hands the session coerced items answering #content/#status, in the order given" do
      written = nil
      allow(session).to receive(:write_todos).and_wrap_original do |original, todos|
        written = todos.to_a
        original.call(todos)
      end

      tool.call({ todos: [{ content: "first", status: "in_progress" },
                          { content: "second", status: "pending" }] },
                invocation_with(session))

      expect(written.map(&:content)).to eq(%w[first second])
      expect(written.map(&:status)).to eq(%w[in_progress pending])
      expect(session.reminders)
        .to eq(["Current todo list:\n- [in_progress] first\n- [pending] second"])
    end
  end

  # Scenario: an empty todo list is still accepted
  #
  # This is how a run CLEARS its list, it succeeds on main, and no spec pinned
  # it before T3. Schema equality cannot catch its loss: `todos` stays in the
  # emitted `required` either way, so a `required:` that rejected `[]` as blank
  # would leave the bytes identical and break the tool. Pinned on the real
  # tool, not on a stand-in declaration.
  describe "clearing the list" do
    let(:session) { Lain::Session.new }

    it "accepts an empty todos array and reports the 0-item shape" do
      result = tool.call({ "todos" => [] }, invocation_with(session))

      expect(result).to have_attributes(is_error: false, content: "todo list replaced with 0 item(s)")
      expect(session.reminders).to eq([])
    end

    it "clears a list that a previous call populated" do
      tool.call({ todos: [{ content: "a", status: "pending" }] }, invocation_with(session))

      result = tool.call({ todos: [] }, invocation_with(session))

      expect(result.is_error).to be(false)
      expect(session.reminders).to eq([])
    end

    it "still requires the key itself: an omitted todos list is refused" do
      expect { tool.call({}, invocation_with(session)) }
        .to raise_error(Lain::Tool::InvalidInput, /todos/i)
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

      need = Lain::Compaction::Need.new(byte_threshold: 1_000_000)
      result = need.check(window_tokens: 1_000_000, plan_step_completed: session.plan_step_completed?)

      expect(result.needed?).to be(true)
      expect(result.signals).to include(:plan_step_completion)
    end

    it "does not raise on the Session::Null context" do
      invocation = invocation_with(Lain::Session::Null.instance)

      expect { tool.call({ todos: [{ content: "a", status: "completed" }] }, invocation) }.not_to raise_error
      expect(Lain::Session::Null.instance.plan_step_completed?).to be(false)
    end
  end

  # Scenario: a bad status is refused before perform runs
  #
  # Renegotiated with T3: this used to be an error Result, because the enum
  # check was hand-rolled inside #perform. Declared as an `inclusion` validator
  # on the element, the SAME declaration emits the schema's `enum` and refuses
  # the call, and it refuses it in {Tool#call} -- before #perform, so there is
  # no Result to return. The executing Effect::Handler turns the raise into an
  # error Result for the model (see Tool's header), so what the model sees is
  # unchanged; what cannot happen any more is #perform running at all.
  describe "rejecting a malformed status" do
    let(:session) { Lain::Session.new }

    it "raises InvalidInput naming the offending status, rather than writing" do
      expect { tool.call({ todos: [{ content: "a", status: "done" }] }, invocation_with(session)) }
        .to raise_error(Lain::Tool::InvalidInput, /done/)
      expect(session.reminders).to eq([])
    end

    it "names the element by index, so one bad item in a long list is findable" do
      expect do
        tool.call({ todos: [{ content: "a", status: "pending" }, { content: "b", status: "nearly" }] },
                  invocation_with(session))
      end.to raise_error(Lain::Tool::InvalidInput, /todos\[1\].*[Ss]tatus/)
    end

    it "refuses an item missing content outright" do
      expect { tool.call({ todos: [{ status: "pending" }] }, invocation_with(session)) }
        .to raise_error(Lain::Tool::InvalidInput, /todos\[0\].*[Cc]ontent/)
    end
  end

  # Two refusals the field DSL introduces. Both inputs were SILENTLY ACCEPTED
  # before T3 -- the raw-Hash validator checked types and required keys and
  # nothing else -- so both are behaviour changes, and a behaviour change
  # nobody pins is one that regresses without a spec noticing. Refusing beats
  # accepting for the same reason everywhere else in this repo: an empty todo
  # renders as `- [pending] ` with nothing after it, and a key the schema never
  # declared means the model believes in a field that does not exist.
  describe "what the raw-Hash validator used to let through" do
    let(:session) { Lain::Session.new }

    it "refuses an item whose content is the empty string" do
      expect { tool.call({ todos: [{ content: "", status: "pending" }] }, invocation_with(session)) }
        .to raise_error(Lain::Tool::InvalidInput, /todos\[0\].*[Cc]ontent/)
      expect(session.reminders).to eq([])
    end

    it "refuses an item carrying a key the schema never declared" do
      expect do
        tool.call({ todos: [{ content: "a", status: "pending", priority: "high" }] }, invocation_with(session))
      end.to raise_error(Lain::Tool::InvalidInput, /todos\[0\].*priority/)
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
