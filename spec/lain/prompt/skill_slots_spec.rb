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
end
