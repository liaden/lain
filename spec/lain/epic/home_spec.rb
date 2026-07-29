# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Epic::Home do
  # Every scenario resolves against a throwaway XDG state home and a throwaway
  # project root, so no spec here can read or write the real ~/.local/state.
  def paths_for(state_home)
    Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  end

  def config_for(home) = Lain::Config.new(epics: Lain::Config::Epics.new(home:))

  def issue(id:, **overrides)
    Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)
  end

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  # A graph that is legal to construct and impossible to emit: a description
  # line ending in a space is stripped by the parse, so Document refuses to
  # write it back rather than change it silently.
  def unemittable_graph = graph_of(issue(id: "a", description: "trailing space "))

  describe "both homes resolve per config" do
    it "puts an xdg home under state_home/epics/<project_hash>/<slug>" do
      Dir.mktmpdir do |tmp|
        state_home = File.join(tmp, "state")
        root = File.join(tmp, "project")
        FileUtils.mkdir_p(root)
        paths = paths_for(state_home)

        home = described_class.resolve(config: config_for(:xdg), paths:, root:, slug: "alpha")

        expect(home.path)
          .to eq(File.join(paths.state_home, "epics", paths.project_hash(root), "alpha"))
      end
    end

    it "puts a repo home under <root>/.lain/epics/<slug>" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "project")
        FileUtils.mkdir_p(root)

        home = described_class.resolve(config: config_for(:repo), paths: paths_for(File.join(tmp, "state")),
                                       root:, slug: "alpha")

        expect(home.path).to eq(File.join(root, ".lain", "epics", "alpha"))
      end
    end

    it "resolves without creating anything -- the directory arrives on the first write" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "project")
        FileUtils.mkdir_p(root)

        home = described_class.resolve(config: config_for(:repo), paths: paths_for(File.join(tmp, "state")),
                                       root:, slug: "alpha")

        expect(File).not_to exist(home.path)
        expect(File).not_to exist(File.join(root, ".lain"))
      end
    end

    it "names the epics container without needing a slug" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "project")
        FileUtils.mkdir_p(root)

        container = described_class.container(config: config_for(:repo), paths: paths_for(File.join(tmp, "state")),
                                              root:)

        expect(container).to eq(File.join(root, ".lain", "epics"))
      end
    end

    it "is a deeply frozen, Ractor-shareable value" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        expect(home).to be_deeply_frozen
        expect(Ractor.shareable?(home)).to be(true)
      end
    end
  end

  describe "the epic artifact round-trips through the home" do
    it "reads back a graph with the digest it was written with" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")
        graph = graph_of(issue(id: "a", description: "does the thing", blocks: ["b"]),
                         issue(id: "b", status: "done"))

        home.write_epic(graph)

        expect(home.read_epic.digest).to eq(graph.digest)
      end
    end

    it "writes it as epic.md inside the home" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        home.write_epic(graph_of(issue(id: "a")))

        expect(File).to exist(File.join(home.path, "epic.md"))
      end
    end

    it "refuses an unemittable graph before any file is touched" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        expect { home.write_epic(unemittable_graph) }.to raise_error(Lain::Epic::MalformedDocument)
        expect(File).not_to exist(home.path)
      end
    end

    it "replaces an earlier epic.md rather than appending to it" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")
        home.write_epic(graph_of(issue(id: "a"), issue(id: "b")))

        second = graph_of(issue(id: "a"))
        home.write_epic(second)

        expect(home.read_epic.digest).to eq(second.digest)
      end
    end

    it "reuses an existing home directory instead of clearing it" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")
        home.research.write("what we learned")

        home.write_epic(graph_of(issue(id: "a")))

        expect(home.research.read).to eq("what we learned")
      end
    end

    it "leaves no temporary file beside the artifact it replaced" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        home.write_epic(graph_of(issue(id: "a")))

        expect(Dir.children(home.path)).to eq(["epic.md"])
      end
    end
  end

  describe "the other artifacts" do
    it "round-trips research.md" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        home.research.write("# Research\n")

        expect(home.research.read).to eq("# Research\n")
        expect(File).to exist(File.join(home.path, "research.md"))
      end
    end

    it "round-trips issues/<id>.md" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        home.issue("a1").write("the story\n")

        expect(home.issue("a1").read).to eq("the story\n")
        expect(File).to exist(File.join(home.path, "issues", "a1.md"))
      end
    end

    it "round-trips plans/<id>.md" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        home.plan("a1").write("the plan\n")

        expect(home.plan("a1").read).to eq("the plan\n")
        expect(File).to exist(File.join(home.path, "plans", "a1.md"))
      end
    end

    it "answers whether an artifact is there without raising" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        expect(home.epic.exist?).to be(false)
        home.write_epic(graph_of(issue(id: "a")))
        expect(home.epic.exist?).to be(true)
      end
    end

    it "refuses to read an artifact that is not there, naming the path" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        expect { home.read_epic }
          .to raise_error(Lain::Epic::Home::MissingArtifact, /#{Regexp.escape(File.join(home.path, "epic.md"))}/)
      end
    end
  end

  describe "path traversal cannot escape the home" do
    %w[../escape a/b .hidden].each do |slug|
      it "refuses the slug #{slug.inspect} naming the filesystem grammar" do
        Dir.mktmpdir do |tmp|
          root = File.join(tmp, "project")
          FileUtils.mkdir_p(root)

          expect { described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root:, slug:) }
            .to raise_error(Lain::Epic::Home::MalformedName,
                            /#{Regexp.escape(slug)}.*#{Regexp.escape(described_class::NAME.source)}/m)
        end
      end

      it "touches nothing outside the home for the slug #{slug.inspect}" do
        Dir.mktmpdir do |tmp|
          root = File.join(tmp, "project")
          FileUtils.mkdir_p(root)
          before = Dir.glob(File.join(tmp, "**", "*"), File::FNM_DOTMATCH).sort

          expect { described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root:, slug:) }
            .to raise_error(Lain::Epic::Home::MalformedName)

          expect(Dir.glob(File.join(tmp, "**", "*"), File::FNM_DOTMATCH).sort).to eq(before)
        end
      end
    end

    it "refuses an empty slug, an uppercase slug, and one opening with a dash" do
      Dir.mktmpdir do |tmp|
        ["", "Alpha", "-alpha", "alpha\n", "alpha beta"].each do |slug|
          expect { described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug:) }
            .to raise_error(Lain::Epic::Home::MalformedName, /#{Regexp.escape(slug.inspect)}/)
        end
      end
    end

    it "refuses a slug that is not a String rather than coercing it" do
      Dir.mktmpdir do |tmp|
        expect { described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: :alpha) }
          .to raise_error(Lain::Epic::Home::MalformedName)
      end
    end

    it "accepts the digits-and-dashes shapes the grammar allows" do
      Dir.mktmpdir do |tmp|
        %w[a alpha alpha-2 2026-07-epic].each do |slug|
          expect { described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug:) }
            .not_to raise_error
        end
      end
    end
  end

  describe "issue ids used as filenames" do
    %w[../escape a/b .hidden Upper].each do |id|
      it "refuses the id #{id.inspect} at write time" do
        Dir.mktmpdir do |tmp|
          home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

          expect { home.issue(id).write("body") }.to raise_error(Lain::Epic::Home::MalformedName)
          expect(File).not_to exist(home.path)
        end
      end
    end

    it "refuses it at read time too, so a lookup cannot escape either" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        expect { home.plan("../../etc/passwd") }.to raise_error(Lain::Epic::Home::MalformedName)
      end
    end
  end

  # The grammar guards the NAME; these guard the composed PATH. Both mkdir_p and
  # Tempfile.create follow symlinks, so a name that is beyond reproach still
  # lands wherever a symlink between the container and the artifact points. The
  # names reaching this object originate in model-authored markdown, so the
  # containment assert is defence in depth behind a grammar that is already
  # total, not the only thing standing there.
  describe "a symlink cannot redirect an artifact out of the home" do
    def elsewhere_link(container, slug, target)
      FileUtils.mkdir_p(container)
      FileUtils.mkdir_p(target)
      File.symlink(target, File.join(container, slug))
    end

    it "refuses to write when the home directory is itself a symlink" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "project")
        target = File.join(tmp, "elsewhere")
        container = File.join(root, ".lain", "epics")
        elsewhere_link(container, "alpha", target)
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root:, slug: "alpha")

        expect { home.research.write("secret") }
          .to raise_error(Lain::Epic::Home::EscapesHome, /alpha/)
        expect(Dir.children(target)).to be_empty
      end
    end

    it "refuses to read through that symlink too" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "project")
        target = File.join(tmp, "elsewhere")
        container = File.join(root, ".lain", "epics")
        elsewhere_link(container, "alpha", target)
        File.write(File.join(target, "epic.md"), "### [ ] `a` planted\n")
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root:, slug: "alpha")

        expect { home.read_epic }.to raise_error(Lain::Epic::Home::EscapesHome)
      end
    end

    it "refuses when an interior directory is the symlink" do
      Dir.mktmpdir do |tmp|
        target = File.join(tmp, "elsewhere")
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")
        FileUtils.mkdir_p(home.path)
        FileUtils.mkdir_p(target)
        File.symlink(target, File.join(home.path, "issues"))

        expect { home.issue("a1").write("body") }.to raise_error(Lain::Epic::Home::EscapesHome, /issues/)
        expect(Dir.children(target)).to be_empty
      end
    end

    it "refuses when the artifact file itself is a symlink" do
      Dir.mktmpdir do |tmp|
        target = File.join(tmp, "planted.md")
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")
        FileUtils.mkdir_p(home.path)
        File.write(target, "planted")
        File.symlink(target, File.join(home.path, "research.md"))

        expect { home.research.read }.to raise_error(Lain::Epic::Home::EscapesHome, /research\.md/)
      end
    end

    # All three of an artifact's methods answer the same way about the same
    # path, so `if a.exist? then a.read` cannot go true-then-refused, and a
    # dangling symlinked home cannot answer "nothing here" to the question and
    # `EscapesHome` to the write. A predicate that raises is unusual; a duck
    # whose three methods disagree about whether a path is legitimate is worse.
    it "refuses exist? on the same paths it refuses read and write on" do
      Dir.mktmpdir do |tmp|
        root = File.join(tmp, "project")
        container = File.join(root, ".lain", "epics")
        elsewhere_link(container, "alpha", File.join(tmp, "elsewhere"))
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root:, slug: "alpha")

        expect { home.epic.exist? }.to raise_error(Lain::Epic::Home::EscapesHome)
      end
    end

    it "answers exist? false, not a refusal, when the home is merely absent" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        expect(home.epic.exist?).to be(false)
      end
    end

    it "allows a symlinked CONTAINER, which is the user's own configured location" do
      Dir.mktmpdir do |tmp|
        real = File.join(tmp, "real-state")
        FileUtils.mkdir_p(real)
        File.symlink(real, File.join(tmp, "linked-state"))
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp),
                                       root: File.join(tmp, "linked-state"), slug: "alpha")

        expect { home.research.write("fine") }.not_to raise_error
        expect(home.research.read).to eq("fine")
      end
    end
  end

  describe "the artifact is a value, not a mutable handle" do
    it "freezes its path, so a mutated handle cannot redirect the write" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        artifact = home.epic

        expect(artifact.path).to be_frozen
        expect { artifact.path << "-MUTATED" }.to raise_error(FrozenError)
        expect(Ractor.shareable?(artifact)).to be(true)
      end
    end

    it "keeps `new` off the public surface, so resolve really is the only door" do
      expect(described_class.singleton_class.private_method_defined?(:new)).to be(true)
      expect(described_class.singleton_class.private_method_defined?(:[])).to be(true)
      # `::` and not `const_get`: const_get is a reflection API and answers
      # regardless of privacy, so it would pass against a public constant too.
      expect { Lain::Epic::Home::Artifact }.to raise_error(NameError, /private constant/)
    end
  end

  describe "the mode an artifact lands with" do
    # File.umask is process-global, so it is set and restored inside the one
    # example that needs it. Asserted against literal modes rather than against
    # the implementation's own expression, so deleting the chmod (which would
    # ship Tempfile's 0600) fails here instead of passing tautologically.
    def mode_under_umask(home, umask)
      previous = File.umask(umask)
      begin
        home.research.write("x")
      ensure
        File.umask(previous)
      end
      File.stat(File.join(home.path, "research.md")).mode & 0o777
    end

    it "is the umask's, not the tempfile's 0600" do
      Dir.mktmpdir do |tmp|
        lenient = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "a")
        strict = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "b")

        expect(mode_under_umask(lenient, 0o022)).to eq(0o644)
        expect(mode_under_umask(strict, 0o002)).to eq(0o664)
      end
    end
  end

  describe "an unreadable artifact" do
    it "is a named refusal, not a raw errno, when a directory sits where the file should" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")
        FileUtils.mkdir_p(File.join(home.path, "epic.md"))

        expect { home.read_epic }
          .to raise_error(Lain::Epic::Home::UnreadableArtifact, /#{Regexp.escape(File.join(home.path, "epic.md"))}/)
      end
    end

    it "still distinguishes absence from unreadability" do
      Dir.mktmpdir do |tmp|
        home = described_class.resolve(config: config_for(:repo), paths: paths_for(tmp), root: tmp, slug: "alpha")

        expect { home.read_epic }.to raise_error(Lain::Epic::Home::MissingArtifact)
      end
    end
  end

  describe "an unknown epics_home" do
    it "is refused rather than defaulting" do
      Dir.mktmpdir do |tmp|
        config = instance_double(Lain::Config, epics_home: :s3)

        expect { described_class.container(config:, paths: paths_for(tmp), root: tmp) }
          .to raise_error(Lain::Epic::Home::UnknownHome, /s3/)
      end
    end
  end
end
