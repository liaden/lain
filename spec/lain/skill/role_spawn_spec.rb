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

    # The dev only-set, rendered under the default schema posture -- plus the
    # `ask_human` T10 grants every child on top of its role's set, which no
    # role in the catalog names and every posture permits.
    expect(request.tools.map { |t| t["name"] })
      .to match_array(%w[read_file list_files glob grep edit_file write_file todo_write bash ask_human])

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

    # T2 widened the funnel: the child's OWN turns ride it between the two
    # lineage events, because the session record cannot reach them any other
    # way (a Timeline walk sees one chain, and the scribe's is the parent's).
    # Here that is the seeded user turn and the child's single reply.
    expect(seen.map(&:kind)).to eq(%i[spawn turn turn message])
  end

  # ---- AC4: an unknown role fails loudly, before any spawn -------------------

  it "raises Role::Catalog::Unknown for an unknown role, spending no tokens" do
    provider = mock(text_response("unused"))
    subject_seam = seam(provider:)

    expect { subject_seam.call(:nope, :fresh, "go") }
      .to raise_error(Lain::Role::Catalog::Unknown, /nope.*expected one of/m)
    expect(provider.call_count).to eq(0)
  end

  # ---- T23: one Seam held, and per-call work that is role selection only -----
  #
  # This class's own doc already says it "holds the same collaborator set the
  # exe's research_subagent assembles" -- the same six, written out twice. Held
  # as one value, what is FIXED at construction and what is CHOSEN per call stop
  # being interleaved in one nine-keyword signature.
  #
  # Every other example above constructs with the loose keywords, so their green
  # beside this block's is the additive claim: both styles are valid.
  describe "the spawn Seam" do
    def seam_value(provider:, **extra)
      Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context }, parent:, **extra)
    end

    it "spawns over an injected seam, holding no loose collaborators of its own" do
      value = seam_value(provider: mock(text_response("done")))
      spawn = described_class.new(seam: value, toolset: union, slots:)

      expect(spawn.call(:dev, :fresh, "go")).to be_ok
      expect(spawn.seam).to be(value)
    end

    # The role is the per-call variable; the seam is not. Two calls through one
    # instance pick two different only-sets while every collaborator -- here the
    # observer carrying each child's lineage -- stays the same object.
    it "chooses the role per call and leaves the held seam untouched" do
      seen = []
      provider = mock(text_response("a"), text_response("b"))
      spawn = described_class.new(seam: seam_value(provider:, observer: seen.method(:push)),
                                  toolset: union, slots:)

      spawn.call(:dev, :fresh, "one")
      dev_tools = provider.last_request.tools.map { |tool| tool["name"] }
      spawn.call(:reviewer_sre, :fresh, "two")

      expect(provider.last_request.tools.map { |tool| tool["name"] })
        .to match_array(%w[read_file list_files bash ask_human])
      expect(dev_tools.size).to eq(9)
      expect(seen.map(&:kind)).to eq(%i[spawn turn turn message spawn turn turn message])
    end

    it "refuses a seam and its loose members together, naming the member" do
      provider = mock(text_response("unused"))

      expect { described_class.new(seam: seam_value(provider:), provider:, toolset: union, slots:) }
        .to raise_error(ArgumentError, "pass seam: or its members [:provider], not both")
    end

    it "refuses a loose keyword that is not a seam member" do
      expect do
        described_class.new(provider: mock(text_response("unused")), context_factory: -> { child_context },
                            parent:, observers: [], toolset: union, slots:)
      end.to raise_error(ArgumentError, /unknown keyword: :observers/)
    end

    # A typo beside a seam is a typo, not a both-at-once conflict.
    it "calls a misspelled keyword beside a seam a typo, not a conflict" do
      expect do
        described_class.new(seam: seam_value(provider: mock(text_response("unused"))),
                            toolset: union, slots:, max_dept: 2)
      end.to raise_error(ArgumentError, "unknown keyword: :max_dept")
    end
  end
end
