# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../../tools/test_map/constant_index"

RSpec.describe TestMap::ConstantIndex do
  def write(root, path, source)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, source)
  end

  def scrubbed_git(root, *args)
    out, status = Open3.capture2e(SeedRepo::SCRUB, "git", "-C", root, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out.strip
  end

  def tree_of_commit(root)
    scrubbed_git(root, "-c", "user.name=t", "-c", "user.email=t@example.com", "add", "-A")
    scrubbed_git(root, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "x")
    scrubbed_git(root, "rev-parse", "HEAD^{tree}")
  end

  def with_leaked_git_context
    keys = %w[GIT_OBJECT_DIRECTORY GIT_CONFIG_PARAMETERS]
    saved = ENV.values_at(*keys)
    ENV["GIT_OBJECT_DIRECTORY"] = File.join(root, "no-such-objects")
    ENV["GIT_CONFIG_PARAMETERS"] = "'core.bare=true'"
    yield
  ensure
    keys.zip(saved) { |key, value| ENV[key] = value }
  end

  around do |example|
    Dir.mktmpdir("constant-index-spec") do |dir|
      @root = dir
      scrubbed_git(dir, "init", "-q")
      example.run
    end
  end

  let(:root) { @root }

  describe "#dependents" do
    it "names a lib file that references the constant through its lexical namespace" do
      write(root, "lib/lain/dag/factory.rb", "module Lain\n  module Dag\n    class Factory; end\n  end\nend\n")
      write(root, "lib/lain/agent.rb", "module Lain\n  class Agent\n    def f = Dag::Factory.new\n  end\nend\n")
      write(root, "lib/lain/other.rb", "module Lain\n  class Other; end\nend\n")

      index = described_class.for(root:, old_tree: tree_of_commit(root))

      expect(index.dependents("lib/lain/dag/factory.rb")).to eq(Set["lib/lain/agent.rb"])
    end

    it "names a spec file that reads a constant of the file at load time" do
      write(root, "lib/lain/event_log/kinds.rb",
            "module Lain\n  module EventLog\n    module Kinds\n      KINDS = %i[turn].freeze\n    end\n  end\nend\n")
      write(root, "spec/lain/rust/event_spec.rb", "Lain::EventLog::Kinds::KINDS.each { |k| k }\n")

      index = described_class.for(root:, old_tree: nil)

      expect(index.dependents("lib/lain/event_log/kinds.rb")).to include("spec/lain/rust/event_spec.rb")
    end

    it "uses the inflected names a path maps to" do
      write(root, "lib/lain/http/client.rb", "module Lain\n  module HTTP\n    class Client; end\n  end\nend\n")
      write(root, "lib/lain/user.rb", "module Lain\n  class User\n    C = HTTP::Client\n  end\nend\n")

      index = described_class.for(root:, old_tree: nil)

      expect(index.dependents("lib/lain/http/client.rb")).to eq(Set["lib/lain/user.rb"])
    end

    it "still finds the users of a constant the new tree no longer defines" do
      write(root, "lib/lain/holder.rb", "module Lain\n  class Holder; end\n  class Extra; end\nend\n")
      write(root, "lib/lain/user.rb", "module Lain\n  class User\n    def f = Extra.new\n  end\nend\n")
      old_tree = tree_of_commit(root)
      write(root, "lib/lain/holder.rb", "module Lain\n  class Holder; end\nend\n")

      index = described_class.for(root:, old_tree:)

      expect(index.dependents("lib/lain/holder.rb")).to include("lib/lain/user.rb")
    end

    it "ignores the file itself and a file whose reference resolves elsewhere" do
      write(root, "lib/lain/a.rb", "module Lain\n  class A\n    def f = A.new\n  end\nend\n")
      write(root, "lib/lain/b.rb", "module Lain\n  class B\n    def f = Elsewhere::A\n  end\nend\n")

      index = described_class.for(root:, old_tree: nil)

      expect(index.dependents("lib/lain/a.rb")).to be_empty
    end

    it "is empty for a path outside lib" do
      write(root, "spec/a_spec.rb", "Lain::A\n")

      expect(described_class.for(root:, old_tree: nil).dependents("spec/a_spec.rb")).to be_empty
    end
  end

  describe "the default git reader" do
    it "reads the old tree despite git context variables in the environment" do
      write(root, "lib/lain/holder.rb", "module Lain\n  class Extra; end\nend\n")
      write(root, "lib/lain/user.rb", "module Lain\n  class User\n    def f = Extra.new\n  end\nend\n")
      old_tree = tree_of_commit(root)
      write(root, "lib/lain/holder.rb", "module Lain\nend\n")

      found = with_leaked_git_context { described_class.for(root:, old_tree:).dependents("lib/lain/holder.rb") }

      expect(found).to include("lib/lain/user.rb")
    end

    it "treats a path absent from the old tree as having no old definitions" do
      write(root, "lib/lain/a.rb", "module Lain\n  class A; end\nend\n")
      old_tree = tree_of_commit(root)
      write(root, "lib/lain/new.rb", "module Lain\n  class New; end\nend\n")

      expect(described_class.for(root:, old_tree:).dependents("lib/lain/new.rb")).to be_empty
    end

    it "raises on a tree id the repository does not hold" do
      write(root, "lib/lain/a.rb", "module Lain\n  class A; end\nend\n")

      index = described_class.for(root:, old_tree: "deadbeef" * 5)

      expect { index.dependents("lib/lain/a.rb") }.to raise_error(RuntimeError, /ls-tree/)
    end
  end

  describe "definitions beyond a class or module body" do
    def dependents_of_holder(holder_source, user_source)
      write(root, "lib/lain/holder.rb", holder_source)
      write(root, "lib/lain/user.rb", user_source)
      described_class.for(root:, old_tree: nil).dependents("lib/lain/holder.rb")
    end

    it "sees an X = assignment inside the file" do
      found = dependents_of_holder("module Lain\n  Gadget = 1\nend\n", "module Lain\n  Gadget\nend\n")

      expect(found).to eq(Set["lib/lain/user.rb"])
    end

    it "sees an A ||= assignment" do
      found = dependents_of_holder("module Lain\n  Gadget ||= 1\nend\n", "module Lain\n  Gadget\nend\n")

      expect(found).to eq(Set["lib/lain/user.rb"])
    end

    it "sees a Lain::E = assignment through a path" do
      found = dependents_of_holder("Lain::Gadget = 3\n", "module Lain\n  Gadget\nend\n")

      expect(found).to eq(Set["lib/lain/user.rb"])
    end

    it "sees every target of a multiple assignment" do
      found = dependents_of_holder("module Lain\n  Other, Gadget = 1, 2\nend\n", "module Lain\n  Gadget\nend\n")

      expect(found).to eq(Set["lib/lain/user.rb"])
    end
  end

  describe "references beyond a plain read" do
    it "counts a superclass as a reference" do
      write(root, "lib/lain/base.rb", "module Lain\n  class Base; end\nend\n")
      write(root, "lib/lain/child.rb", "module Lain\n  class Child < Base; end\nend\n")

      expect(described_class.for(root:, old_tree: nil).dependents("lib/lain/base.rb")).to eq(Set["lib/lain/child.rb"])
    end

    it "resolves a leading :: reference" do
      write(root, "lib/lain/holder.rb", "module Lain\n  class Holder; end\nend\n")
      write(root, "lib/lain/user.rb", "module Other\n  X = ::Lain::Holder\nend\n")

      expect(described_class.for(root:, old_tree: nil).dependents("lib/lain/holder.rb")).to eq(Set["lib/lain/user.rb"])
    end

    it "counts a spec file that references the constant" do
      write(root, "lib/lain/holder.rb", "module Lain\n  class Holder; end\nend\n")
      write(root, "spec/lain/holder_spec.rb", "RSpec.describe Lain::Holder do\nend\n")

      found = described_class.for(root:, old_tree: nil).dependents("lib/lain/holder.rb")

      expect(found).to eq(Set["spec/lain/holder_spec.rb"])
    end
  end

  describe "a path outside lib" do
    it "has no dependents even when its file defines a constant others reference" do
      write(root, "spec/helper_spec.rb", "module Fixture\nend\n")
      write(root, "spec/other_spec.rb", "Fixture\n")

      expect(described_class.for(root:, old_tree: nil).dependents("spec/helper_spec.rb")).to be_empty
    end
  end

  describe "over this repository" do
    it "finds a known dependent through the production construction path" do
      repo = File.expand_path("../../..", __dir__)

      index = described_class.for(root: repo, old_tree: nil)

      expect(index.dependents("lib/lain/dag/factory.rb")).not_to be_empty
    end
  end
end
