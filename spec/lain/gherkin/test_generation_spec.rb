# frozen_string_literal: true

require "tmpdir"

# Approved Criteria -> the `gherkin-tests` skill scaffold, rendered and
# dispatched through a REAL {Lain::Skill::RoleSpawn} to `test_engineer` over a
# {Lain::Provider::Mock} -- the role_spawn_spec pattern, so this spec doubles
# as proof the shipped `gherkin-tests/skill.md` actually loads and renders.
#
# Tests go where the project's layout says: the prompt names the exact target
# path the layout mirrors from the subject, and afterwards the call reports
# whether the child created or changed that file and what the guard says of it.
RSpec.describe Lain::Gherkin::TestGeneration do
  let(:layout_mini) { File.expand_path("../../fixtures/projects/layout_mini", __dir__) }
  let(:store) { Lain::Store.new }
  let(:parent) { Lain::Timeline.empty(store:) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:guard) { Lain::TestLayout::Guard.new(layout: Lain::Config.test_layout(root:), root:) }
  let(:target) { "spec/unit/models/order_spec.rb" }

  # test_engineer's only-set (role/catalog.rb) -- the union it attenuates from
  # must hold every tool the role names.
  let(:union) do
    Lain::Toolset.new([
                        Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                        Lain::Tools::Grep.new, Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new,
                        Lain::Tools::TodoWrite.new, Lain::Tools::Bash.new
                      ])
  end
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

  around do |example|
    Dir.mktmpdir do |root|
      FileUtils.cp_r(File.join(layout_mini, "."), root)
      @root = root
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  attr_reader :slots, :root

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  def role_spawn(provider:)
    Lain::Skill::RoleSpawn.new(provider:, context_factory: -> { child_context }, toolset: union, parent:, slots:)
  end

  def generation(spawn) = described_class.new(renderer:, role_spawn: spawn, guard:)

  def generate(spawn, with: criteria)
    generation(spawn).call(with, subject: "app/models/order.rb", level: "unit")
  end

  def prompt_of(provider) = provider.last_request.messages.first["content"].first["text"]

  def write(relative, body = "RSpec.describe Order do\nend\n")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  # A child that writes files as it runs, standing in for a real one's tool calls.
  def child_writing(files)
    lambda do |_role, _mode, _prompt|
      files.each { |relative, body| write(relative, body) }
      Lain::Tool::Result.ok("done")
    end
  end

  it "spawns test_engineer fresh with the mechanical scenario, the layout's framework, and no rubric text" do
    provider = mock(text_response("wrote the spec"))

    generate(role_spawn(provider:))

    # fresh context mode: the child's first message IS the rendered prompt.
    expect(prompt_of(provider)).to include("the widget renders", "Given a mounted widget", "rspec")
    expect(prompt_of(provider)).not_to include("the widget feels right", "a human judges the feel")
    expect(provider.last_request.system.last["text"]).to eq(slots.render_role(:test_engineer))
  end

  describe "the target path" do
    it "names spec/unit/models/order_spec.rb in the prompt, and reports it missing when the child wrote elsewhere" do
      provider = mock(text_response("wrote spec/models/order_spec.rb"))
      write("spec/models/order_spec.rb")

      record = generate(role_spawn(provider:))

      expect(prompt_of(provider)).to include(target, "app/models/order.rb")
      expect(record).to have_attributes(target:, missing?: true, generated?: false)
      expect(record.verdict.rule).to eq(:missing)
    end

    it "refuses before spawning when the layout cannot place the subject's tests" do
      provider = mock(text_response("unused"))

      expect { generation(role_spawn(provider:)).call(criteria, subject: "lib/order.rb", level: "unit") }
        .to raise_error(Lain::TestLayout::Unplaceable, %r{lib/order\.rb})
      expect(provider.call_count).to eq(0)
    end
  end

  # Whether the child did the work is a comparison of the target before and
  # after the spawn, and whether the work is in the right place is the guard's.
  describe "what the child did to the target" do
    it "reads a target the child created, describing the subject, as generated" do
      record = generate(child_writing(target => "RSpec.describe Order do\nend\n"))

      expect(record).to have_attributes(created?: true, changed?: false, generated?: true)
      expect(record.verdict.rule).to eq(:mirrors)
    end

    # Test generation runs before the implementation, so a correctly placed
    # test for a class that does not exist yet is the expected outcome.
    it "counts a correctly placed test written before its class as generated" do
      record = generation(child_writing("spec/unit/models/refund_spec.rb" => "RSpec.describe Refund do\nend\n"))
               .call(criteria, subject: "app/models/refund.rb", level: "unit")

      expect(record).to have_attributes(created?: true, generated?: true)
      expect(record.verdict.rule).to eq(:no_source)
    end

    it "does not count a target written with the wrong subject, and carries the guard's refusal" do
      record = generate(child_writing(target => "RSpec.describe OrderRecord do\nend\n"))

      expect(record).to have_attributes(created?: true, generated?: false)
      expect(record.verdict.rule).to eq(:elsewhere)
    end

    it "reads a pre-existing target the child left alone while writing a sibling as not generated" do
      write(target, "RSpec.describe Order do\n  it(\"old\") { }\nend\n")

      record = generate(child_writing("spec/unit/models/order_new_spec.rb" => "RSpec.describe Order do\nend\n"))

      expect(record).to have_attributes(created?: false, changed?: false, missing?: false, generated?: false)
    end

    it "reads a pre-existing target the child added to as changed and generated" do
      write(target, "RSpec.describe Order do\nend\n")

      record = generate(child_writing(target => "RSpec.describe Order do\n  it(\"totals\") { }\nend\n"))

      expect(record).to have_attributes(created?: false, changed?: true, generated?: true)
    end
  end

  it "returns a record wrapping the child's result, the criteria digest, and the rubric split" do
    record = generate(role_spawn(provider: mock(text_response("wrote the spec"))))

    expect(record.result).to be_ok
    expect(record.result.content).to eq("wrote the spec")
    expect(record.criteria_digest).to eq(criteria.digest)
    expect(record.rubric_scenarios.map(&:name)).to eq(["the widget feels right"])
    expect(record.rubric_scenarios.first).to be_a(Lain::Gherkin::Scenario)
  end

  it "is Ractor-shareable in every field it adds" do
    record = generate(child_writing(target => "RSpec.describe Order do\nend\n"))

    expect([record.criteria_digest, record.target, record.rubric_scenarios, record.before, record.after,
            record.verdict]).to all(be_deeply_frozen)
  end

  it "raises NothingMechanical naming the digest, spawning nothing, when every scenario is rubric-flagged" do
    provider = mock(text_response("unused"))

    expect { generate(role_spawn(provider:), with: all_rubric_criteria) }
      .to raise_error(Lain::Gherkin::TestGeneration::NothingMechanical, /#{Regexp.escape(all_rubric_criteria.digest)}/)
    expect(provider.call_count).to eq(0)
  end
end
