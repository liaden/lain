# frozen_string_literal: true

require "tmpdir"

# T-D1 / PS-3: a spawned role subagent renders its PERSONA into the child's
# system -- the role prelude as SEGMENTS, segment 0 the role-invariant bulk
# (cache-marked so heterogeneous siblings share the warm prefix), segment 1 the
# role tail after the breakpoint -- NOT the parent's bare top-level system slot,
# and NOT a fused String. The persona rides an injected {Role::Persona}; with
# none wired the child renders byte-for-byte as before (that Null default is
# pinned in subagent_spec).
RSpec.describe "a spawned role's persona (PS-3)" do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  # Anonymous named capabilities: a role attenuates against tool NAMES, and the
  # child never executes a tool here (the mock settles on the first turn), so a
  # bare name is all the union needs. The superset covers researcher AND the SRE
  # reviewer so two heterogeneous roles can attenuate from one union.
  def tool(named)
    Class.new(Lain::Tool) do
      define_method(:name) { named.to_s }
      define_method(:description) { "the #{named} capability" }
      define_method(:input_schema) { { type: :object, properties: {} } }
      define_method(:perform) { |_input, _invocation| Lain::Tool::Result.ok("ok") }
    end.new
  end

  let(:union) { Lain::Toolset.new(%i[read_file list_files bash].map { |n| tool(n) }) }

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  def with_project(slots = {})
    Dir.mktmpdir do |root|
      slots.each do |rel, body|
        path = File.join(root, ".lain", "slots", "#{rel}.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      yield Lain::Prompt::Slots.load(root:)
    end
  end

  # The chat-default researcher shape: fresh/schema, read-only, persona wired
  # through the injected Slots. The context_factory renders the SAME bulk the
  # persona's segment 0 carries (backend.context's `slots.render`) -- exactly
  # the double-bulk trap the seam must resolve by REPLACING, not appending.
  def role_subagent(slots, provider:, role:)
    Lain::Tools::Subagent.new(
      provider:,
      context_factory: -> { Lain::Context.new(model: "child-model", max_tokens: 256, system: slots.render) },
      toolset: union, policy: role.spawn_policy, parent:,
      persona: Lain::Role::Persona.new(role:, slots:)
    )
  end

  def spawn(slots, role_name)
    provider = mock(text_response("done"))
    role_subagent(slots, provider:, role: Lain::Role::Catalog.fetch(role_name)).call({ "prompt" => "go" }, invocation)
    provider.last_request
  end

  it "renders the persona as two blocks -- bulk (marked) then role tail -- replacing the bare system slot" do
    with_project do |slots|
      system = spawn(slots, :researcher).system

      expect(system.size).to eq(2)
      expect(system[0]["text"]).to eq(slots.render("system"))
      expect(system[0]["cache"]).to be(true)
      expect(system[1]["text"]).to eq(slots.render_role(:researcher))
    end
  end

  it "does not double the bulk: segment 0's bytes appear exactly once in system" do
    with_project do |slots|
      system = spawn(slots, :researcher).system

      expect(system.map { |b| b["text"] }.count(slots.render("system"))).to eq(1)
    end
  end

  # The CE-4 win: two DIFFERENT roles share segment 0 (bulk) byte-for-byte and
  # the breakpoint sits ON it, so the warm tools+bulk prefix is reused; only the
  # role tail diverges. A fused String cannot deliver this.
  it "marks the shared bulk so heterogeneous siblings share the warm prefix, tails diverging" do
    with_project do |slots|
      researcher = spawn(slots, :researcher).system
      sre = spawn(slots, :reviewer_sre).system

      expect(researcher[0]["text"]).to eq(sre[0]["text"])
      expect(researcher[0]["cache"]).to be(true)
      expect(sre[0]["cache"]).to be(true)
      expect(researcher[1]["text"]).not_to eq(sre[1]["text"])
    end
  end

  # The explicit fused-String discriminator (the T24 review probe): a single
  # fused block would carry the whole joined prelude and its one mark would land
  # after the role tail -- size 1, segment 0 == the joined prelude. Segments
  # fail that: size 2, segment 0 the bulk ALONE.
  it "is not a fused String: segment 0 is the bulk alone, not the joined prelude" do
    with_project do |slots|
      role = Lain::Role::Catalog.fetch(:researcher)
      system = spawn(slots, :researcher).system

      expect(system.size).to eq(2)
      expect(system[0]["text"]).not_to eq(role.prelude(slots:))
    end
  end

  it "reaches a role slot override into the child, leaving sibling roles unaffected" do
    with_project("role/researcher" => "OVERRIDE 7: cite primary sources only.") do |slots|
      researcher = spawn(slots, :researcher).system
      sre = spawn(slots, :reviewer_sre).system

      expect(researcher[1]["text"]).to include("OVERRIDE 7")
      expect(sre[1]["text"]).not_to include("OVERRIDE 7")
    end
  end

  it "keeps the researcher read-only: schema posture renders exactly its only-set, no capability change" do
    with_project do |slots|
      tools = spawn(slots, :researcher).tools

      expect(tools.map { |t| t["name"] }).to match_array(%w[read_file list_files])
    end
  end

  # The ≤4-mark invariant, PINNED PENDING. Segment 0 carries the seam's mark AND
  # Context#cache_marked marks the last system block (the role tail), so a role
  # child renders TWO system marks; once CacheBreakpoints spends its cap-1 = 3
  # message budget, the wire carries 5 cache_control blocks -- past Anthropic's
  # 4-cap, a latent 400. The fix is OUT of this card's file scope (it lives in
  # Context/CacheBreakpoints: move the role tail into a seed MESSAGE after the
  # breakpoint so system holds ONE block -- SpawnPolicy::SiblingTemplate's
  # existing doctrine). This pin fails today (green suite, visible known-failure)
  # and flips to a real failure the moment persona is wired into exe without the
  # Context fix.
  it "sends no more than Anthropic's 4 cache_control blocks for a long-lived role child",
     pending: "role tail belongs in a seed message; fix lives in Context/CacheBreakpoints -- see follow-up" do
    with_project do |slots|
      child = Lain::Role::Catalog.fetch(:researcher).child_context(
        Lain::Context.new(model: "child-model", max_tokens: 256, system: slots.render), slots:
      )
      # Pile up content blocks (EVERY = 15) so CacheBreakpoints places its full
      # cap-1 message budget on top of the two system marks.
      timeline = 30.times.inject(Lain::Timeline.empty(store:)) do |t, i|
        t.commit(role: i.even? ? :user : :assistant,
                 content: Array.new(4) { { "type" => "text", "text" => "block #{i}" } })
      end
      request = child.render(timeline:, toolset: union)

      wire_marks = request.system.count { |b| b["cache"] } +
                   request.messages.sum { |m| m["content"].count { |b| b["cache"] } }
      expect(wire_marks).to be <= 4
    end
  end
end
