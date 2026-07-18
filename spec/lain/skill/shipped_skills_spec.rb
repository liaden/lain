# frozen_string_literal: true

require "tmpdir"

# The three skills Lain SHIPS -- create-plan, execute-plan, critique -- exercised
# against the REAL templates/skill tree (not a fixture), so this spec is the
# acceptance test that the shipped scaffolds genuinely load, render, and encode
# process. Loaded once from disk, composed in memory: the same session-fixed,
# pure render every other slot uses.
RSpec.describe "shipped skills" do
  # The names Lain ships. A method, not a constant in the example-group class,
  # so re-loading the spec never warns on a constant redefinition.
  def shipped_names = %i[create-plan execute-plan critique]

  # A renderer over the REAL shipped skills. `root` is where the project's
  # `.lain/` overrides live; default it at an empty tmpdir so no stray user skill
  # or slot leaks into the "as shipped" assertions.
  def shipped_renderer(root:)
    catalog = Lain::Skill::Catalog.load(root:)
    slots = Lain::Prompt::Slots.load(root:)
    Lain::Skill::Renderer.new(catalog:, slots:)
  end

  def with_empty_project
    Dir.mktmpdir { |root| yield shipped_renderer(root:), root }
  end

  # Write a `.lain/slots/skill/<skill>/<hole>.md` override under +root+.
  def write_override(root, skill, hole, body)
    path = File.join(root, ".lain", "slots", "skill", skill, "#{hole}.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe "the three skills load and render" do
    it "presents create-plan, execute-plan, and critique in the shipped catalog" do
      Dir.mktmpdir do |root|
        catalog = Lain::Skill::Catalog.load(root:)
        shipped_names.each { |name| expect(catalog.names).to include(name) }
      end
    end

    it "renders each shipped skill to non-empty scaffold text" do
      with_empty_project do |renderer|
        shipped_names.each do |name|
          rendered = renderer.render(name)
          expect(rendered).to be_a(String)
          expect(rendered.strip).not_to be_empty
        end
      end
    end

    it "declares at least the named slots each skill's front-matter promises, all resolvable" do
      Dir.mktmpdir do |root|
        catalog = Lain::Skill::Catalog.load(root:)
        renderer = shipped_renderer(root:)

        shipped_names.each do |name|
          skill = catalog.fetch(name)
          expect(skill.slots).not_to be_empty
          # Every promised hole must resolve (a shipped default exists) -- a
          # declared slot with no default is a broken skill, and render would
          # raise UnknownSlot rather than splice silence.
          expect { renderer.render(name) }.not_to raise_error
        end
      end
    end
  end

  describe "create-plan's scaffold drives a plan, not code" do
    it "instructs grounding-before-planning, Gherkin acceptance criteria, and writing to planning/specs" do
      with_empty_project do |renderer|
        scaffold = renderer.render("create-plan")

        expect(scaffold.downcase).to match(/ground/)
        expect(scaffold.downcase).to match(/before .*plan|ground.* first|ground.* before/)
        expect(scaffold).to match(/[Gg]herkin/)
        expect(scaffold).to match(%r{planning/specs})
      end
    end

    it "references lain's real role-catalog names" do
      with_empty_project do |renderer|
        scaffold = renderer.render("create-plan")
        # A plan for parallel sub-agents must name the real roles the orchestrator
        # can spawn; a made-up role would fail loudly at Role::Catalog.fetch time.
        real_roles = Lain::Role::Catalog.names.map(&:to_s)
        named = real_roles.select { |role| scaffold.include?(role) }
        expect(named).not_to be_empty
        expect(scaffold).to include("test_engineer")
      end
    end

    it "names role delegation and describes run_skill accurately as a runtime continuation" do
      with_empty_project do |renderer|
        scaffold = renderer.render("create-plan")

        # Role delegation: both the inherit and fresh binding shapes.
        expect(scaffold).to include("@role/skill")
        expect(scaffold).to include("@role[/skill]")
        # run_skill is a TOOL the agent calls mid-run to get another skill's
        # rendered scaffold back as its next tool result -- NOT render-time
        # inlining (that mechanism is front-matter `includes:`). The scaffold
        # must describe the tool honestly, tying `run_skill` to a tool result,
        # and keep it distinct from the `includes:` inlining mechanism.
        run_skill_clause = scaffold[/`run_skill`[^.]*\./]
        expect(run_skill_clause).to match(/tool result|continuation/)
        expect(scaffold).to include("includes:")
      end
    end
  end

  describe "execute-plan's scaffold orchestrates TDD sub-agents" do
    it "instructs the red-first TDD loop, worktree isolation, and orchestrator-owned commits" do
      with_empty_project do |renderer|
        scaffold = renderer.render("execute-plan").downcase

        expect(scaffold).to match(/red/)
        expect(scaffold).to match(/worktree/)
        expect(scaffold).to match(/orchestrat/)
      end
    end
  end

  describe "critique's scaffold reviews without touching the tree" do
    it "asks for architectural, SOLID, and duplication findings ranked for the author" do
      with_empty_project do |renderer|
        scaffold = renderer.render("critique")

        expect(scaffold).to match(/SOLID/)
        expect(scaffold.downcase).to match(/duplicat/)
        expect(scaffold.downcase).to match(/blocker|should-fix|nit|rank/)
      end
    end
  end

  describe "a user slot extends a shipped skill at the declared hole" do
    it "renders create-plan with the project's conventions override in place of the shipped default" do
      with_empty_project do |_renderer, root|
        marker = "USER-CONVENTIONS-MARKER-42: prefer the smallest seam."
        write_override(root, "create-plan", "conventions", marker)

        # Reload against the same root so the override is read from disk.
        rendered = shipped_renderer(root:).render("create-plan")
        expect(rendered).to include(marker)
      end
    end
  end
end
