# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Prompt::SkillSlots do
  def write_file(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe ".read excludes the scaffold" do
    it "never surfaces skill.md as a phantom hole" do
      Dir.mktmpdir do |dir|
        write_file(File.join(dir, "create-plan", "skill.md"), "SCAFFOLD BODY")
        write_file(File.join(dir, "create-plan", "conventions.md"), "HOLE BODY")
        region = described_class.new(fills: {}, templates: described_class.read(dir))

        expect(region.source("create-plan", "conventions")).to eq("HOLE BODY")
        expect { region.source("create-plan", "skill") }
          .to raise_error(Lain::Prompt::UnknownSlot, /skill/)
      end
    end
  end

  describe "#source override-then-default" do
    it "lets an empty override win over the shipped default (a deliberately blanked hole)" do
      region = described_class.new(
        fills: { "cp" => { "h" => "" } },
        templates: { "cp" => { "h" => "DEFAULT" } }
      )

      expect(region.source("cp", "h")).to eq("")
    end

    it "falls back to the shipped default when no override key exists" do
      region = described_class.new(fills: {}, templates: { "cp" => { "h" => "DEFAULT" } })

      expect(region.source("cp", "h")).to eq("DEFAULT")
    end

    it "raises loudly, naming the skill and known holes, when a hole exists in neither tree" do
      region = described_class.new(fills: {}, templates: { "cp" => { "h" => "DEFAULT" } })

      expect { region.source("cp", "ghost") }
        .to raise_error(Lain::Prompt::UnknownSlot) { |e|
          expect(e.message).to include("ghost")
          expect(e.message).to include("cp")
          expect(e.message).to include("h")
        }
    end
  end

  describe "project slot files are checked against the shipped names" do
    def load_slots(shipped:, overrides:)
      Dir.mktmpdir do |root|
        shipped.each { |(skill, hole), body| write_file(File.join(root, "shipped", skill, "#{hole}.md"), body) }
        overrides.each do |path, body|
          write_file(File.join(root, ".lain", "slots", "skill", path), body)
        end
        Lain::Prompt::Slots.load(root:, skill_shipped_dir: File.join(root, "shipped"))
      end
    end

    it "refuses a misspelled hole file, naming the file and the nearest known name" do
      expect do
        load_slots(shipped: { %w[research brief] => "x", %w[research skill] => "s" },
                   overrides: { "research/breif.md" => "mine" })
      end.to raise_error(Lain::Prompt::UnknownSlot) { |e|
        expect(e.message).to include("breif.md", "did you mean", "brief")
      }
    end

    it "refuses a directory matching no skill, naming the directory" do
      expect do
        load_slots(shipped: { %w[research brief] => "x" }, overrides: { "reserch/brief.md" => "mine" })
      end.to raise_error(Lain::Prompt::UnknownSlot) { |e|
        expect(e.message).to include("reserch", "research")
      }
    end

    it "refuses a hole file for a skill that takes no holes, saying so" do
      expect do
        load_slots(shipped: { %w[handoff skill] => "s" }, overrides: { "handoff/notes.md" => "mine" })
      end.to raise_error(Lain::Prompt::UnknownSlot) { |e|
        expect(e.message).to include("notes.md", "handoff", "takes no holes")
        expect(e.message).not_to include("directory")
      }
    end

    %w[research.md notes.txt].each do |loose|
      it "refuses #{loose} sitting directly in the skill slots, saying where holes live" do
        expect do
          load_slots(shipped: { %w[research brief] => "x" }, overrides: { loose => "mine" })
        end.to raise_error(Lain::Prompt::UnknownSlot) { |e|
          expect(e.message).to include(loose, "skill/<skill>/<hole>.md")
        }
      end
    end

    it "suggests the nearest skill for a loose file" do
      expect do
        load_slots(shipped: { %w[research brief] => "x" }, overrides: { "reserch.md" => "mine" })
      end.to raise_error(Lain::Prompt::UnknownSlot, /did you mean "research"/)
    end

    it "points a skill.md among the holes at the project skill's own directory" do
      expect do
        load_slots(shipped: { %w[research brief] => "x" }, overrides: { "research/skill.md" => "mine" })
      end.to raise_error(Lain::Prompt::UnknownSlot, %r{\.lain/skills/research/skill\.md})
    end

    it "refuses a hole file with the wrong extension" do
      expect do
        load_slots(shipped: { %w[research brief] => "x" }, overrides: { "research/brief.txt" => "mine" })
      end.to raise_error(Lain::Prompt::UnknownSlot, /brief\.txt/)
    end

    it "still lets a declared hole be overridden" do
      slots = load_slots(shipped: { %w[research brief] => "x" }, overrides: { "research/brief.md" => "mine" })

      expect(slots.render_skill("research", "brief")).to eq("mine")
    end
  end
end
