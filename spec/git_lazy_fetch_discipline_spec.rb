# frozen_string_literal: true

require "prism"
require "open3"
require "tmpdir"

# In a partial clone a git read that meets a missing object fetches it, and the fetch runs the program
# `remote.<name>.uploadpack` names. Every git lain spawns carries GIT_NO_LAZY_FETCH=1 so a cloned repository
# cannot run code through lain's own reads. The scan finds each file that spawns git; each one is driven for
# real here and the env its git child got is read off the spawn, so a site whose code drops the variable is
# red even when a comment still names it. The scan reads literals only: a git program spelled through a
# computed value, such as `"g" + "it"` or a constant built from another, is not seen.
module GitLazyFetchDiscipline
  SPAWNERS = %i[new call run spawn system exec popen popen2 popen2e popen3 capture2 capture2e capture3
                pipeline pipeline_r pipeline_w pipeline_rw].freeze

  # Constants that hold "git" as data and spawn nothing with it, by file. Only these writes are skipped, so
  # a spawn added elsewhere in the same file is still found.
  NOT_SPAWNING = {
    "lain/shell/programs.rb" => { OPTION_DIRECTED: "lists program names the shell reader treats alike" },
    "lain/approval/composed_term.rb" => {
      GIT: "is the label a printed approval row shows",
      LOCATORS: "names the cargo config keys that locate a source"
    },
    "lain/isolation/worktree/registry.rb" => { LABEL: "names the backend in a refusal" }
  }.freeze

  # A `"git"` or `"git ..."` program in any spelling: a spawner's argument, an argv literal, a constant
  # holding either, or backticks.
  class Finder < Prism::Visitor
    # @param exempt [Array<Symbol>] constants whose git is data
    def initialize(exempt = [])
      super()
      @exempt = exempt
      @exempted = []
      @found = false
    end

    def found? = @found

    # The exempt constants that are still there and still hold git.
    attr_reader :exempted

    def visit_call_node(node)
      @found ||= SPAWNERS.include?(node.name) && node.arguments&.arguments.to_a.any? { program?(_1) }
      super
    end

    def visit_array_node(node)
      @found ||= git?(node.elements.first)
      super
    end

    def visit_constant_write_node(node)
      held = program?(unfrozen(node.value))
      return @exempted << node.name if held && @exempt.include?(node.name)

      @found ||= held
      super
    end

    def visit_x_string_node(node)
      @found ||= node.unescaped.lstrip.start_with?("git")
      super
    end

    def visit_interpolated_x_string_node(node)
      first = node.parts.first
      @found ||= first.is_a?(Prism::StringNode) && first.unescaped.lstrip.start_with?("git")
      super
    end

    private

    def program?(node)
      node = node.expression if node.is_a?(Prism::SplatNode)
      git?(node) || shell_line?(node) || (node.is_a?(Prism::ArrayNode) && git?(node.elements.first))
    end

    def unfrozen(node) = node.is_a?(Prism::CallNode) && node.name == :freeze ? node.receiver : node

    def git?(node) = node.is_a?(Prism::StringNode) && node.unescaped == "git"

    def shell_line?(node) = node.is_a?(Prism::StringNode) && node.unescaped.start_with?("git ")
  end

  def self.lib = File.expand_path("../lib", __dir__)

  def self.flagged = Dir.glob("**/*.rb", base: lib).sort.select { scan(_1).found? }

  def self.exempted = NOT_SPAWNING.keys.to_h { [_1, scan(_1).exempted.sort] }

  def self.scan(path)
    Finder.new(NOT_SPAWNING.fetch(path, {}).keys).tap { Prism.parse_file(File.join(lib, path)).value.accept(_1) }
  end

  # Each git spawn's environment, read where the child is made.
  class Spawns
    def initialize = @envs = []

    def record(args)
      env, command = args.first.is_a?(Hash) ? args : [{}, *args]
      program = Array(command).first.to_s
      @envs << env if File.basename(program) == "git" || program.start_with?("git ")
    end

    attr_reader :envs
  end
end

RSpec.describe "git lazy fetch discipline" do
  let(:refused) { { "GIT_NO_LAZY_FETCH" => "1" } }
  let(:spawns) { GitLazyFetchDiscipline::Spawns.new }

  # The fixture's own git is built before recording starts, so only the site's spawns are read.
  before do
    repo
    recorder = spawns
    allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **opts|
      recorder.record(args)
      original.call(*args, **opts)
    end
    %i[capture2 capture2e capture3].each do |name|
      allow(Open3).to receive(name).and_wrap_original do |original, *args, **opts|
        recorder.record(args)
        original.call(*args, **opts)
      end
    end
  end

  around do |example|
    Dir.mktmpdir("lain-git-lazy-fetch") { |made| (@base = File.realpath(made)) and example.run }
  end

  def repo
    @repo ||= SeedRepo.derived("git lazy fetch discipline", into: File.join(@base, "repo")) { nil }
  end

  def scratch(name) = File.join(@base, name).tap { FileUtils.mkdir_p(_1) }

  # Each file that spawns git, and a drive through it.
  sites = {
    "lain/approval/composed_term/repository.rb" => lambda {
      Lain::Approval::ComposedTerm::Repository.git("rev-parse", "HEAD", directory: repo)
    },
    "lain/approval/judgement.rb" => lambda {
      Lain::Approval::Judgement.const_get(:OwnHistory).new("git log", root: repo, files: nil, env: {})
                               .send(:no_driver_configured?)
    },
    "lain/approval/lease_commit.rb" => lambda {
      rule = Lain::Approval::LeaseCommit.allocate
      git = Struct.new(:resolved).new("git")
      env = { "PATH" => ENV.fetch("PATH") }
      config = File.join(@base, "gitconfig").tap { File.write(_1, "") }
      rule.send(:no_gitlink?, repo, git, env)
      rule.send(:no_filter?, git, env, repo)
      rule.send(:reads_only?, git, env.merge("GIT_CONFIG_GLOBAL" => config), repo, [config])
    },
    "lain/bench/hot_paths.rb" => lambda {
      Lain::Bench::HotPaths.new.send(:git_init, scratch("bench"))
      Lain::Bench::HotPaths::Corpus.mask_list(scratch("bench-mask"))
    },
    "lain/confine/profile.rb" => -> { Lain::Confine::Profile.const_get(:Seal).git_dirs(repo) },
    "lain/confine/profiles.rb" => lambda {
      Lain::Confine::Profiles.const_get(:Sealed).new(home: @base, tmpdir: scratch("tmp")).configs(repo)
    },
    "lain/grader/mutation_reinsertion.rb" => lambda {
      patch = File.join(@base, "none.patch").tap { File.write(_1, "") }
      Lain::Grader::MutationReinsertion.const_get(:Runs).allocate
                                       .send(:applied?, Struct.new(:patch_path).new(patch), repo)
    },
    "lain/isolation/checkout.rb" => -> { Lain::Isolation::Checkout.new(repo).run("rev-parse", "HEAD") },
    "lain/isolation/worker_id.rb" => -> { Lain::Isolation::WorkerId.checked("worker-1") },
    "lain/session_record/provenance.rb" => -> { Lain::SessionRecord::Provenance.harness(gem_root: repo) },
    "lain/workspace/snapshot/scope/shadow_git/repository.rb" => lambda {
      Lain::Workspace::Snapshot::Scope::ShadowGit::Repository
        .new(root: repo, dir: File.join(@base, "shadow"), index: File.join(@base, "shadow-index"),
             shell_out_factory: Lain::Shell::Out.method(:new))
        .ready.stage
    }
  }

  it "finds git spawned only at the sites driven here" do
    expect(GitLazyFetchDiscipline.flagged).to eq(sites.keys.sort)
  end

  it "skips only exempt constants that are still there and still hold git" do
    expect(GitLazyFetchDiscipline.exempted)
      .to eq(GitLazyFetchDiscipline::NOT_SPAWNING.transform_values { _1.keys.sort })
  end

  sites.each do |path, drive|
    it "refuses a lazy fetch in every git #{path} spawns" do
      instance_exec(&drive)

      expect(spawns.envs).not_to be_empty
      expect(spawns.envs).to all(include(refused))
    end
  end
end
