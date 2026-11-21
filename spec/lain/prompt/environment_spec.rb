# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Prompt::Environment do
  let(:env) { { "HOME" => "/home/ada", "USER" => "ada", "SHELL" => "/bin/zsh" } }
  let(:clock) { Struct.new(:now).new(Time.utc(2001, 2, 3, 23, 59)) }

  def with_os_release(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "os-release")
      File.write(path, body)
      yield path
    end
  end

  def current(root:, cwd: root, related: [], os_release: "/nonexistent/os-release")
    project = Lain::Project.new(root:, cwd:, kind: :project, detected_by: :flag)
    described_class.current(project:, related:, clock:, env:, os_release:)
  end

  describe ".current" do
    it "reads the home, shell, project, date and related directories" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        cwd = File.join(root, "sub")
        FileUtils.mkdir_p(cwd)
        text = current(root:, cwd:, related: ["~/dev/pitchcraft", "/srv/app"]).to_s

        expect(text).to include("/bin/zsh", root, cwd, "2001-02-03", "~/dev/pitchcraft", "/srv/app")
      end
    end

    it "names no user and no home directory" do
      Dir.mktmpdir do |dir|
        text = current(root: File.realpath(dir), related: ["~/notes"]).to_s

        expect(text).not_to match(/User:|Home directory:|ada/)
      end
    end

    it "shows paths under the home from ~" do
      text = described_class.fixed.with(home: "/home/ada", root: "/home/ada/dev/app",
                                        cwd: "/home/ada/dev/app/lib", related: ["/home/ada/notes"]).to_s

      expect(text).to include("Project root: ~/dev/app", "Working directory: ~/dev/app/lib",
                              "Related directories: ~/notes")
    end

    it "shows paths from ~ whatever trailing slashes the home carries" do
      ["/home/ada/", "/home/ada//"].each do |home|
        text = described_class.fixed.with(home:, root: "/home/ada/app", cwd: "/home/ada/app/lib", related: []).to_s

        expect(text).to include("Project root: ~/app", "Working directory: ~/app/lib")
        expect(text).not_to include("/home/ada")
      end
    end

    it "leaves a sibling directory that merely shares the home's prefix alone" do
      text = described_class.fixed.with(home: "/home/al", root: "/home/alice/app", cwd: "/home/alice/app").to_s

      expect(text).to include("Project root: /home/alice/app")
    end

    it "names the OS from os-release" do
      Dir.mktmpdir do |dir|
        with_os_release(%(PRETTY_NAME="Arch Linux"\nNAME="Arch Linux"\n)) do |path|
          expect(current(root: File.realpath(dir), os_release: path).to_s).to include("Arch Linux")
        end
      end
    end

    it "ignores blank and comment lines in os-release" do
      Dir.mktmpdir do |dir|
        with_os_release(%(# a comment\n\nPRETTY_NAME="Arch Linux"\n)) do |path|
          expect(current(root: File.realpath(dir), os_release: path).os).to eq("Arch Linux")
        end
      end
    end

    it "expands a bare ~ related entry to the home directory" do
      Dir.mktmpdir do |dir|
        expect(current(root: File.realpath(dir), related: ["~"]).related).to eq(["/home/ada"])
      end
    end

    it "falls back to the Ruby host OS when there is no os-release" do
      Dir.mktmpdir do |dir|
        expect(current(root: File.realpath(dir)).os).to eq(RbConfig::CONFIG["host_os"])
      end
    end

    it "says whether the root is a git repository" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        expect(current(root:).git).to be(false)
        FileUtils.mkdir_p(File.join(root, ".git"))
        expect(current(root:).git).to be(true)
      end
    end

    it "renders the same bytes every time for one value" do
      Dir.mktmpdir do |dir|
        value = current(root: File.realpath(dir))
        expect(value.to_s).to eq(value.to_s)
      end
    end

    it "stays Ractor-shareable" do
      Dir.mktmpdir do |dir|
        expect(current(root: File.realpath(dir), related: ["/srv/app"])).to be_deeply_frozen
      end
    end
  end

  describe "#for_child" do
    it "defers the working directory to the role instructions, keeping every other fact" do
      text = described_class.fixed.for_child.to_s

      expect(text).to include("- Working directory: stated after your role instructions", "/work/project",
                              "/work/related")
      expect(text).not_to include("/work/project/src")
    end

    it "renders the same bytes whatever the working directory was" do
      elsewhere = described_class.fixed.with(cwd: "/elsewhere")

      expect(elsewhere.for_child.to_s).to eq(described_class.fixed.for_child.to_s)
    end
  end

  describe "#for_child with a home-rooted project" do
    it "holds no home path and is the same bytes for every child" do
      home = described_class.fixed.with(root: "/home/user/app", cwd: "/home/user/app/a")
      other = home.with(cwd: "/home/user/app/b")

      expect(home.for_child.to_s).to eq(other.for_child.to_s)
      expect(home.for_child.to_s).not_to include("/home/user")
    end
  end

  it "carries no user field, since nothing renders one" do
    expect(described_class.members).not_to include(:user)
  end

  describe ".none" do
    it "renders nothing" do
      expect(described_class.none.to_s).to eq("")
    end
  end

  describe ".fixed" do
    it "renders constant text that names every field" do
      expect(described_class.fixed.to_s).to include("Linux", "/bin/bash", "/work/project", "2026-01-02")
    end
  end
end
