# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe Lain::Skill::Catalog do
  # A skill.md source: YAML front-matter fence above a raw markdown scaffold.
  def skill_source(front, body)
    "#{YAML.dump(front)}---\n#{body}"
  end

  # Write `<name>/skill.md` under +dir+ and return +dir+ for chaining.
  def write_skill(dir, name, front:, body:)
    path = File.join(dir, name, "skill.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, skill_source(front, body))
    dir
  end

  # Write a raw skill.md verbatim (for the malformed-front-matter cases), then
  # load a catalog whose only shipped skill is that file.
  def load_raw(name, source)
    Dir.mktmpdir do |shipped_dir|
      path = File.join(shipped_dir, name, "skill.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      return described_class.load(root: Dir.mktmpdir, shipped_dir:)
    end
  end

  # A throwaway shipped-templates dir and a throwaway project root, both wired
  # into one `Catalog.load`. Mirrors role_spec's `with_project`, but the shipped
  # dir is injected so the real (empty) templates/skill/ tree stays untouched.
  def with_catalog(shipped: {}, user: {})
    Dir.mktmpdir do |shipped_dir|
      Dir.mktmpdir do |root|
        shipped.each { |name, spec| write_skill(shipped_dir, name, **spec) }
        user.each { |name, spec| write_skill(File.join(root, ".lain", "skills"), name, **spec) }
        yield described_class.load(root:, shipped_dir:)
      end
    end
  end

  describe "a shipped skill loads with its metadata and scaffold" do
    it "parses name, description, raw scaffold, and declared slots/includes" do
      with_catalog(shipped: {
                     "create-plan" => {
                       front: { "description" => "Build an orchestrator-ready TDD plan.",
                                "slots" => %w[system task],
                                "includes" => %w[house-style] },
                       body: "## Build the plan\n\nGather the code state first.\n"
                     }
                   }) do |catalog|
        skill = catalog.fetch("create-plan")

        expect(skill.name).to eq(:"create-plan")
        expect(skill.description).to eq("Build an orchestrator-ready TDD plan.")
        expect(skill.scaffold).to eq("## Build the plan\n\nGather the code state first.\n")
        expect(skill.slots).to eq(%i[system task])
        expect(skill.includes).to eq(%i[house-style])
      end
    end

    it "loads a skill with no front-matter as an all-scaffold, empty-config skill" do
      Dir.mktmpdir do |shipped_dir|
        path = File.join(shipped_dir, "bare", "skill.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "## Just a scaffold\n")

        catalog = described_class.load(root: Dir.mktmpdir, shipped_dir:)
        skill = catalog.fetch("bare")

        expect(skill.scaffold).to eq("## Just a scaffold\n")
        expect(skill.slots).to eq([])
        expect(skill.description).to eq("")
      end
    end
  end

  describe "a user skill under .lain/skills overrides/extends the shipped set" do
    it "adds a project-only skill" do
      with_catalog(user: {
                     "triage" => { front: { "description" => "Triage the bug." }, body: "## Triage\n" }
                   }) do |catalog|
        expect(catalog.fetch("triage").description).to eq("Triage the bug.")
      end
    end

    it "resolves a name collision to the user version" do
      with_catalog(
        shipped: { "triage" => { front: { "description" => "shipped" }, body: "## SHIPPED\n" } },
        user: { "triage" => { front: { "description" => "user" }, body: "## USER\n" } }
      ) do |catalog|
        skill = catalog.fetch("triage")
        expect(skill.description).to eq("user")
        expect(skill.scaffold).to eq("## USER\n")
      end
    end
  end

  describe "an unknown skill fails loudly naming the set" do
    it "raises Unknown naming the miss and the known skills" do
      with_catalog(shipped: { "create-plan" => { front: { "description" => "d" }, body: "b" } }) do |catalog|
        expect { catalog.fetch("nope") }
          .to raise_error(Lain::Skill::Catalog::Unknown) { |e|
            expect(e.message).to include("nope")
            expect(e.message).to include("create-plan")
          }
      end
    end
  end

  describe "front-matter failures are loud and named (never a silent degrade)" do
    it "raises Malformed on an unclosed fence rather than swallowing the scaffold" do
      # `---` opens a fence that never closes; the mapping-shaped body would
      # otherwise be parsed whole as front-matter, leaving scaffold == "".
      expect { load_raw("runaway", "---\ndescription: hi\nextra: value\n") }
        .to raise_error(Lain::Skill::Catalog::Malformed) { |e|
          expect(e.message).to include("runaway")
        }
    end

    it "raises Malformed naming the file when front-matter is not a mapping" do
      expect { load_raw("seq", "---\n- a\n- b\n---\nbody\n") }
        .to raise_error(Lain::Skill::Catalog::Malformed) { |e|
          expect(e.message).to include("seq")
          expect(e.message).to include("mapping")
        }
    end

    it "wraps a YAML syntax error in Malformed naming the file" do
      expect { load_raw("bad", "---\ndescription: \"unterminated\n---\nbody\n") }
        .to raise_error(Lain::Skill::Catalog::Malformed) { |e|
          expect(e.message).to include("bad")
        }
    end

    it "still loads a well-formed but empty front-matter block as empty config" do
      catalog = load_raw("empty", "---\n---\n## Scaffold only\n")
      expect(catalog.fetch("empty").scaffold).to eq("## Scaffold only\n")
      expect(catalog.fetch("empty").slots).to eq([])
    end
  end

  describe "a loaded skill is config only, no behavior" do
    it "loads Ractor.shareable, frozen skills exposing no agent behavior" do
      with_catalog(shipped: {
                     "create-plan" => { front: { "description" => "d", "slots" => %w[system] }, body: "b" }
                   }) do |catalog|
        skill = catalog.fetch("create-plan")

        expect(skill).to be_frozen
        expect(skill).to be_ractor_shareable
        %i[call render spawn perform invoke].each { |m| expect(skill).not_to respond_to(m) }
      end
    end
  end
end
