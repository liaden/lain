# frozen_string_literal: true

require "tmpdir"

# GG-2: approved Criteria -> the `gherkin-tests` skill scaffold, rendered and
# dispatched through a REAL {Lain::Skill::RoleSpawn} to `test_engineer` over a
# {Lain::Provider::Mock} -- the role_spawn_spec pattern, so this spec doubles
# as proof the shipped `gherkin-tests/skill.md` actually loads and renders.
RSpec.describe Lain::Gherkin::TestGeneration do
  let(:store) { Lain::Store.new }
  let(:parent) { Lain::Timeline.empty(store:) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }

  # test_engineer's only-set (role/catalog.rb) -- the union it attenuates from
  # must hold every tool the role names.
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

  let(:catalog) { Lain::Skill::Catalog.load }
  let(:renderer) { Lain::Skill::Renderer.new(catalog:, slots:) }

  let(:criteria) do
    Lain::Gherkin::Criteria.parse(<<~MD)
      ```gherkin
      Scenario: the widget renders
        Given a mounted widget
        When it renders
        Then the markup is present

      # rubric
      Scenario: the widget feels right
        Given a mounted widget
        Then a human judges the feel
      ```
    MD
  end

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  def role_spawn(provider:)
    Lain::Skill::RoleSpawn.new(provider:, context_factory: -> { child_context }, toolset: union, parent:, slots:)
  end

  def generation(provider:)
    described_class.new(renderer:, role_spawn: role_spawn(provider:))
  end

  # ---- AC: the scaffold reaches the test-engineer with the criteria digest ---

  it "spawns test_engineer fresh with the mechanical scenario, the framework, and no rubric text" do
    provider = mock(text_response("wrote the spec"))

    generation(provider:).call(criteria, framework: "rspec")

    request = provider.last_request
    prompt = request.messages.first["content"].first["text"]

    # fresh context mode: the child's first message IS the rendered prompt.
    expect(prompt).to include("the widget renders", "Given a mounted widget", "rspec")
    expect(prompt).not_to include("the widget feels right", "a human judges the feel")

    # role: test_engineer, persona in system.
    expect(request.system.last["text"]).to eq(slots.render_role(:test_engineer))
  end

  it "returns a record wrapping the child's result, the criteria digest, and the rubric split" do
    provider = mock(text_response("wrote the spec"))

    record = generation(provider:).call(criteria, framework: "rspec")

    expect(record.result).to be_ok
    expect(record.result.content).to eq("wrote the spec")
    expect(record.criteria_digest).to eq(criteria.digest)
    expect(record.rubric_scenarios.map(&:name)).to eq(["the widget feels right"])
    expect(record.rubric_scenarios.first).to be_a(Lain::Gherkin::Scenario)
  end

  it "digest and rubric_scenarios are Ractor-shareable" do
    provider = mock(text_response("wrote the spec"))
    record = generation(provider:).call(criteria, framework: "rspec")

    expect(Ractor.shareable?(record.criteria_digest)).to be(true)
    expect(Ractor.shareable?(record.rubric_scenarios)).to be(true)
  end

  # ---- panel fix: an all-rubric Criteria must not silently spawn a no-op ------

  let(:all_rubric_criteria) do
    Lain::Gherkin::Criteria.parse(<<~MD)
      ```gherkin
      # rubric
      Scenario: the widget feels right
        Given a mounted widget
        Then a human judges the feel
      ```
    MD
  end

  it "raises NothingMechanical naming the digest, spawning nothing, when every scenario is rubric-flagged" do
    provider = mock(text_response("unused"))

    expect { generation(provider:).call(all_rubric_criteria, framework: "rspec") }
      .to raise_error(Lain::Gherkin::TestGeneration::NothingMechanical, /#{Regexp.escape(all_rubric_criteria.digest)}/)
    expect(provider.call_count).to eq(0)
  end
end
