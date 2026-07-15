# frozen_string_literal: true

# The T1 acceptance: the memory READ path, wired end to end through the live
# session. A Session holding the run's Memory::Recorder renders the manifest
# into the Request's workspace tail -- the same uncached-suffix channel todos
# ride -- and Tools::MemoryRead over the same recorder closes the loop: what
# the model wrote this session, it can list (manifest) and open (read back).
#
# Wired for real, not simulated: renders go through a real Agent over
# Provider::Mock (which retains the Requests it was handed), and the write
# that populates memory in the read-back example is the Agent's own
# memory_write tool, run through the real ToolRunner -- the same shape as
# spec/lain/seams/memory_snapshot_seam_spec.rb.
RSpec.describe "Memory read path seam" do
  def item(id, description)
    Lain::Memory::Item.new(id:, description:, body: "body of #{id}")
  end

  def write_call(tool_use_id, memory_item)
    [tool_use_id, "memory_write",
     { "id" => memory_item.id, "description" => memory_item.description, "body" => memory_item.body }]
  end

  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }

  def agent_over(session, responses:, toolset: Lain::Toolset.new)
    provider = Lain::Provider::Mock.new(responses:)
    agent = Lain::Agent.new(provider:, toolset:, context:, session:)
    [agent, provider]
  end

  describe "manifest descriptions reach the rendered Request tail" do
    let(:recorder) do
      Lain::Memory::Recorder.new.tap do |holder|
        holder.write(item("aspirin-dosing", "Aspirin dosing bounds for adults"))
        holder.write(item("warfarin-interactions", "Warfarin interaction list"))
      end
    end

    it "carries both id | description lines inside the final user message's workspace-tagged block" do
      agent, provider = agent_over(Lain::Session.new(memory: recorder), responses: [text_response])
      agent.ask("what do we know about anticoagulants?")

      final_message = provider.last_request.messages.last
      expect(final_message.fetch("role")).to eq("user")

      workspace_block = final_message.fetch("content")
                                     .filter_map { |block| block["text"] }
                                     .find { |text| text.start_with?(Lain::Workspace::OPENING_TAG) }
      expect(workspace_block).to include("aspirin-dosing | Aspirin dosing bounds for adults")
        .and include("warfarin-interactions | Warfarin interaction list")
        .and end_with(Lain::Workspace::CLOSING_TAG)
    end
  end

  describe "the manifest never disturbs the cached prefix" do
    # Multi-block turns, sized so CacheBreakpoints places an INTERMEDIATE
    # marker (blocks_since >= EVERY at the assistant turn) besides the
    # final-message marker and the system marker -- the chain must have a
    # cached prefix to protect, or this example would pass vacuously.
    let(:timeline) do
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :user, content: text_blocks("query", 8))
                    .commit(role: :assistant, content: text_blocks("answer", 7))
                    .commit(role: :user, content: text_blocks("follow-up", 1))
    end

    def text_blocks(prefix, count)
      Array.new(count) { |i| { "type" => "text", "text" => "#{prefix} #{i}" } }
    end

    # The Agent's own compose line (agent.rb#call_model), reproduced so the
    # SAME timeline can be rendered under two sessions.
    def render(session)
      context.render(timeline:, toolset: Lain::Toolset.new,
                     workspace: Lain::Workspace.empty.with(*session.reminders))
    end

    it "keeps every prefix entry except the final one digest-identical across the two renders" do
      recorder = Lain::Memory::Recorder.new
      recorder.write(item("aspirin-dosing", "Aspirin dosing bounds for adults"))

      populated = render(Lain::Session.new(memory: recorder)).prefix_digests
      bare = render(Lain::Session.new).prefix_digests

      expect(populated.size).to be > 2
      expect(populated.size).to eq(bare.size)
      expect(populated[0..-2]).to eq(bare[0..-2])
      expect(populated.last).not_to eq(bare.last)
    end
  end

  describe "an empty index adds nothing to the render" do
    it "renders bytes digest-identical to a session with no memory source" do
      empty_holder = Lain::Session.new(memory: Lain::Memory::Recorder.new)
      sourceless = Lain::Session.new

      requests = [empty_holder, sourceless].map do |session|
        agent, provider = agent_over(session, responses: [text_response])
        agent.ask("hello")
        provider.last_request
      end

      expect(requests.first).to have_same_digest_as(requests.last)
    end
  end

  describe "the model can read back what it wrote, same session" do
    let(:aspirin) { item("aspirin-dosing", "Aspirin dosing bounds for adults") }
    let(:recorder) { Lain::Memory::Recorder.new }
    let(:toolset) do
      Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder:),
                         Lain::Tools::MemoryRead.new(index: recorder)])
    end

    let(:responses) do
      [tool_response(write_call("tu_1", aspirin)),
       tool_response(["tu_2", "memory_read", { "id" => "aspirin-dosing" }]),
       text_response("recalled")]
    end

    it "returns the item's verbatim body in the tool_result" do
      agent, = agent_over(Lain::Session.new(memory: recorder), responses:, toolset:)
      agent.ask("remember the aspirin bounds, then read them back")

      read_result = agent.timeline.to_a
                         .flat_map(&:content)
                         .find { |block| block["type"] == "tool_result" && block["tool_use_id"] == "tu_2" }
      expect(read_result.fetch("is_error")).to be(false)
      expect(read_result.fetch("content")).to eq(aspirin.body)
    end
  end
end
