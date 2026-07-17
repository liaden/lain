# frozen_string_literal: true

require "async"

# C2 REVIEW PROBES (adversarial; leave in worktree). Each block names the AC or
# claim it tries to falsify and the persona that owns the finding. Probes that
# DOCUMENT a gap assert current behavior and say FINDING in the comment -- the
# probe stays green so the file is runnable evidence, and the review carries
# the ranked finding.
RSpec.describe "C2 probes: sibling-template prefix strategy" do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:union) { Lain::Toolset.new([Lain::Tools::ReadFile.new, EchoTool.new]) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:template) { "Shared sibling brief, the bulk every worker reads first. " * 40 }
  let(:sibling_template) { Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate }

  def policy(prefix:, posture: :handler_union, only: %i[read_file])
    Lain::Tool::SpawnPolicy.new(prefix:, posture:, only:)
  end

  def build_tool(provider:, policy:, journal: Lain::Channel::Null.instance, context: child_context)
    Lain::Tools::Subagent.new(
      provider:, context_factory: -> { context }, toolset: union, policy:,
      parent:, journal:, budget: Lain::Agent::Budget.new, max_depth: 3
    )
  end

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  # The encoder consults #supports? -- same bare-host duck the encoding spec uses.
  def encoder
    Class.new do
      include Lain::Provider::AnthropicEncoding

      def supports?(_capability) = true
    end.new
  end

  def wire_marks(encoded)
    system_marks = Array(encoded[:system_]).select { |b| b.is_a?(Hash) && b["cache_control"] }
    message_marks = encoded[:messages].flat_map { |m| m["content"] }
                                      .select { |b| b.is_a?(Hash) && b["cache_control"] }
    [system_marks, message_marks]
  end

  # ---- AC1: full-BYTE prefix identity, not just digest identity --------------
  # Linus: compare the actual bytes through the breakpoint, and prove no
  # per-child content leaks forward into any sibling's shared prefix.
  it "P1: three siblings' full prefix bytes are identical, and no task leaks into any prefix" do
    provider = mock(text_response("a"), text_response("b"), text_response("c"))
    tool = build_tool(provider:, policy: policy(prefix: sibling_template.new(template:)))
    tasks = %w[alpha-task beta-task gamma-task]
    tasks.each { |t| expect(tool.call({ "prompt" => t }, invocation)).to be_ok }

    prefix_bytes = provider.requests.map { |r| Lain::Canonical.dump(r.cache_prefix) }
    expect(prefix_bytes.uniq.size).to eq(1)
    tasks.each { |t| expect(prefix_bytes.first).not_to include(t) }
    # per-child content sits after the breakpoint: first user message is the task
    provider.requests.each_with_index do |r, i|
      expect(r.messages.first["content"].first["text"]).to eq(tasks[i])
    end
  end

  # "Different roles with the same template": two DIFFERENT tools (different
  # only-sets -- the closest thing this seam has to roles) over the same union
  # and template must still share prefix bytes, because under handler_union the
  # attenuation never reaches the schema. Aaron: this is the CE-4 win stated as
  # bytes.
  it "P2: two differently-attenuated siblings over one template share full prefix bytes" do
    a = build_tool(provider: (pa = mock(text_response("a"))),
                   policy: policy(prefix: sibling_template.new(template:), only: %i[read_file]))
    b = build_tool(provider: (pb = mock(text_response("b"))),
                   policy: policy(prefix: sibling_template.new(template:), only: %i[echo]))
    a.call({ "prompt" => "one" }, invocation)
    b.call({ "prompt" => "two" }, invocation)

    expect(Lain::Canonical.dump(pa.last_request.cache_prefix))
      .to eq(Lain::Canonical.dump(pb.last_request.cache_prefix))
  end

  # ---- AC1: chain-head sharing on the CURRENT (pre-R1) prefix_digests --------
  it "P3: prefix_digests share one head at SYSTEM_PREFIX and diverge at the tail" do
    provider = mock(text_response("a"), text_response("b"), text_response("c"))
    tool = build_tool(provider:, policy: policy(prefix: sibling_template.new(template:)))
    %w[t1 t2 t3].each { |t| tool.call({ "prompt" => t }, invocation) }

    chains = provider.requests.map(&:prefix_digests)
    heads = chains.map(&:first)
    expect(heads.map(&:first).uniq).to eq([Lain::Request::SYSTEM_PREFIX])
    expect(heads.map(&:last).uniq.size).to eq(1)
    expect(chains.map(&:last).map(&:last).uniq.size).to eq(3)
  end

  # ---- The T24 census, on the ACTUAL Anthropic wire encoding -----------------
  # Linus: the card spec counts neutral marks on the Request; the wire is what
  # 400s. Encode and count cache_control across system_ AND messages: exactly
  # one system-slot mark, on the template.
  it "P4: the encoded wire carries exactly one system cache_control, on the template block" do
    provider = mock(text_response("done"))
    tool = build_tool(provider:, policy: policy(prefix: sibling_template.new(template:)))
    tool.call({ "prompt" => "go" }, invocation)

    system_marks, message_marks = wire_marks(encoder.encode(provider.last_request))
    expect(system_marks.size).to eq(1)
    expect(system_marks.first["text"]).to eq(template)
    expect(message_marks.size).to eq(1)
    expect(system_marks.size + message_marks.size).to be <= 4
  end

  # At CacheBreakpoints' FULL 3-message budget (the card spec never drives it
  # there), the template arm must still fit the 4-marker cap. 40 single-block
  # messages force indices [14, 29, 39] -> 3 message marks + 1 system = 4.
  it "P5: at the full message-marker budget the template arm sits exactly at the cap and encodes" do
    shaped = sibling_template.new(template:).child_context(child_context)
    timeline = (0...40).reduce(Lain::Timeline.empty(store:)) do |tl, i|
      tl.commit(role: i.even? ? :user : :assistant,
                content: [{ "type" => "text", "text" => "m#{i}" }])
    end
    request = shaped.render(timeline:, toolset: union)

    system_marks, message_marks = wire_marks(encoder.encode(request))
    expect(system_marks.size).to eq(1)
    expect(message_marks.size).to eq(3)
  end

  # FIXED (was the Linus SHOULD-FIX finding): a factory context whose system
  # arrives PRE-MARKED (the role_spec:119-136 probe shape) used to keep its
  # mark when the template demoted it to non-last -- 2 system marks, 5 on the
  # wire at full message budget -> TooManyCacheMarkers mid-child-run. The
  # strategy now owns ALL mark placement for the child: caller marks are
  # stripped (and the strip journaled), so exactly Context's tail mark -- the
  # template boundary -- reaches the wire.
  it "P6: a pre-marked factory system is stripped to exactly one wire mark, journaled, baseline untouched" do
    marked_ctx = Lain::Context.new(
      model: "child-model", max_tokens: 256,
      system: [{ "type" => "text", "text" => "bulk", "cache" => true }]
    )
    notes = []
    shaped = sibling_template.new(template:).child_context(marked_ctx, journal: notes)
    timeline = (0...40).reduce(Lain::Timeline.empty(store:)) do |tl, i|
      tl.commit(role: i.even? ? :user : :assistant,
                content: [{ "type" => "text", "text" => "m#{i}" }])
    end
    request = shaped.render(timeline:, toolset: union)

    expect(request.system.count { |b| b["cache"] }).to eq(1)
    expect(notes.map { |n| n.to_journal["type"] }).to eq(%w[system_mark_stripped])

    system_marks, message_marks = wire_marks(encoder.encode(request))
    expect(system_marks.size).to eq(1)
    expect(system_marks.first["text"]).to eq(template)
    expect(message_marks.size).to eq(3)

    # baseline: the SAME pre-marked factory WITHOUT the template stays at 1
    # mark (Context#cache_marked's merge is idempotent on a last-block mark)
    baseline = marked_ctx.render(timeline:, toolset: union)
    expect(baseline.system.count { |b| b["cache"] }).to eq(1)
  end

  # ---- AC3: handler_union tool bytes on the wire -----------------------------
  it "P7: two siblings' ENCODED tool schemas are byte-identical; a denied call refuses at the Handler" do
    provider = mock(
      text_response("first"),
      tool_response(["t1", "echo", { "text" => "x" }]),
      text_response("second")
    )
    journal = Lain::Channel.new
    tool = build_tool(provider:, policy: policy(prefix: sibling_template.new(template:)), journal:)
    tool.call({ "prompt" => "one" }, invocation)
    tool.call({ "prompt" => "two" }, invocation)

    encoded_tools = provider.requests.map { |r| JSON.dump(encoder.encode(r)[:tools]) }
    expect(encoded_tools.uniq.size).to eq(1)

    refusal = tool.last_child.to_a.find do |turn|
      turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" }
    end
    expect(refusal.content.first["is_error"]).to be(true)
    expect(journal.drain.map { |e| e.to_journal["type"] }).to include("refused")
  end

  # ---- AC4: the floor boundary, both sides, and per-SPAWN (not per-render) ---
  it "P8: one char under the floor notes; at the floor it does not" do
    floor_chars = sibling_template::MINIMUM_CACHEABLE_TOKENS * sibling_template::CHARS_PER_TOKEN
    notes_under = []
    notes_at = []
    sibling_template.new(template: "x" * (floor_chars - 1)).journal_floor(notes_under)
    sibling_template.new(template: "x" * floor_chars).journal_floor(notes_at)

    expect(notes_under.map { |n| n.to_journal["type"] }).to eq(%w[template_below_floor])
    expect(notes_at).to be_empty
  end

  it "P9: the floor note fires once per SPAWN even when the child renders twice, and N times for N spawns" do
    journal = Lain::Channel.new
    provider = mock(
      tool_response(["t1", "read_file", { "path" => "/nonexistent" }]), # 2 renders in spawn 1
      text_response("done"),
      text_response("done"), text_response("done")
    )
    tool = build_tool(provider:, policy: policy(prefix: sibling_template.new(template: "tiny")), journal:)
    tool.call({ "prompt" => "one" }, invocation)
    two_render_notes = journal.drain.count { |e| e.to_journal["type"] == "template_below_floor" }
    expect(two_render_notes).to eq(1)

    tool.call({ "prompt" => "two" }, invocation)
    tool.call({ "prompt" => "three" }, invocation)
    expect(journal.drain.count { |e| e.to_journal["type"] == "template_below_floor" }).to eq(2)
  end

  # FIXED (was the Schneeman SHOULD-FIX finding): #launch_actor builds the
  # child through the same child_context seam (the template rides) and now
  # calls journal_floor too -- an actor-mode sibling below the floor is
  # reported, never the "silently un-cacheable" state AC4 forbids.
  it "P10: launch_actor threads the template AND journals the floor note" do
    journal = Lain::Channel.new
    provider = mock(text_response("actor done"))
    tool = Lain::Tools::Subagent.new(
      provider:, context_factory: -> { child_context }, toolset: union,
      policy: policy(prefix: sibling_template.new(template: "tiny"), posture: :schema),
      parent:, journal:, budget: Lain::Agent::Budget.new,
      max_depth: 1, mode: :actor, log: Lain::Tools::Subagent::Log.new
    )
    Sync do
      actor = tool.launch_actor("go")
      actor.settle
      expect(actor.timeline).not_to be_empty
      actor.stop
    end

    types = journal.drain.map { |e| e.to_journal["type"] }
    expect(provider.last_request.system.last["text"]).to eq("tiny") # template rode
    expect(types).to include("template_below_floor")                # ...and loudly
  end

  # ---- Fresh/Inherit unchanged: the new legs are byte-invisible --------------
  # Jeremy: the only render-path change is child_context(factory.call); identity
  # passthrough (same OBJECT, not an equal copy) is what makes the fresh and
  # inherit arms byte-identical to the base rendering by construction.
  it "P11: Fresh, Inherit, and the empty-template SiblingTemplate all pass the factory context through by identity" do
    strategies = Lain::Tool::SpawnPolicy::PrefixStrategy
    expect(strategies.fetch(:fresh).child_context(child_context)).to be(child_context)
    expect(strategies.fetch(:inherit).child_context(child_context)).to be(child_context)
    expect(strategies.fetch(:sibling_template).child_context(child_context)).to be(child_context)
  end

  it "P12: a fresh-arm spawn still renders system: nil -- zero bytes added by the seam" do
    provider = mock(text_response("done"))
    tool = build_tool(provider:, policy: policy(prefix: :fresh, posture: :schema))
    tool.call({ "prompt" => "go" }, invocation)
    expect(provider.last_request.system).to be_nil
  end

  # ---- Isolation invariants under the template arm ---------------------------
  it "P13: the strategy is frozen and its template immutable -- safe under the fiber fan-out" do
    strategy = sibling_template.new(template:)
    expect(strategy).to be_frozen
    expect(strategy.child_context(child_context)).to be_frozen
    expect(Ractor.shareable?(strategy)).to be(true)
  end

  it "P14: sibling timelines stay fresh-rooted: meet with parent AND with each other is empty" do
    provider = mock(text_response("a"), text_response("b"))
    tool = build_tool(provider:, policy: policy(prefix: sibling_template.new(template:)))
    tool.call({ "prompt" => "one" }, invocation)
    first_child = tool.last_child
    tool.call({ "prompt" => "two" }, invocation)
    second_child = tool.last_child

    expect(first_child.meet(parent)).to be_empty
    expect(first_child.meet(second_child)).to be_empty
    expect(first_child.to_a.first.content.first["text"]).to eq("one")
    expect(second_child.to_a.first.content.first["text"]).to eq("two")
  end
end
