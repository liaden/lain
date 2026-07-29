# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The shape both `.lain/*.rb` DSL loaders wear. {Lain::Summarizer::Catalog} and
# {Lain::Isolation::Services} were byte-identical here, each naming the other in
# a comment as the posture it took; these examples pin the shared contract once,
# against a subclass as thin as the two real ones, and then assert the two real
# ones actually sit on it.
RSpec.describe Lain::DslCatalog do
  # Answers the one message the base sends an evaluator, so the contract under
  # test is the base's own -- neither project DSL's Builder is in the way.
  echoing_builder = Module.new do
    def self.build(source, path) = [source.strip, path]
  end

  # `const_set`, not `DSL_PATH = ...`: a constant assigned in a block body lands
  # in the enclosing lexical scope, not in the anonymous class.
  let(:catalog_class) do
    Class.new(described_class) do
      def self.name = "SpecCatalog"

      const_set(:DSL_PATH, Lain::ProjectDir.join("things.rb"))
      define_singleton_method(:builder) { echoing_builder }
    end
  end

  # Writes the subclass's DSL file under a throwaway root and loads it.
  def load_from(catalog_class, source)
    Dir.mktmpdir("lain-dsl-catalog") do |root|
      path = File.join(root, catalog_class.dsl_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      return [catalog_class.load(root:), path]
    end
  end

  describe ".load" do
    it "is an EMPTY catalog when the project has no DSL file, never an error" do
      Dir.mktmpdir("lain-dsl-catalog-empty") do |root|
        catalog = catalog_class.load(root:)

        expect(catalog).to be_empty
        expect(catalog.to_a).to eq([])
      end
    end

    it "hands the file's contents and its FULL path to the builder" do
      catalog, path = load_from(catalog_class, "things\n")

      expect(catalog.to_a).to eq(["things", path])
    end

    it "resolves the DSL file under the given root, never under Dir.pwd" do
      _catalog, path = load_from(catalog_class, "things\n")

      expect(path).to end_with(File.join(".lain", "things.rb"))
      expect(path).not_to start_with(Dir.pwd)
    end

    it "refuses to load a subclass that declares no DSL_PATH" do
      anonymous = Class.new(described_class) { def self.builder = nil }

      expect { anonymous.load(root: "/nowhere") }.to raise_error(NotImplementedError, /must name its DSL file/)
    end

    it "refuses to load a subclass that names no builder" do
      Dir.mktmpdir("lain-dsl-catalog-no-builder") do |root|
        path = File.join(root, ".lain", "things.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "things\n")
        anonymous = Class.new(described_class) { const_set(:DSL_PATH, File.join(".lain", "things.rb")) }

        expect { anonymous.load(root:) }.to raise_error(NotImplementedError, /must name its DSL Builder/)
      end
    end
  end

  describe "the collection itself" do
    it "is enumerable in declaration order" do
      catalog = catalog_class.new(%w[first second])

      expect(catalog.map(&:upcase)).to eq(%w[FIRST SECOND])
    end

    it "freezes itself and the declarations it was handed" do
      declarations = ["first"]
      catalog = catalog_class.new(declarations)

      expect(catalog).to be_frozen
      expect(declarations).to be_frozen
    end
  end

  # The point of the base: the two real loaders are thin, and their public
  # `.lain/` names are unchanged (CLI::IsolationBackend prints one of them).
  describe "the two project loaders" do
    it "sits under Summarizer::Catalog, whose DSL path is unchanged" do
      expect(Lain::Summarizer::Catalog.ancestors).to include(described_class)
      expect(Lain::Summarizer::Catalog::DSL_PATH).to eq(File.join(".lain", "summarizers.rb"))
      expect(Lain::Summarizer::Catalog.dsl_path).to eq(Lain::Summarizer::Catalog::DSL_PATH)
      expect(Lain::Summarizer::Catalog.builder).to be(Lain::Summarizer::Builder)
    end

    it "sits under Isolation::Services, whose DSL path is unchanged" do
      expect(Lain::Isolation::Services.ancestors).to include(described_class)
      expect(Lain::Isolation::Services::DSL_PATH).to eq(File.join(".lain", "services.rb"))
      expect(Lain::Isolation::Services.dsl_path).to eq(Lain::Isolation::Services::DSL_PATH)
      expect(Lain::Isolation::Services.builder).to be(Lain::Isolation::Services::Builder)
    end
  end
end
