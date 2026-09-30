# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# An issue's red step, in the checkout its actor holds: tests generated from the
# issue's approved criteria into the file the project's layout mirrors from the
# subject, run there, and committed on the issue's branch only once they fail.
# Real git and a real rspec child, over a copy of layout_mini checked out on an
# issue branch in a linked worktree -- the shape an adopted lease has once the
# actor's branch is cut.
RSpec.describe Lain::CLI::EpicDriver::IssueTests, :seam do
  around do |example|
    Dir.mktmpdir("lain-issue-tests") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(repo)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", repo)
      FileUtils.cp_r(File.join(layout_mini, "."), repo)
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "layout_mini")
      git(repo, "worktree", "add", "-q", "-b", "lain/issue/demo/a", held)
      example.run
    end
  end

  let(:layout_mini) { File.expand_path("../../../fixtures/projects/layout_mini", __dir__) }
  let(:target) { "spec/unit/models/order_spec.rb" }
  let(:worker_env) { Lain::WorkerEnv.default.with(cwd: held, checkout: held) }
  let(:criteria) do
    Lain::Gherkin::Criteria.parse(<<~MD)
      ```gherkin
      Scenario: an order totals its lines
        Given an order with lines of 1 and 2
        When it is totalled
        Then the total is 3

      Scenario: an order can be refunded
        Given a totalled order
        When it is refunded
        Then its total is 0
      ```
    MD
  end
  let(:union) do
    Lain::Toolset.new([
                        Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                        Lain::Tools::Grep.new, Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new,
                        Lain::Tools::TodoWrite.new, Lain::Tools::Bash.new
                      ])
  end
  let(:slots) { Lain::Prompt::Slots.load(root: repo) }
  let(:renderer) { Lain::Skill::Renderer.new(catalog: Lain::Skill::Catalog.load, slots:) }
  let(:rspec) { ->(root) { Lain::Grader::TestHarness.new(root, adapter: Lain::Grader::TestHarness::Adapter::Rspec.new) } }
  let(:unrun) { ->(_root) { raise "no suite should run once generation has failed" } }

  # Two examples the subject does not satisfy, so the step is red.
  let(:red) do
    <<~RUBY
      # frozen_string_literal: true

      require_relative "../../../app/models/order"

      RSpec.describe Order do
        it("totals its lines") { expect(Order.new.total).to eq(3) }
        it("can be refunded") { expect(Order.new).to respond_to(:refund) }
      end
    RUBY
  end

  # One example the subject already satisfies.
  let(:green) do
    <<~RUBY
      # frozen_string_literal: true

      require_relative "../../../app/models/order"

      RSpec.describe Order do
        it("starts empty") { expect(Order.new.total).to eq(0) }
      end
    RUBY
  end

  def repo = File.join(@root, "repo")
  def held = File.join(@root, "issue-a")

  # This spec's own git runs only inside the fixture's temp tree; the scrub is
  # for the hook's GIT_INDEX_FILE reason.
  def git(dir, *args)
    raise "refusing to run git outside the fixture: #{dir}" unless dir.start_with?("#{@root}/")

    shell = Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout.strip
  end

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  # The test_engineer child, scripted: it writes `body` at `path` through the
  # real write_file tool, which resolves the path in the checkout it runs in.
  # write_file makes no directories and git carries none, so the fixture does.
  def writing(path, body)
    FileUtils.mkdir_p(File.dirname(File.join(held, path)))
    mock(tool_response(["w1", "write_file", { "path" => path, "content" => body }]), text_response("wrote the spec"))
  end

  # write_file will not overwrite a file the child has not read, so a child
  # replacing tests an earlier run committed does it through the shell.
  def overwriting(path, body)
    command = "printf '%s' '#{[body].pack("m0")}' | base64 -d > #{path}"
    mock(tool_response(["b1", "bash", { "command" => command }]), text_response("rewrote the spec"))
  end

  def role_spawn(provider)
    Lain::Skill::RoleSpawn.new(provider:, context_factory: -> { Lain::Context.new(model: "child", max_tokens: 256) },
                               toolset: union, parent: Lain::Timeline.empty(store: Lain::Store.new), slots:,
                               tool_middleware: ToolRegistry::UNGUARDED)
  end

  # The layout is the PROJECT's, resolved from the repository root the held
  # checkout was cut from -- never from the checkout, which a gitignored
  # config never reaches.
  def step(provider, harness: rspec, since: git(repo, "rev-parse", "HEAD"))
    described_class.new(renderer:, role_spawn: role_spawn(provider), layout: Lain::Config.test_layout(root: repo),
                        harness:)
                   .call(criteria, worker_env, subject: "app/models/order.rb", since:)
  end

  # What an earlier run's red step left on a kept branch: the tests, committed
  # under the message that names their target and criteria.
  def committed_earlier(body, digest: criteria.digest)
    FileUtils.mkdir_p(File.dirname(File.join(held, target)))
    File.write(File.join(held, target), body)
    git(held, "add", "--", target)
    git(held, "commit", "--no-verify", "-q", "-m", "test: failing tests at #{target}, from criteria #{digest}")
    git(held, "rev-parse", "HEAD")
  end

  def work_committed
    File.write(File.join(held, "refund.txt"), "refund\n")
    git(held, "add", "refund.txt")
    git(held, "commit", "-q", "-m", "work")
    git(held, "rev-parse", "HEAD")
  end

  def first_prompt(provider) = provider.requests.first.messages.first["content"].first["text"]

  it "writes the tests where the layout mirrors the subject, runs them red, and commits them on the issue's branch" do
    provider = writing(target, red)
    parent_head = git(repo, "rev-parse", "HEAD")

    result = step(provider)

    expect(File.read(File.join(held, target))).to eq(red)
    expect(result.run).not_to be_clean
    expect(result.run.failed.size).to eq(2)
    expect(git(held, "rev-parse", "lain/issue/demo/a")).to eq(result.sha)
    expect(git(held, "show", "--name-only", "--format=", result.sha).split("\n")).to eq([target])
    expect(git(held, "status", "--porcelain")).to eq("")
    expect(git(repo, "rev-parse", "HEAD")).to eq(parent_head)
    expect(first_prompt(provider)).to include(target, "an order totals its lines", "an order can be refunded")
  end

  # A gitignored .lain/config.rb stays in the project root: `worktree add`
  # carries only what git tracks, so the held checkout has no config at all.
  it "writes the tests with the project's layout when the held checkout carries no config" do
    FileUtils.rm(File.join(held, ".lain", "config.rb"))

    result = step(writing(target, red))

    expect(git(held, "show", "--name-only", "--format=", result.sha).split("\n")).to eq([target])
  end

  it "refuses tests that pass before any work is done, and commits nothing" do
    head = git(held, "rev-parse", "HEAD")

    expect { step(writing(target, green)) }
      .to raise_error(Lain::Error, /#{Regexp.escape(target)}/)
    expect(git(held, "rev-parse", "HEAD")).to eq(head)
  end

  # Enforcement is opt-in: a framework the files betray is never read as a
  # declared layout, which would impose level roots the project never chose.
  it "refuses, naming the tests verb, a project that declares no test layout, and spawns nothing" do
    FileUtils.rm(File.join(repo, ".lain", "config.rb"))
    File.write(File.join(held, ".rspec"), "--format progress\n")
    provider = mock(text_response("unused"))

    expect { step(provider, harness: unrun) }
      .to raise_error(Lain::Error, %r{declares no test layout.*add a `tests` line to \.lain/config\.rb}m)
    expect(provider.call_count).to eq(0)
  end

  it "refuses a child that wrote its tests anywhere but the layout's path, and commits nothing" do
    head = git(held, "rev-parse", "HEAD")

    expect { step(writing("spec/models/order_spec.rb", red), harness: unrun) }
      .to raise_error(Lain::Error, /#{Regexp.escape(target)}/)
    expect(git(held, "rev-parse", "HEAD")).to eq(head)
  end

  # The refusal used to quote the guard's accepting verdict ("... mirrors ..."),
  # which read as the reason when the target was merely left untouched.
  it "refuses a child that left the target as it stood, saying so rather than quoting the layout's verdict" do
    committed_earlier(red, digest: "blake3:other")

    expect { step(writing(target, red), harness: unrun) }
      .to raise_error(Lain::Error, /left #{Regexp.escape(target)} exactly as it already stood/) { |error|
        expect(error.message).not_to include("mirrors")
      }
  end

  context "when the branch already holds this step's commit from an earlier run" do
    it "carries it forward while its tests still fail, spawning nothing and committing nothing" do
      earlier = committed_earlier(red)
      provider = mock

      result = step(provider)

      expect([result.sha, result.carried, result.record.target]).to eq([earlier, true, target])
      expect(result.run.failed.size).to eq(2)
      expect(git(held, "rev-parse", "HEAD")).to eq(earlier)
      expect(provider.call_count).to eq(0)
    end

    it "carries it forward from under implementation commits that have not yet turned it green" do
      earlier = committed_earlier(red)
      worked = work_committed

      result = step(mock)

      expect(result.sha).to eq(earlier)
      expect(git(held, "rev-parse", "HEAD")).to eq(worked)
    end

    it "refuses, without claiming no work was done, once those tests no longer fail" do
      committed_earlier(green)
      head = git(held, "rev-parse", "HEAD")
      provider = mock

      expect { step(provider) }.to raise_error(Lain::Error, /no longer fail on this branch/) { |error|
        expect(error.message).not_to include("before any work")
        # A resumed or forked chat is never asked, so the remedy has to work
        # from somewhere that will ask.
        expect(error.message).to include("start a new chat and answer delete", "delete `lain/issue/demo/a` yourself")
        expect(error.message).not_to include("delete `lain/issue/demo/a` (its tip is kept")
      }
      expect(git(held, "rev-parse", "HEAD")).to eq(head)
      expect(provider.call_count).to eq(0)
    end

    it "does not carry a commit whose message matches but which never touched the tests" do
      FileUtils.mkdir_p(File.dirname(File.join(held, target)))
      File.write(File.join(held, target), red)
      git(held, "add", "--", target)
      git(held, "commit", "--no-verify", "-q", "-m", "work that wrote the spec")
      File.write(File.join(held, "unrelated.txt"), "unrelated\n")
      git(held, "add", "unrelated.txt")
      git(held, "commit", "--no-verify", "-q", "-m",
          "test: failing tests at #{target}, from criteria #{criteria.digest}")
      provider = overwriting(target, red.sub("totals its lines", "totals its two lines"))

      result = step(provider)

      expect(result.carried).to be(false)
      expect(provider.call_count).to eq(2)
    end

    # Only the branch's own line is this issue's history; a merged side branch
    # is somebody else's.
    it "does not carry a commit reachable only through a merged side branch" do
      git(held, "switch", "-q", "-c", "side")
      committed_earlier(red)
      git(held, "switch", "-q", "lain/issue/demo/a")
      work_committed
      git(held, "merge", "--no-ff", "-q", "-m", "merge side", "side")
      provider = overwriting(target, red.sub("totals its lines", "totals its two lines"))

      result = step(provider)

      expect(result.carried).to be(false)
      expect(provider.call_count).to eq(2)
    end

    it "generates afresh over a commit made from other criteria" do
      stale = committed_earlier(green, digest: "blake3:other")
      provider = overwriting(target, red)

      result = step(provider)

      expect(result.carried).to be(false)
      expect(git(held, "rev-parse", "#{result.sha}^")).to eq(stale)
      expect(provider.call_count).to eq(2)
    end

    # A commit the lease's base already holds belongs to the epic, not to this
    # issue's earlier run.
    it "does not carry a commit that sits at or below the base the lease was cut from" do
      committed_earlier(red)
      provider = overwriting(target, red.sub("totals its lines", "totals its two lines"))

      result = step(provider, since: git(held, "rev-parse", "HEAD"))

      expect(result.carried).to be(false)
      expect(provider.call_count).to eq(2)
    end
  end
end
