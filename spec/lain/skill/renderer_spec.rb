# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Skill::Renderer do
  # A throwaway project tree: a "shipped" skill dir (scaffold + hole defaults)
  # the catalog loads, plus an optional `.lain/slots/skill/<skill>/<hole>.md`
  # override tree the Slots read. Rendering is session-fixed and pure: loaded
  # once from disk here, then composed in memory.
  def with_project(shipped: {}, overrides: {})
    Dir.mktmpdir do |root|
      shipped_dir = File.join(root, "shipped")
      shipped.each { |path, body| write(File.join(shipped_dir, path), body) }
      overrides.each do |(skill, hole), body|
        write(File.join(root, ".lain", "slots", "skill", skill, "#{hole}.md"), body)
      end
      catalog = Lain::Skill::Catalog.load(root:, shipped_dir:)
      slots = Lain::Prompt::Slots.load(root:, skill_shipped_dir: shipped_dir)
      yield described_class.new(catalog:, slots:)
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  # A minimal shipped skill: front-matter declaring one hole, a scaffold that
  # places that hole with the `render` helper.
  def create_plan(scaffold: "# Create plan\n\n<%= render(\"conventions\") %>\n")
    { "create-plan/skill.md" => "---\nslots:\n  - conventions\n---\n#{scaffold}" }
  end

  describe "a skill scaffold renders with its user slot fills injected" do
    it "puts the override file's conventions markdown at the hole, verbatim" do
      with_project(
        shipped: create_plan.merge("create-plan/conventions.md" => "SHIPPED default conventions"),
        overrides: { %w[create-plan conventions] => "USER CONVENTIONS 42: prefer haiku." }
      ) do |renderer|
        rendered = renderer.render("create-plan")

        expect(rendered).to include("USER CONVENTIONS 42: prefer haiku.")
        expect(rendered).to include("# Create plan")
        expect(rendered).not_to include("SHIPPED default conventions")
      end
    end
  end

  describe "a missing skill slot falls back to the shipped default" do
    it "fills the hole from the shipped default and renders successfully" do
      with_project(
        shipped: create_plan.merge("create-plan/conventions.md" => "SHIPPED default conventions")
      ) do |renderer|
        rendered = nil
        expect { rendered = renderer.render("create-plan") }.not_to raise_error
        expect(rendered).to include("SHIPPED default conventions")
      end
    end
  end

  describe "static include inlines another skill, cycle-guarded" do
    it "inlines B's rendered scaffold into A" do
      shipped = {
        "a/skill.md" => "---\nincludes:\n  - b\n---\nA-top <%= render(\"b\") %> A-tail",
        "b/skill.md" => "B-body"
      }
      with_project(shipped:) do |renderer|
        expect(renderer.render("a")).to eq("A-top B-body A-tail")
      end
    end

    it "raises Lain::Prompt::CircularSlot naming the A -> B -> A cycle, no infinite loop" do
      shipped = {
        "a/skill.md" => "---\nincludes:\n  - b\n---\n<%= render(\"b\") %>",
        "b/skill.md" => "---\nincludes:\n  - a\n---\n<%= render(\"a\") %>"
      }
      with_project(shipped:) do |renderer|
        expect { renderer.render("a") }
          .to raise_error(Lain::Prompt::CircularSlot) { |e|
            expect(e.message).to include("a")
            expect(e.message).to include("b")
          }
      end
    end
  end

  describe "a scaffold reference that is neither a slot nor an include is loud" do
    it "raises rather than splicing an empty string" do
      with_project(shipped: { "a/skill.md" => "<%= render(\"ghost\") %>" }) do |renderer|
        expect { renderer.render("a") }
          .to raise_error(Lain::Prompt::UnknownSlot, /ghost/)
      end
    end
  end

  # The composition splices ALREADY-RENDERED fragments; it must never feed them
  # back through ERB. A fragment whose OUTPUT bytes look like ERB (`<%-`, `<%%`)
  # would be re-parsed and silently mangled on a second pass -- a verbatim-
  # injection violation and the bench's cardinal no-silent-truncation sin.
  describe "composition splices pre-rendered fragments without a second ERB pass" do
    it "keeps a hole fill whose OUTPUT contains ERB-looking bytes, verbatim" do
      # `50%% off <%%- code` renders ONCE (in render_skill) to `50%% off <%- code`;
      # those bytes must survive composition, not be re-parsed and truncated.
      with_project(
        shipped: create_plan.merge("create-plan/conventions.md" => "ignored default"),
        overrides: { %w[create-plan conventions] => "50%% off <%%- code" }
      ) do |renderer|
        expect(renderer.render("create-plan")).to include("50%% off <%- code")
      end
    end

    it "keeps an included skill whose scaffold OUTPUT contains ERB-looking bytes, verbatim" do
      shipped = {
        "a/skill.md" => "---\nincludes:\n  - b\n---\nA[<%= render(\"b\") %>]",
        "b/skill.md" => "B-body <%%- silent"
      }
      with_project(shipped:) do |renderer|
        expect(renderer.render("a")).to eq("A[B-body <%- silent]")
      end
    end
  end

  describe "rendering is pure and byte-stable" do
    it "produces byte-identical output across repeated renders" do
      with_project(
        shipped: create_plan.merge("create-plan/conventions.md" => "steady"),
        overrides: { %w[create-plan conventions] => "steady override" }
      ) do |renderer|
        expect(renderer.render("create-plan")).to eq(renderer.render("create-plan"))
      end
    end

    it "raises ImpureSlot for a Time.now reference in the scaffold" do
      with_project(shipped: { "a/skill.md" => "Now: <%= Time.now %>" }) do |renderer|
        expect { renderer.render("a") }
          .to raise_error(Lain::Prompt::ImpureSlot, /Time/)
      end
    end

    it "raises ImpureSlot for a Time.now reference in a hole fill" do
      with_project(
        shipped: create_plan.merge("create-plan/conventions.md" => "ok"),
        overrides: { %w[create-plan conventions] => "Now: <%= Time.now %>" }
      ) do |renderer|
        expect { renderer.render("create-plan") }
          .to raise_error(Lain::Prompt::ImpureSlot, /Time/)
      end
    end
  end
end
