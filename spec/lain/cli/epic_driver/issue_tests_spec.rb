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

  def role_spawn(provider)
    Lain::Skill::RoleSpawn.new(provider:, context_factory: -> { Lain::Context.new(model: "child", max_tokens: 256) },
                               toolset: union, parent: Lain::Timeline.empty(store: Lain::Store.new), slots:,
                               tool_middleware: ToolRegistry::UNGUARDED)
  end

  def step(provider, harness: rspec)
    described_class.new(renderer:, role_spawn: role_spawn(provider), harness:)
                   .call(criteria, worker_env, subject: "app/models/order.rb")
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

  it "refuses tests that pass before any work is done, and commits nothing" do
    head = git(held, "rev-parse", "HEAD")

    expect { step(writing(target, green)) }
      .to raise_error(Lain::Error, /#{Regexp.escape(target)}/)
    expect(git(held, "rev-parse", "HEAD")).to eq(head)
  end

  # Enforcement is opt-in: a framework the files betray is never read as a
  # declared layout, which would impose level roots the project never chose.
  it "refuses, naming [tests], a project that declares no test layout, and spawns nothing" do
    FileUtils.rm(File.join(held, ".lain", "config.toml"))
    File.write(File.join(held, ".rspec"), "--format progress\n")
    provider = mock(text_response("unused"))

    expect { step(provider, harness: unrun) }
      .to raise_error(Lain::Error, /declares no test layout.*add a \[tests\] table/m)
    expect(provider.call_count).to eq(0)
  end

  it "refuses a child that wrote its tests anywhere but the layout's path, and commits nothing" do
    head = git(held, "rev-parse", "HEAD")

    expect { step(writing("spec/models/order_spec.rb", red), harness: unrun) }
      .to raise_error(Lain::Error, /#{Regexp.escape(target)}/)
    expect(git(held, "rev-parse", "HEAD")).to eq(head)
  end
end
