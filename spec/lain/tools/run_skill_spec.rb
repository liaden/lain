# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::RunSkill do
  # A throwaway skills tree the Catalog loads, wrapped in a real Skill::Renderer
  # -- run_skill is the in-agent composition primitive, so it renders the SAME
  # way the repl's SkillDispatch does (scaffold, then args after a blank line),
  # and the spec exercises the real renderer rather than a stub of it.
  def with_renderer(shipped:)
    Dir.mktmpdir do |root|
      shipped_dir = File.join(root, "shipped")
      shipped.each { |path, body| write(File.join(shipped_dir, path), body) }
      catalog = Lain::Skill::Catalog.load(root:, shipped_dir:)
      slots = Lain::Prompt::Slots.load(root:, skill_shipped_dir: shipped_dir)
      yield Lain::Skill::Renderer.new(catalog:, slots:)
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  # A skill with no holes: its scaffold is guidance the calling agent reads next.
  def critique(body: "# Critique\n\nReview the target rigorously.")
    { "critique/skill.md" => body }
  end

  # A handful of independent, no-hole skills, to prove the budget is cumulative
  # and cross-skill (not a per-skill or nesting counter).
  def several_skills
    { "one/skill.md" => "SKILL ONE", "two/skill.md" => "SKILL TWO",
      "three/skill.md" => "SKILL THREE" }
  end

  it "has a model-facing name and description" do
    with_renderer(shipped: critique) do |renderer|
      tool = described_class.new(renderer:)
      expect(tool.name).to eq("run_skill")
      expect(tool.description).to be_a(String)
      expect(tool.description).not_to be_empty
    end
  end

  it "renders text only, so it is not gated by approval" do
    with_renderer(shipped: critique) do |renderer|
      expect(described_class.new(renderer:).requires_approval?).to be(false)
    end
  end

  describe "AC: the agent invokes a skill at runtime" do
    it "returns the rendered scaffold plus the args as the tool_result the caller reads next" do
      with_renderer(shipped: critique) do |renderer|
        tool = described_class.new(renderer:)

        result = tool.call({ name: "critique", args: "the plan at planning/specs/foo.md" })

        expect(result).to have_attributes(is_error: false)
        expect(result.content).to include("Review the target rigorously.")
        expect(result.content).to include("the plan at planning/specs/foo.md")
      end
    end

    it "returns the bare scaffold with no trailing blank when args are omitted" do
      with_renderer(shipped: critique) do |renderer|
        tool = described_class.new(renderer:)

        result = tool.call({ name: "critique" })

        expect(result).to have_attributes(is_error: false)
        expect(result.content).to eq("# Critique\n\nReview the target rigorously.")
      end
    end

    it "treats an explicitly empty args string as argless -- the bare scaffold" do
      with_renderer(shipped: critique) do |renderer|
        tool = described_class.new(renderer:)

        result = tool.call({ name: "critique", args: "" })

        expect(result.content).to eq("# Critique\n\nReview the target rigorously.")
      end
    end

    it "appends multiline args verbatim after a single blank line" do
      with_renderer(shipped: critique) do |renderer|
        tool = described_class.new(renderer:)

        result = tool.call({ name: "critique", args: "line one\nline two\nline three" })

        expect(result.content).to eq(
          "# Critique\n\nReview the target rigorously.\n\nline one\nline two\nline three"
        )
      end
    end
  end

  describe "AC: an unknown skill is a loud tool error, not a crash" do
    it "returns an error Result naming the unknown skill" do
      with_renderer(shipped: critique) do |renderer|
        tool = described_class.new(renderer:)

        result = nil
        expect { result = tool.call({ name: "nope" }) }.not_to raise_error
        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("nope")
      end
    end
  end

  describe "AC: a static include cycle is caught at render time" do
    it "returns an error Result rather than hanging when a skill includes itself transitively" do
      shipped = {
        "a/skill.md" => "---\nincludes:\n  - b\n---\n<%= render(\"b\") %>",
        "b/skill.md" => "---\nincludes:\n  - a\n---\n<%= render(\"a\") %>"
      }
      with_renderer(shipped:) do |renderer|
        tool = described_class.new(renderer:)

        result = nil
        expect { result = tool.call({ name: "a" }) }.not_to raise_error
        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("a")
        expect(result.content).to include("b")
      end
    end
  end

  describe "AC: dispatch-time recursion is bounded (a per-run invocation budget)" do
    it "refuses a further run_skill once the configured budget is exhausted" do
      with_renderer(shipped: critique) do |renderer|
        tool = described_class.new(renderer:, max_invocations: 2)

        first = tool.call({ name: "critique" })
        second = tool.call({ name: "critique" })
        third = tool.call({ name: "critique" })

        expect(first).to have_attributes(is_error: false)
        expect(second).to have_attributes(is_error: false)
        expect(third).to have_attributes(is_error: true)
        expect(third.content).to match(/budget/)
      end
    end

    # The budget is CUMULATIVE and CROSS-SKILL -- it charges every call, whatever
    # skill, and never resets -- so exhausting it with three DIFFERENT skills
    # makes those session-quota semantics visible (it is not a per-skill or a
    # nesting counter).
    it "charges every call cumulatively across different skills" do
      with_renderer(shipped: several_skills) do |renderer|
        tool = described_class.new(renderer:, max_invocations: 2)

        expect(tool.call({ name: "one" })).to have_attributes(is_error: false)
        expect(tool.call({ name: "two" })).to have_attributes(is_error: false)
        third = tool.call({ name: "three" })

        expect(third).to have_attributes(is_error: true)
        expect(third.content).to match(/budget/)
      end
    end

    it "never crashes the loop when the budget is exhausted -- it returns an error Result" do
      with_renderer(shipped: critique) do |renderer|
        tool = described_class.new(renderer:, max_invocations: 0)

        result = nil
        expect { result = tool.call({ name: "critique" }) }.not_to raise_error
        expect(result).to have_attributes(is_error: true)
      end
    end
  end
end
