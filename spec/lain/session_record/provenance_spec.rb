# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# What produced a run, as one header block: which lain, which tools, which
# effort, which project policy, and where it ran.
RSpec.describe Lain::SessionRecord::Provenance do
  let(:toolset) { CoreGraph.toolset }
  let(:place) { { root: "/work/project", cwd: "/work/project/sub", home: "/home/tester" } }

  def current(effort: "low")
    described_class.current(toolset:, effort:, policy: "blake3:policy", **place)
  end

  def harness(gem_root:, git: Lain::Shell::Out) = described_class.harness(git:, gem_root:)

  # A committed checkout shaped like lain's own: the 4 harness trees and a file outside them.
  def checkout(into)
    SeedRepo.derived("provenance-harness", into:) do |dir|
      %w[lib ext crates exe].each { |tree| FileUtils.mkdir_p(File.join(dir, tree)) }
      %w[lib/a.rb ext/b.rs crates/c.rs exe/lain].each { |path| File.write(File.join(dir, path), "one\n") }
      SeedRepo.git(dir, "add", "-A")
      SeedRepo.git(dir, "commit", "-q", "-m", "harness")
    end
  end

  def head_of(dir) = SeedRepo.git(dir, "rev-parse", "HEAD").stdout.strip

  describe ".current" do
    it "records the toolset's digest as the tool surface" do
      expect(current.tool_surface).to eq(toolset.digest)
    end

    it "records the effort, the root, the cwd and the home it was handed" do
      expect(current).to have_attributes(effort: "low", root: "/work/project", cwd: "/work/project/sub",
                                         home: "/home/tester")
    end

    it "reads an absent effort and an absent home as unrecorded" do
      place[:home] = nil

      expect(current(effort: nil)).to have_attributes(effort: "unrecorded", home: "unrecorded")
    end

    it "records the running lain's harness" do
      expect(current.harness).to eq(described_class.harness)
    end

    it "reads that harness from git once per process, not once per launch" do
      current
      allow(Lain::Shell::Out).to receive(:new).and_call_original
      2.times { current }

      expect(Lain::Shell::Out).not_to have_received(:new)
    end

    it "is deeply frozen" do
      expect(Ractor.shareable?(current)).to be(true)
    end
  end

  describe "the harness" do
    around do |example|
      Dir.mktmpdir("provenance-harness") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    let(:root) { checkout(File.join(@dir, "lain")) }

    it "is the HEAD sha and a digest of the uncommitted changes" do
      expect(harness(gem_root: root)).to match(/\A#{head_of(root)}\+blake3:\h{64}\z/)
    end

    it "changes when a file under lib, ext, crates or exe changes" do
      clean = harness(gem_root: root)
      edited = %w[lib/a.rb ext/b.rs crates/c.rs exe/lain].map do |path|
        File.write(File.join(root, path), "two\n")
        harness(gem_root: root)
      end

      expect([clean, *edited].uniq.size).to eq(5)
    end

    it "changes when a new file lands untracked under lib" do
      clean = harness(gem_root: root)
      File.write(File.join(root, "lib", "new.rb"), "fresh\n")

      expect(harness(gem_root: root)).not_to eq(clean)
    end

    it "does not change when a file outside those trees changes" do
      clean = harness(gem_root: root)
      File.write(File.join(root, "README"), "edited\n")

      expect(harness(gem_root: root)).to eq(clean)
    end

    it "is unrecorded when GEM_ROOT is not a git work tree" do
      plain = File.join(@dir, "installed")
      FileUtils.mkdir_p(plain)

      expect(harness(gem_root: plain)).to eq("unrecorded")
    end

    it "is unrecorded when GEM_ROOT is a directory inside some other work tree" do
      nested = File.join(root, "lib")

      expect(harness(gem_root: nested)).to eq("unrecorded")
    end

    # Each user setting below reshapes `git diff` or `git ls-files` output when git reads it.
    it "is the same under a user git config that reshapes diffs and ignores lib/" do
      File.write(File.join(root, "lib", "a.rb"), "two\n")
      File.write(File.join(root, "lib", "new.rb"), "fresh\n")
      File.write(File.join(@dir, "excludes"), "lib/\n")
      hostile = File.join(@dir, "gitconfig")
      File.write(hostile, "[color]\n\tui = always\n[diff]\n\tnoprefix = true\n[core]\n\tabbrev = 12\n" \
                          "\texcludesFile = #{File.join(@dir, "excludes")}\n")
      ordinary = harness(gem_root: root)

      expect(with_env("GIT_CONFIG_GLOBAL" => hostile) { harness(gem_root: root) }).to eq(ordinary)
    end

    it "is unrecorded when git outlives a short bound, which it is given" do
      bounds = []
      hung = Class.new do
        define_singleton_method(:new) do |*, timeout: nil, **|
          bounds << timeout
          Class.new { def run_command = raise(Lain::Shell::Out::Timeout, "git hung") }.new
        end
      end

      expect(harness(gem_root: root, git: hung)).to eq("unrecorded")
      expect(bounds).to all(be_between(1, 5))
    end

    describe "an untracked entry that is not a readable regular file" do
      def recorded?(value) = value.match?(/\A#{head_of(root)}\+blake3:\h{64}\z/)

      it "is digested by its target when it is a symlink, dangling or not" do
        link = File.join(root, "lib", "link")
        File.symlink("nowhere-a", link)
        first = harness(gem_root: root)
        File.unlink(link)
        File.symlink("nowhere-b", link)

        expect([recorded?(first), harness(gem_root: root) == first]).to eq([true, false])
      end

      it "is digested by its name when it is a symlink to a directory" do
        File.symlink(File.join(root, "ext"), File.join(root, "lib", "dir_link"))

        expect(recorded?(harness(gem_root: root))).to be(true)
      end

      it "is digested by its name when git lists it as a directory" do
        nested = File.join(root, "lib", "nested")
        FileUtils.mkdir_p(nested)
        SeedRepo.git(nested, "init", "-q")
        File.write(File.join(nested, "x.rb"), "x\n")

        expect(recorded?(harness(gem_root: root))).to be(true)
      end

      it "is digested by a fixed marker when it cannot be read" do
        locked = File.join(root, "lib", "locked.rb")
        File.write(locked, "secret\n")
        File.chmod(0o000, locked)

        expect(recorded?(harness(gem_root: root))).to be(true)
      ensure
        File.chmod(0o600, locked)
      end

      it "is digested by its type, never opened, when it is a FIFO" do
        File.mkfifo(File.join(root, "lib", "pipe"))

        expect(recorded?(harness(gem_root: root))).to be(true)
      end
    end

    it "is unrecorded when git is not installed" do
      missing = Class.new { def self.new(*, **) = raise(Errno::ENOENT, "git") }

      expect(harness(gem_root: root, git: missing)).to eq("unrecorded")
    end
  end

  describe "the policy" do
    around do |example|
      Dir.mktmpdir("provenance-policy") do |dir|
        @dir = dir
        example.run
      end
    end

    let(:paths) { Lain::Paths.new(env: { "HOME" => @dir, "XDG_CONFIG_HOME" => File.join(@dir, "xdg") }) }

    def policy_in(root, body)
      FileUtils.mkdir_p(File.join(root, ".lain"))
      File.write(File.join(root, ".lain", "config.rb"), body)
      described_class.launched(project: throwaway_project(root), toolset:, effort: nil, paths:).policy
    end

    it "changes when a line is added to the project's config" do
      root = File.join(@dir, "project")

      expect(policy_in(root, "approval do\nend\n")).not_to eq(policy_in(root, "approval do\nend\n# more\n"))
    end

    it "is the same for the same config bytes in 2 different directories" do
      expect(policy_in(File.join(@dir, "clone_a"), "approval do\nend\n"))
        .to eq(policy_in(File.join(@dir, "clone_b"), "approval do\nend\n"))
    end

    it "covers, for a launch, the project's own .lain/*.rb and the user's config.rb" do
      project = throwaway_project(@dir)
      files = [".lain/extra.rb", "xdg/lain/config.rb"]
      files.each { |path| FileUtils.mkdir_p(File.dirname(File.join(@dir, path))) }
      policies = ["# before\n", "# after\n"].flat_map do |body|
        files.map do |path|
          File.write(File.join(@dir, path), body)
          described_class.launched(project:, toolset:, effort: nil, paths:).policy
        end
      end

      expect(policies.uniq.size).to eq(4)
    end

    it "records, for a launch, the project's root and cwd and the user's home" do
      paths = Lain::Paths.new(env: { "HOME" => "/home/tester" })
      FileUtils.mkdir_p(File.join(@dir, "sub"))
      project = Lain::Project.new(root: @dir, cwd: File.join(@dir, "sub"), kind: :project, detected_by: :flag)

      expect(described_class.launched(project:, toolset:, effort: "high", paths:))
        .to have_attributes(root: @dir, cwd: File.join(@dir, "sub"), home: "/home/tester", effort: "high")
    end
  end

  describe "#to_header" do
    it "nests every field under one provenance key" do
      expect(current.to_header).to eq("provenance" => { "harness" => current.harness,
                                                        "tool_surface" => toolset.digest, "effort" => "low",
                                                        "policy" => current.policy, "cwd" => "/work/project/sub",
                                                        "root" => "/work/project", "home" => "/home/tester" })
    end
  end
end
