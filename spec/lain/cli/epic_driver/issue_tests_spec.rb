# frozen_string_literal: true

require "fileutils"
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
      SeedRepo.with_layout(layout_mini, into: repo)
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
  let(:spawned) { [] }
  let(:parent) { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) }

  def repo = File.join(@root, "repo")
  def held = File.join(@root, "issue-a")

  # This spec's own git runs only inside the fixture's temp tree; the scrub is
  # for the hook's GIT_INDEX_FILE reason.
  def git(dir, *) = SeedRepo.git(inside_fixture(dir), *).stdout.strip

  def inside_fixture(dir)
    raise "refusing to run git outside the fixture: #{dir}" unless dir.start_with?("#{@root}/")

    dir
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
                               toolset: union, parent:, slots:, observer: spawned.method(:push),
                               tool_middleware: ToolRegistry::UNGUARDED)
  end

  # The layout is the PROJECT's, resolved from the repository root the held
  # checkout was cut from -- never from the checkout, which a gitignored
  # config never reaches.
  def step(provider, harness: rspec, since: git(repo, "rev-parse", "HEAD"), lane: "issue.demo.a.1",
           subject: "app/models/order.rb", level: nil, name: nil, shell_out_factory: Lain::Shell::Out.public_method(:new))
    layout = Lain::Config.test_layout(root: repo)
    described_class.new(renderer:, role_spawn: role_spawn(provider), layout:, harness:, shell_out_factory:,
                        test_layout: Lain::Middleware::GuardTestLayout::Run.new(layout:, root: repo))
                   .call(criteria, worker_env, subject:, since:, lane:, level:, name:)
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

  # The child writes behind the board's layout guard, which reads the target
  # IssueTests declared to the run they share. Without that declaration a new
  # file inside an existing module reads as a split sibling of the module's test.
  describe "a new file inside an existing module, behind the board's layout guard" do
    let(:nested) { "spec/unit/models/order/hello_spec.rb" }
    let(:run) { Lain::Middleware::GuardTestLayout::Run.new(layout: Lain::Config.test_layout(root: repo), root: repo) }
    let(:journal) { [] }
    let(:greeting) do
      "require_relative \"../../../../app/models/order\"\n\nRSpec.describe Order do\n  " \
        "it(\"greets\") { expect(Order.new).to respond_to(:hello) }\nend\n"
    end

    def guarded(env, **)
      Lain::Middleware::Stack.new([Lain::Middleware::GuardTestLayout.new(run:, roots: run.roots_for(env), journal:),
                                   Lain::Middleware::Sensitivity.new,
                                   Lain::Middleware::Gate.new(policy: Lain::Middleware::Gate::ApproveAll.new)])
    end

    def guarded_spawn
      Lain::Skill::RoleSpawn.new(provider: writing(nested, greeting),
                                 context_factory: -> { Lain::Context.new(model: "child", max_tokens: 256) },
                                 toolset: union, parent: CoreGraph.timeline, slots:,
                                 tool_middleware: ToolRegistry.builder { |env, **| guarded(env) })
    end

    def nested_step
      described_class.new(renderer:, role_spawn: guarded_spawn, layout: Lain::Config.test_layout(root: repo),
                          test_layout: run, harness: rspec)
                     .call(criteria, worker_env, subject: "app/models/order/hello.rb",
                                                 since: git(repo, "rev-parse", "HEAD"), lane: "issue.demo.a.1")
    end

    it "declares its target to the run, so the guarded write lands and counts as generated" do
      result = nested_step

      expect(run.declared(held)).to eq([nested])
      expect(result.record).to have_attributes(target: nested, generated?: true)
      expect(journal.map(&:class)).to include(Lain::Telemetry::TestLayoutDeferred)
    end
  end

  # A retry's child spawns from the same head over the same Store; only the
  # attempt's lane tells its :spawn from the failed attempt's.
  it "gives a retried red step a :spawn address the failed attempt's did not hold" do
    expect { step(mock(text_response("no tests"), text_response("no tests")), lane: "issue.demo.a.1") }
      .to raise_error(Lain::Error)

    step(writing(target, red), lane: "issue.demo.a.2")

    digests = spawned.select { |event| event.kind == :spawn }.map(&:digest)
    expect(digests.size).to eq(2)
    expect(digests.uniq.size).to eq(2)
  end

  it "refuses tests that pass before any work is done, and commits nothing" do
    head = git(held, "rev-parse", "HEAD")

    expect { step(writing(target, green)) }
      .to raise_error(Lain::Error, /#{Regexp.escape(target)}/)
    expect(git(held, "rev-parse", "HEAD")).to eq(head)
  end

  it "refuses tests that never load, quoting the load error, and commits nothing" do
    head = git(held, "rev-parse", "HEAD")
    broken = "require_relative \"../../../app/models/missing_order\"\n\nRSpec.describe(Object) { it(\"x\") { } }\n"

    expect { step(writing(target, broken)) }
      .to raise_error(Lain::Error, /did not load.*missing_order/m)
    expect(git(held, "rev-parse", "HEAD")).to eq(head)
  end

  context "when the described constant is the subject's own, not yet written" do
    let(:greeting_target) { "spec/unit/models/greeting_spec.rb" }
    let(:describing_greeting) do
      "RSpec.describe Greeting do\n  it(\"greets\") { expect(Greeting.new).to respond_to(:hello) }\nend\n"
    end

    def step_for_greeting(body) = step(writing(greeting_target, body), subject: "app/models/greeting.rb")

    it "commits the tests as red, the run's only error being the uninitialized constant" do
      result = step_for_greeting(describing_greeting)

      expect(result.run.errors.size).to eq(1)
      expect(result.run.errors.first).to include("uninitialized constant Greeting")
      expect(git(held, "show", "--name-only", "--format=", result.sha).split("\n")).to eq([greeting_target])
    end

    it "still refuses a misspelt constant when the subject exists, and commits nothing" do
      File.write(File.join(held, "app/models/greeting.rb"), "class Greeting; end\n")
      git(held, "add", "app/models/greeting.rb")
      git(held, "commit", "-q", "-m", "subject")
      head = git(held, "rev-parse", "HEAD")

      expect { step_for_greeting(describing_greeting.gsub("Greeting", "Greting")) }
        .to raise_error(Lain::Error, /did not load.*Greting/m)
      expect(git(held, "rev-parse", "HEAD")).to eq(head)
    end

    it "refuses the same missing constant once the subject file exists, since the test then never loads it" do
      File.write(File.join(held, "app/models/greeting.rb"), "class Greeting; end\n")
      git(held, "add", "app/models/greeting.rb")
      git(held, "commit", "-q", "-m", "subject")

      expect { step_for_greeting(describing_greeting) }
        .to raise_error(Lain::Error, /did not load.*uninitialized constant Greeting/m)
    end

    it "accepts a namespaced constant ending in the subject's name, matching only the last segment" do
      namespaced = "module Billing; end\n#{describing_greeting.gsub("Greeting", "Billing::Greeting")}"

      expect(step_for_greeting(namespaced).run.errors.first).to include("uninitialized constant Billing::Greeting")
    end

    it "refuses a constant the subject does not define" do
      expect { step_for_greeting(describing_greeting.gsub("Greeting", "Farewell")) }
        .to raise_error(Lain::Error, /did not load.*Farewell/m)
    end
  end

  # A git that cannot answer is not a git that answered "nothing".
  def failing_git(subcommand)
    Lain::Shell::Out.public_method(:new)
    lambda do |*argv, **options|
      broken = argv.include?(subcommand)
      Lain::Shell::Out.new(*(broken ? ["sh", "-c", "echo bad #{subcommand} >&2; exit 128"] : argv), **options)
    end
  end

  it "reports git's error when status fails, rather than treating the tree as clean" do
    provider = writing(target, red)

    expect { step(provider, shell_out_factory: failing_git("status")) }
      .to raise_error(Lain::Isolation::Checkout::Failed, /git status failed.*bad status/m)
    expect(provider.call_count).to eq(0)
  end

  it "reports git's error when the log of earlier commits fails, rather than finding none" do
    committed_earlier(red)
    provider = mock

    expect { step(provider, shell_out_factory: failing_git("log")) }
      .to raise_error(Lain::Isolation::Checkout::Failed, /git log failed.*bad log/m)
    expect(provider.call_count).to eq(0)
  end

  it "refuses a red step that also wrote the subject, naming it, and commits nothing" do
    head = git(held, "rev-parse", "HEAD")
    provider = mock(tool_response(["w1", "write_file", { "path" => target, "content" => red }],
                                  ["w2", "write_file", { "path" => "app/models/greet.rb", "content" => "x = 1\n" }]),
                    text_response("wrote the spec"))
    FileUtils.mkdir_p(File.dirname(File.join(held, target)))

    expect { step(provider) }.to raise_error(Lain::Error, %r{app/models/greet\.rb})
    expect(git(held, "rev-parse", "HEAD")).to eq(head)
  end

  it "names the stray subject even when it makes the tests pass" do
    satisfied = "class Order\n  def total = 3\n  def refund = 0\nend\n"
    shell = ->(body) { "printf '%s' '#{[body].pack("m0")}' | base64 -d" }
    provider = mock(tool_response(["w1", "write_file", { "path" => target, "content" => red }]),
                    tool_response(["b1", "bash", { "command" => "#{shell.call(satisfied)} > app/models/order.rb" }]),
                    text_response("wrote the spec"))
    FileUtils.mkdir_p(File.dirname(File.join(held, target)))

    expect { step(provider) }.to raise_error(Lain::Error, %r{app/models/order\.rb}) { |error|
      expect(error.message).not_to include("none failed")
    }
  end

  it "accepts a helper the child wrote under the test tree" do
    helper = "spec/support/shared.rb"
    FileUtils.mkdir_p(File.join(held, "spec/support"))
    both = mock(tool_response(["w1", "write_file", { "path" => target, "content" => red }],
                              ["w2", "write_file", { "path" => helper, "content" => "# helper\n" }]),
                text_response("wrote the spec"))
    FileUtils.mkdir_p(File.dirname(File.join(held, target)))

    expect(step(both).record.target).to eq(target)
  end

  it "lets the run rewrite the tracked Gemfile.lock and keeps it out of the red commit" do
    File.write(File.join(held, "Gemfile.lock"), "GEM\n")
    git(held, "add", "--", "Gemfile.lock")
    git(held, "commit", "--no-verify", "-q", "-m", "lock")
    provider = mock(tool_response(["w1", "write_file", { "path" => target, "content" => red }]),
                    tool_response(["b1", "bash", { "command" => "printf 'CHECKSUMS\\n' >> Gemfile.lock" }]),
                    text_response("wrote the spec"))
    FileUtils.mkdir_p(File.dirname(File.join(held, target)))

    sha = step(provider).sha

    expect(git(held, "show", "--name-only", "--format=", sha)).to eq(target)
  end

  it "refuses a deleted tracked file" do
    provider = mock(tool_response(["w1", "write_file", { "path" => target, "content" => red }]),
                    tool_response(["b1", "bash", { "command" => "rm app/models/order.rb" }]),
                    text_response("wrote the spec"))
    FileUtils.mkdir_p(File.dirname(File.join(held, target)))

    expect { step(provider) }.to raise_error(Lain::Error, %r{app/models/order\.rb})
  end

  it "keeps a renamed path whole when the child moved a tracked file" do
    provider = mock(tool_response(["w1", "write_file", { "path" => target, "content" => red }]),
                    tool_response(["b1", "bash", { "command" => "git mv app/models/order.rb app/models/moved.rb" }]),
                    text_response("wrote the spec"))
    FileUtils.mkdir_p(File.dirname(File.join(held, target)))

    expect { step(provider) }.to raise_error(Lain::Error, %r{app/models/moved\.rb})
  end

  context "with the cargo preset and an inline target" do
    let(:meeting) { "src/meeting.rs" }
    let(:body) { "#[cfg(test)]\nmod tests {\n    #[test] fn starts() { super::start(); }\n}\n" }

    before do
      File.write(File.join(repo, ".lain", "config.rb"), "tests preset: :cargo, source_roots: %w[src]\n")
      trust_project(repo)
      seed_crate_root
    end

    def seed_crate_root
      FileUtils.mkdir_p(File.join(held, "src"))
      File.write(File.join(held, "src/lib.rs"), "pub fn old() {}\n")
      git(held, "add", "--", "src/lib.rs")
      git(held, "commit", "--no-verify", "-q", "-m", "crate root")
    end

    def diagnostic(code, file, message = "cannot find function `start`")
      JSON.generate(reason: "compiler-message",
                    message: { level: "error", message:, code: { code: },
                               spans: [{ is_primary: true, file_name: file }] })
    end

    # Cargo's own parsing, lockfile and build dir, with the child process replaced by canned stdout.
    def cargo_printing(*lines)
      canned = File.join(@root, "cargo.out")
      File.write(canned, lines.join("\n"))
      adapter = Class.new(Lain::Grader::TestHarness::Adapter::Cargo) do
        define_method(:command) { |**| ["cat", canned] }
      end.new(held)
      ->(root) { Lain::Grader::TestHarness.new(root, adapter:) }
    end

    def cargo_step(harness, extra: nil)
      FileUtils.mkdir_p(File.join(held, "src"))
      calls = [tool_response(["w1", "write_file", { "path" => meeting, "content" => body }])]
      calls << tool_response(["b1", "bash", { "command" => extra }]) if extra
      step(mock(*calls, text_response("done")), harness:, subject: meeting, level: "unit")
    end

    it "commits the tests as red when the only errors are missing items in the subject" do
      result = cargo_step(cargo_printing(diagnostic("E0425", meeting)))

      expect(git(held, "show", "--name-only", "--format=", result.sha).split("\n").sort).to eq(["src/lib.rs", meeting])
    end

    it "refuses an error of another kind as not loading, and commits nothing" do
      head = git(held, "rev-parse", "HEAD")

      expect { cargo_step(cargo_printing(diagnostic("E0308", meeting, "mismatched types"))) }
        .to raise_error(Lain::Error, /did not load.*E0308/m)
      expect(git(held, "rev-parse", "HEAD")).to eq(head)
    end

    it "refuses a missing item in another file, and commits nothing" do
      head = git(held, "rev-parse", "HEAD")

      expect { cargo_step(cargo_printing(diagnostic("E0425", "src/other.rs"))) }
        .to raise_error(Lain::Error, /did not load/)
      expect(git(held, "rev-parse", "HEAD")).to eq(head)
    end

    it "keeps a rewritten tracked Cargo.lock out of the red commit and does not call it stray" do
      File.write(File.join(held, "Cargo.lock"), "# lock\n")
      git(held, "add", "--", "Cargo.lock")
      git(held, "commit", "--no-verify", "-q", "-m", "lock")

      result = cargo_step(cargo_printing(diagnostic("E0425", meeting)), extra: "printf 'more\\n' >> Cargo.lock")

      expect(git(held, "show", "--name-only", "--format=", result.sha).split("\n").sort).to eq(["src/lib.rs", meeting])
    end

    it "does not call an ungitignored target/ a stray write" do
      result = cargo_step(cargo_printing(diagnostic("E0425", meeting)),
                          extra: "mkdir -p target/debug && printf x > target/debug/out")

      expect(git(held, "show", "--name-only", "--format=", result.sha).split("\n").sort).to eq(["src/lib.rs", meeting])
    end
  end

  context "with the cargo preset and an integration level in a workspace member" do
    let(:subject_file) { "crates/store/src/lib.rs" }
    let(:integration) { "crates/store/tests/store-crate.rs" }
    let(:helper) { "crates/store/tests/common/mod.rs" }

    before do
      File.write(File.join(repo, ".lain", "config.rb"),
                 "tests preset: :cargo, source_roots: %w[src crates/store/src]\n")
      trust_project(repo)
      FileUtils.mkdir_p(File.join(held, "crates/store/tests/common"))
    end

    def cargo_failing
      canned = File.join(@root, "cargo.out")
      File.write(canned, "test round_trips ... FAILED\n")
      adapter = Class.new(Lain::Grader::TestHarness::Adapter::Cargo) do
        define_method(:command) { |**| ["cat", canned] }
      end.new(held)
      ->(root) { Lain::Grader::TestHarness.new(root, adapter:) }
    end

    def integration_step(since: git(repo, "rev-parse", "HEAD"))
      test = "#[test]\nfn round_trips() {}\n"
      provider = mock(tool_response(["w1", "write_file", { "path" => integration, "content" => test }]),
                      tool_response(["w2", "write_file", { "path" => helper, "content" => "pub fn seed() {}\n" }]),
                      text_response("done"))
      step(provider, harness: cargo_failing, subject: subject_file, level: "integration", name: "store-crate", since:)
    end

    it "writes the tests into the member's own tests/ file named for the issue, helper beside it, and commits them" do
      result = integration_step

      expect(result.record.target).to eq(integration)
      expect(git(held, "show", "--name-only", "--format=", result.sha).split("\n")).to eq([integration])
    end

    it "carries an earlier run's commit of the same integration file forward" do
      since = git(repo, "rev-parse", "HEAD")
      earlier = integration_step(since:).sha
      provider = mock

      result = step(provider, harness: cargo_failing, subject: subject_file, level: "integration",
                              name: "store-crate", since:)

      expect([result.sha, result.carried, provider.call_count]).to eq([earlier, true, 0])
    end
  end

  context "with the cargo preset and a new subject" do
    let(:meeting) { "src/meeting.rs" }
    let(:body) { "#[cfg(test)]\nmod tests {\n    #[test] fn starts() { super::start(); }\n}\n" }
    let(:nested) { "src/capture/pipewire.rs" }
    let(:erring_file) { meeting }
    let(:missing_item) do
      JSON.generate(reason: "compiler-message",
                    message: { level: "error", message: "cannot find function `start`", code: { code: "E0425" },
                               spans: [{ is_primary: true, file_name: erring_file }] })
    end

    before do
      File.write(File.join(repo, ".lain", "config.rb"), "tests preset: :cargo, source_roots: %w[src]\n")
      trust_project(repo)
      FileUtils.mkdir_p(File.join(held, "src"))
    end

    def commit_file(path, text)
      FileUtils.mkdir_p(File.dirname(File.join(held, path)))
      File.write(File.join(held, path), text)
      git(held, "add", "--", path)
      git(held, "commit", "--no-verify", "-q", "-m", "add #{path}")
    end

    def cargo_printing_missing_item
      canned = File.join(@root, "cargo.out")
      File.write(canned, missing_item)
      adapter = Class.new(Lain::Grader::TestHarness::Adapter::Cargo) do
        define_method(:command) { |**| ["cat", canned] }
      end.new(held)
      ->(root) { Lain::Grader::TestHarness.new(root, adapter:) }
    end

    def cargo_step(subject: meeting, path: subject, content: body)
      FileUtils.mkdir_p(File.join(held, File.dirname(path)))
      provider = mock(tool_response(["w1", "write_file", { "path" => path, "content" => content }]),
                      text_response("done"))
      step(provider, harness: cargo_printing_missing_item, subject:, level: "unit")
    end

    def committed_paths(result) = git(held, "show", "--name-only", "--format=", result.sha).split("\n").sort

    it "declares the module in the crate root and commits it with the tests" do
      commit_file("src/lib.rs", "pub fn old() {}\n")

      result = cargo_step

      expect(File.read(File.join(held, "src/lib.rs"))).to eq("pub fn old() {}\npub mod meeting;\n")
      expect(committed_paths(result)).to eq(["src/lib.rs", meeting])
      expect(git(held, "status", "--porcelain")).to eq("")
    end

    context "when the subject is nested" do
      let(:erring_file) { nested }

      it "declares a nested subject in its parent's mod.rs" do
        commit_file("src/lib.rs", "")
        commit_file("src/capture/mod.rs", "")

        result = cargo_step(subject: nested, content: body)

        expect(File.read(File.join(held, "src/capture/mod.rs"))).to eq("pub mod pipewire;\n")
        expect(committed_paths(result)).to eq(["src/capture/mod.rs", nested])
      end
    end

    it "changes no file but the target when the module is already declared" do
      commit_file("src/lib.rs", "mod meeting;\n")

      result = cargo_step

      expect(committed_paths(result)).to eq([meeting])
      expect(File.read(File.join(held, "src/lib.rs"))).to eq("mod meeting;\n")
    end

    it "refuses a subject whose parent module file is missing, and commits nothing" do
      commit_file("src/lib.rs", "")
      head = git(held, "rev-parse", "HEAD")

      expect { cargo_step(subject: "src/capture/pipewire.rs") }.to raise_error(Lain::Error, %r{src/capture\.rs})
      expect(git(held, "rev-parse", "HEAD")).to eq(head)
    end

    it "still calls the child's own write to the crate root a stray write" do
      commit_file("src/lib.rs", "")
      provider = mock(tool_response(["w1", "write_file", { "path" => meeting, "content" => body }]),
                      tool_response(["b1", "bash", { "command" => "printf 'fn extra() {}\\n' >> src/lib.rs" }]),
                      text_response("done"))

      expect { step(provider, harness: cargo_printing_missing_item, subject: meeting, level: "unit") }
        .to raise_error(Lain::Error, %r{also wrote src/lib\.rs})
    end
  end

  it "registers nothing for the rspec or command adapters" do
    command = Lain::Grader::TestHarness::Adapter::Command.new(out_argv: ->(out) { [out] }, passed: /P/, failed: /F/)
    adapters = [Lain::Grader::TestHarness::Adapter::Rspec.new, command]

    expect(adapters.map { |adapter| adapter.registration(subject: "app/models/order.rb", root: repo) }).to eq([[], []])
  end

  context "with a command adapter that reports errors inside tests" do
    def reporting(lines)
      lambda do |root|
        File.write(File.join(@root, "report.txt"), lines)
        Lain::Grader::TestHarness.new(
          root, adapter: Lain::Grader::TestHarness::Adapter::Command.new(
            out_argv: ->(out) { ["sh", "-c", "cp #{File.join(@root, "report.txt")} #{out}"] },
            passed: /^ok (.+)/, failed: /^fail (.+)/, errors: /^error (.+)/
          )
        )
      end
    end

    it "accepts failed plus errors as red" do
      expect(step(writing(target, red), harness: reporting("fail a\nerror b\n"))).to be_a(described_class::Red)
    end

    it "accepts an error beside a passing example as red" do
      expect(step(writing(target, red), harness: reporting("ok a\nerror NameError in b\n")))
        .to be_a(described_class::Red)
    end

    it "refuses a run where nothing ran but errors" do
      expect { step(writing(target, red), harness: reporting("error cannot load\n")) }
        .to raise_error(Lain::Error, /did not load.*cannot load/m)
    end
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
