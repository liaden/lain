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

  describe "AC: an oversized expansion is bounded" do
    # A tiny ceiling, so an oversized fixture costs a few bytes rather than the
    # 64 KiB the shipped one would need. The bound is injected as the tool takes
    # it, so the seam the wiring would use is the seam under test.
    def bounded(renderer, limit)
      ceiling = described_class::Ceiling.new(bound: Lain::Tool::Bounds::Handback.new(limit:))
      described_class.new(renderer:, ceiling:)
    end

    # Under the ceiling: nothing about the bound is visible on the ordinary
    # path, which is the whole point of it.
    it "hands back an ordinary expansion unchanged" do
      with_renderer(shipped: critique) do |renderer|
        result = described_class.new(renderer:).call({ name: "critique" })

        expect(result).to have_attributes(is_error: false)
        expect(result.content).to eq("# Critique\n\nReview the target rigorously.")
      end
    end

    it "answers an oversized expansion with its size, the ceiling and something narrower to do" do
      with_renderer(shipped: critique(body: "short")) do |renderer|
        result = bounded(renderer, 64).call({ name: "critique", args: "z" * 200 })

        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("207 bytes")
        expect(result.content).to include("ceiling of 64")
        expect(result.content).to include("critique")
        expect(result.content).to include("run_skill again with shorter args")
      end
    end

    # The scaffold overran on its own, so the args are not the lever and saying
    # they are would name the very call that was just refused. The renderer is
    # pure, so this refusal is permanent for this skill and the sentence says so.
    it "offers no args advice when the scaffold alone overran" do
      with_renderer(shipped: critique(body: "y" * 200)) do |renderer|
        result = bounded(renderer, 64).call({ name: "critique" })

        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("200 bytes")
        expect(result.content).to include("renders the same bytes every time")
        expect(result.content).to include("run a narrower skill")
        expect(result.content).not_to include("args")
      end
    end

    # The general case of the same defect, and the one a real invocation hits:
    # run_skill exists to pull guidance in against a concrete target, so an
    # oversized skill is usually called WITH args. Emptiness is the wrong
    # question -- three bytes of args on a scaffold that overruns on its own is
    # still a scaffold that overruns.
    it "offers no args advice when dropping every arg would still overrun" do
      with_renderer(shipped: critique(body: "y" * 200)) do |renderer|
        result = bounded(renderer, 64).call({ name: "critique", args: "abc" })

        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("renders the same bytes every time")
        expect(result.content).not_to include("args")
      end
    end

    # The size it is told is the one it cannot get below. 205 would name a total
    # the model could shave three bytes off and be refused all over again.
    it "reports the scaffold's own size, not the total it cannot reach" do
      with_renderer(shipped: critique(body: "y" * 200)) do |renderer|
        result = bounded(renderer, 64).call({ name: "critique", args: "abc" })

        expect(result.content).to include("200 bytes")
        expect(result.content).not_to include("205")
      end
    end

    # The refusal exists to keep the bytes OUT of the context, so a message that
    # quoted or previewed them would defeat it exactly.
    it "returns none of the oversized bytes" do
      with_renderer(shipped: critique(body: "MARKER-#{"y" * 200}")) do |renderer|
        result = bounded(renderer, 64).call({ name: "critique" })

        expect(result.content).not_to include("MARKER")
        expect(result.content).not_to include("yyyy")
      end
    end

    # The args the model supplies are part of what lands in context, so they are
    # part of what is measured -- which is what makes "call it with shorter args"
    # a move the model can actually take.
    it "measures the args along with the scaffold" do
      with_renderer(shipped: critique(body: "short")) do |renderer|
        tool = bounded(renderer, 64)

        expect(tool.call({ name: "critique" })).to have_attributes(is_error: false)
        expect(tool.call({ name: "critique", args: "z" * 200 })).to have_attributes(is_error: true)
      end
    end

    # BYTES, not characters. Every other fixture here is ASCII, where the two
    # agree; this one is the difference, and without it the ceiling could
    # silently loosen severalfold for non-Latin guidance.
    it "measures bytes rather than characters" do
      with_renderer(shipped: critique(body: "é" * 33)) do |renderer|
        result = bounded(renderer, 64).call({ name: "critique" })

        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("66 bytes")
      end
    end

    it "refuses at the shipped ceiling with nothing injected" do
      limit = Lain::Tools::RunSkill::EXPANSION_BOUND.limit
      with_renderer(shipped: critique(body: "y" * (limit + 1))) do |renderer|
        result = described_class.new(renderer:).call({ name: "critique" })

        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("ceiling of #{limit}")
      end
    end

    # A model told the number can shorten its args and never issue the refused
    # call at all; one told only "too large" has to discover it by being refused.
    it "names the ceiling in the description the model reads" do
      with_renderer(shipped: critique) do |renderer|
        expect(described_class.new(renderer:).description)
          .to include(Lain::Tools::RunSkill::EXPANSION_BOUND.limit.to_s)
      end
    end

    it "is a value object two tools may share" do
      expect(Ractor.shareable?(described_class::Ceiling.new)).to be(true)
    end

    # A bound is not an exception: the refusal is an answer the loop continues
    # past, so the very next call still works.
    it "leaves the tool usable after a refusal" do
      shipped = { "huge/skill.md" => "y" * 200, "small/skill.md" => "SMALL" }
      with_renderer(shipped:) do |renderer|
        tool = bounded(renderer, 64)

        expect(tool.call({ name: "huge" })).to have_attributes(is_error: true)
        expect(tool.call({ name: "small" })).to have_attributes(is_error: false, content: "SMALL")
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
        expect(third.content).to include("budget")
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
        expect(third.content).to include("budget")
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
