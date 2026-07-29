# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Skill::Library do
  # A project tree carrying BOTH halves the library is made of: one user skill
  # under `.lain/skills` and one slot override under `.lain/slots`. Loading from
  # this one root is what proves the pair comes from a single read.
  def with_project(&block)
    Dir.mktmpdir do |root|
      write(File.join(root, ".lain", "skills", "greet", "skill.md"), "# Greet\nSay hello.\n")
      write(File.join(root, ".lain", "slots", "system.md"), "Be terse.\n")
      yield(root)
    end
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe ".load" do
    it "reads the catalog and the slots from ONE root, so both halves see one tree" do
      with_project do |root|
        library = described_class.load(root:)

        expect(library.catalog).to be_a(Lain::Skill::Catalog)
        expect(library.catalog.names).to include(:greet)
        expect(library.slots).to be_a(Lain::Prompt::Slots)
        expect(library.slots.render).to include("Be terse.")
      end
    end

    it "answers a frozen value, so nothing downstream can memoize state onto it" do
      with_project do |root|
        expect(described_class.load(root:)).to be_frozen
      end
    end

    # The object's whole contract, at its own level: ONE read per half. The
    # wiring spec counts the same thing across a whole assembled session; this
    # counts it here, where the load actually happens.
    #
    # NOTE this is a count and not `eq` between two loads. {Skill::Catalog} and
    # {Prompt::Slots} define no `==`, so they compare by identity, and Data's
    # member-wise equality is only ever as deep as its members -- two loads of
    # one tree are NOT equal. Giving them value equality is a real change to two
    # classes with their own reasons, not a side effect of pairing them.
    it "reads each half exactly once" do
      allow(Lain::Skill::Catalog).to receive(:load).and_call_original
      allow(Lain::Prompt::Slots).to receive(:load).and_call_original

      with_project { |root| described_class.load(root:) }

      expect(Lain::Skill::Catalog).to have_received(:load).once
      expect(Lain::Prompt::Slots).to have_received(:load).once
    end
  end

  # The pair is required, both halves, because the whole reason this object
  # exists is that a from-disk default is a SECOND read of the same tree.
  it "refuses to construct on half a pair" do
    with_project do |root|
      expect { described_class.new(catalog: Lain::Skill::Catalog.load(root:)) }.to raise_error(ArgumentError, /slots/)
      expect { described_class.new(slots: Lain::Prompt::Slots.load(root:)) }.to raise_error(ArgumentError, /catalog/)
    end
  end

  # The composition the pair exists for: {Skill::Renderer} needs exactly these
  # two, which is why they travel together at all.
  describe "#renderer" do
    it "composes a Renderer over its OWN catalog and slots, reading no disk of its own" do
      with_project do |root|
        library = described_class.load(root:)
        renderer = library.renderer

        expect(renderer).to be_a(Lain::Skill::Renderer)
        expect(renderer.instance_variable_get(:@catalog)).to be(library.catalog)
        expect(renderer.instance_variable_get(:@slots)).to be(library.slots)
      end
    end

    it "renders a skill's scaffold, so the composition is wired and not merely shaped" do
      with_project do |root|
        expect(described_class.load(root:).renderer.render("greet")).to eq("# Greet\nSay hello.\n")
      end
    end
  end
end
