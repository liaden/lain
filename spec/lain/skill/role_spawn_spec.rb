# frozen_string_literal: true

require "tmpdir"

# The call-time role-selecting spawn seam (T-D2): (role_name, context_mode,
# prompt) -> subagent result. It fetches the role (loud on unknown, BEFORE any
# spawn), builds a one-shot Subagent under that role's policy and persona with
# the chosen prefix, and runs the prompt to a single final result synchronously.
RSpec.describe Lain::Skill::RoleSpawn do
  # A shared Store and a two-turn parent chain whose head is H -- the inherit
  # mode forks it, the fresh mode does not.
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }

  # The union a role attenuates FROM must hold every tool the role names, or
  # Toolset#only fails loudly. This is the dev role's full set (plus is fine).
  let(:union) do
    Lain::Toolset.new([
                        Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                        Lain::Tools::Grep.new, Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new,
                        Lain::Tools::TodoWrite.new, Lain::Tools::Bash.new
                      ])
  end

  around do |example|
    Dir.mktmpdir do |root|
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  attr_reader :slots

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  def seam(provider:, parent: self.parent, **extra)
    described_class.new(
      provider:, context_factory: -> { child_context }, toolset: union, parent:, slots:, **extra
    )
  end

  # ---- AC1: a chosen role at call time, inherit prefix, persona in system ----

  it "spawns the chosen role's only-set with an inherit prefix and the role persona in system" do
    provider = mock(text_response("done"))
    seam(provider:).call(:dev, :inherit, "go")

    request = provider.last_request

    # The dev only-set, rendered under the default schema posture.
    expect(request.tools.map { |t| t["name"] })
      .to match_array(%w[read_file list_files glob grep edit_file write_file todo_write bash])

    # inherit prefix: the child forked the parent, so H's turns precede the prompt.
    expect(request.messages.first["content"].first["text"]).to eq("hi")

    # The dev persona reshaped the child's system into the two prelude segments.
    expect(request.system.size).to eq(2)
    expect(request.system.first["text"]).to eq(slots.render("system"))
    expect(request.system.first["cache"]).to be(true)
    expect(request.system.last["text"]).to eq(slots.render_role(:dev))
  end

  # ---- AC2: the fresh context mode -- no inherited parent conversation -------

  it "honors the fresh context mode: the child inherits none of the parent's conversation" do
    provider = mock(text_response("done"))
    seam(provider:).call(:dev, :fresh, "go")

    request = provider.last_request
    texts = request.messages.flat_map { |m| Array(m["content"]).map { |b| b["text"] } }
    expect(texts).not_to include("hi", "yo")
    expect(request.messages.first["content"].first["text"]).to eq("go")
  end

  # ---- AC3: run the prompt to a single final result, synchronously -----------

  it "runs the prompt to a single final result, returned synchronously" do
    provider = mock(text_response("the final answer"))
    result = seam(provider:).call(:dev, :fresh, "compute it")

    expect(result).to be_ok
    expect(result.content).to eq("the final answer")
  end

  # ---- SHOULD-FIX: the injected observer reaches the spawned child's Lineage -
  #
  # exe/lain wires the real Subagent with `observer: chronicle.observer` so the
  # child's :spawn/:message lineage reaches the session scribe. Once B3 drives
  # `@role/skill` spawns through this seam, an unforwarded observer would land
  # the child's lineage on the Null chain writer -- "silent record loss one
  # level up" (subagent.rb's own words). The seam must forward it.

  it "forwards an injected observer so the spawned child's spawn/message lineage reaches it" do
    seen = []
    provider = mock(text_response("done"))
    seam(provider:, observer: seen.method(:push)).call(:dev, :fresh, "go")

    expect(seen.map(&:kind)).to eq(%i[spawn message])
  end

  # ---- AC4: an unknown role fails loudly, before any spawn -------------------

  it "raises Role::Catalog::Unknown for an unknown role, spending no tokens" do
    provider = mock(text_response("unused"))
    subject_seam = seam(provider:)

    expect { subject_seam.call(:nope, :fresh, "go") }
      .to raise_error(Lain::Role::Catalog::Unknown, /nope.*expected one of/m)
    expect(provider.call_count).to eq(0)
  end
end
