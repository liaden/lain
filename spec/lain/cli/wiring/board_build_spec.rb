# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The unit's own seam. {Lain::CLI::Wiring} drives this module with everything
# defaulted, so the production assertions live beside that assembler in
# wiring_spec.rb; what belongs HERE is the `paths:` injection Wiring does not
# expose, and the two vocabularies the module exists to keep apart.
RSpec.describe Lain::CLI::Wiring::BoardBuild do
  let(:chronicle) { Lain::CLI::Chronicle::Null.new }
  let(:toolset) { Lain::Toolset.new([]) }

  def in_tree(config: nil)
    Dir.mktmpdir("lain-board-build") do |dir|
      base = File.realpath(dir)
      root = File.join(base, "repo")
      FileUtils.mkdir_p(File.join(root, ".lain"))
      File.write(File.join(root, ".lain", "config.toml"), config) if config
      yield(root, File.join(base, "home"))
    end
  end

  def project_at(root, cwd = root) = Lain::Project.new(root:, cwd:, kind: :project, detected_by: :flag)

  def paths_at(home) = Lain::Paths.new(env: { "HOME" => home })

  def board_for(root, home, options: { yolo: false })
    described_class.for(chronicle:, options:, model: "m", toolset:, project: project_at(root),
                        paths: paths_at(home))
  end

  def read_of(path) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })

  describe ".classifier" do
    it "anchors the home-relative table at the INJECTED home, not the process's" do
      in_tree do |root, home|
        classifier = described_class.classifier(project: project_at(root), paths: paths_at(home))

        expect(classifier.denied?(File.join(home, ".kube", "config"))).to be(true)
        expect(classifier.denied?(File.join(Dir.home, ".kube", "config"))).to be(false)
      end
    end

    # The `cwd:` half of the same injection, and the one T8's panel found
    # mattered: a relative path is joined LEXICALLY to the project's cwd, so a
    # tool call written the way a model writes one still classifies.
    #
    # The `.env` line alone does NOT see cwd -- it is a BASENAME rule, so it
    # answers gated at any cwd whatever, and mutating `cwd: project.cwd` to
    # `paths.home` survives it. `.kube/config` is the discriminator: it is a
    # HOME-ANCHORED rule, so resolving this relative path against the project's
    # cwd puts it outside home and ordinary, while resolving it against home
    # would deny it. One assertion, and it is the only one here that can tell
    # which directory the classifier was given.
    it "resolves a relative path against the project's cwd" do
      in_tree do |root, home|
        cwd = File.join(root, "services")
        FileUtils.mkdir_p(cwd)
        classifier = described_class.classifier(project: project_at(root, cwd), paths: paths_at(home))

        expect(classifier.gated?(".env")).to be(true)
        expect(classifier.classify(".kube/config").reason).to eq(:none)
      end
    end

    it "compiles the project's own [sensitivity] table into the rules" do
      in_tree(config: "[sensitivity]\ndenied = [\"*.secret\"]\n") do |root, home|
        classifier = described_class.classifier(project: project_at(root), paths: paths_at(home))

        expect(classifier.classify(File.join(root, "prod.secret")).reason).to eq(:configured)
      end
    end

    # Loud, and unrescued: this table RESTRICTS, so a session that ran with it
    # silently un-parsed would be running with the project's denials off.
    it "refuses a malformed table by name, and names the file" do
      in_tree(config: "sensitivity = \"strict\"\n") do |root, home|
        expect { described_class.classifier(project: project_at(root), paths: paths_at(home)) }
          .to raise_error(Lain::Sensitivity::Rules::NotATable, /config\.toml.*must be a table/)
      end
    end

    # The other side of that asymmetry, and the regression it exists to prevent:
    # a typo in a table this class never reads must cost that table's feature
    # and NOT the session. `[epics]` is the neighbour with the loudest refusal,
    # so it is the one worth pinning.
    it "is unmoved by a typo in a table it does not read" do
      in_tree(config: %(epics = "not a table"\n\n[sensitivity]\ndenied = ["*.secret"]\n)) do |root, home|
        classifier = described_class.classifier(project: project_at(root), paths: paths_at(home))

        expect(classifier.classify(File.join(root, "prod.secret")).reason).to eq(:configured)
      end
    end

    # A file nobody can parse costs the project its ADDITIONS and says so; the
    # built-in tables are unaffected, because they were never in the file. Told
    # rather than dropped -- silence here would be a boundary quietly narrowing.
    it "degrades to the built-in rules when the file will not parse, and reports it" do
      in_tree(config: "this is not [valid toml") do |root, home|
        said = []
        classifier = described_class.classifier(project: project_at(root), paths: paths_at(home),
                                                notice: ->(message) { said << message })

        expect(classifier.classify(File.join(home, ".ssh", "id_rsa")).reason).to eq(:protected)
        expect(said.join).to match(/\[sensitivity\].*not in force/)
      end
    end

    it "stays silent about a file that parses" do
      in_tree(config: %([sensitivity]\ndenied = ["*.secret"]\n)) do |root, home|
        said = []
        described_class.classifier(project: project_at(root), paths: paths_at(home),
                                   notice: ->(message) { said << message })

        expect(said).to be_empty
      end
    end
  end

  describe ".for" do
    it "hands the board a live policy rather than the Null" do
      in_tree do |root, home|
        board = board_for(root, home)

        expect(board.sensitivity).not_to equal(Lain::Sensitivity::Policy::Null.instance)
        expect(board.sensitivity.gates?(read_of(File.join(root, ".env")))).to be(true)
      end
    end

    # The two vocabularies, asserted apart. A project that RESTRICTS paths and
    # grants no call shapes must come back with a live path boundary and an
    # EMPTY approval rung -- the `[sensitivity]` table must never arrive at the
    # deterministic rung as a remembered answer.
    it "keeps the sensitivity table out of the approval rung" do
      in_tree(config: "[sensitivity]\ndenied = [\"*.secret\"]\n") do |root, home|
        board = board_for(root, home)

        expect(board.instance_variable_get(:@rules)).to be_empty
        expect(board.sensitivity.denial(read_of(File.join(root, "a.secret")))&.reason).to eq(:configured)
      end
    end
  end
end
