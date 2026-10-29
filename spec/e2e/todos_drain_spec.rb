# frozen_string_literal: true

# One trivial chore drained by this checkout's real `exe/lain`: the runner claims it, cuts a lease, runs the
# headless chat there against the recorded model, and lands the chat's commit through `lain land`.
#
# A commit's output names its sha, so every commit is made at one fixed date, or the chat's next request
# could never match the cassette.
RSpec.describe "draining one chore through a lease, a headless chat and lain land", :e2e do
  # Spelled out step by step, and its one command allowed by the project's rules, so the small model the
  # cassette is recorded on makes 2 calls and no judge is asked: the cassette stays small enough to read.
  commit = "git add hello.txt && git commit -q -m add-hello"
  chore = "Call write_file with path set to exactly hello.txt and content set to hi, then run this bash command: " \
          "#{commit}"
  config = "approval do\n  allow \"bash\", command: #{commit.inspect}\nend\n"

  once(:journey) do
    E2E::Cassette.serve("todos_drain") do |upstream, _cassette|
      sandbox = E2E::Sandbox.create(files: { "TODOS.md" => "# Chores\n- [ ] #{chore}\n", ".lain/config.rb" => config })
      project = sandbox.project.to_s
      in_sandbox_state(sandbox) do
        trust_project(project)
        SeedRepo.git(project, "branch", "-M", "main")
        SeedRepo.git(project, "commit", "-q", "--amend", "--no-edit", "--reset-author", env: dates)
        drain(sandbox, upstream)
      end
    end
  end

  # The runner, its leases and Land read this process's state home, as the chat child reads the sandbox's;
  # in production they are one process's, so the journey makes them one too.
  def in_sandbox_state(sandbox)
    names = %w[XDG_STATE_HOME XDG_RUNTIME_DIR]
    held = ENV.to_h.slice(*names)
    names.each { |name| ENV[name] = sandbox.env.fetch(name) }
    yield
  ensure
    names.each { |name| ENV[name] = held[name] }
  end

  def drain(sandbox, upstream)
    project = sandbox.project.to_s
    status = SeedRepo.git(project, "status", "--porcelain", "--untracked-files=no").stdout
    outcome = runner(sandbox, upstream).first
    drainers.each(&:join)
    { outcome:, status:, after: SeedRepo.git(project, "status", "--porcelain", "--untracked-files=no").stdout,
      line: File.readlines(File.join(project, "TODOS.md"), chomp: true).fetch(1),
      landed: Lain::Shell::Out.new("git", "-C", project, "show", "main:hello.txt",
                                   environment: SeedRepo::SCRUB).run_command.stdout,
      chat_err: File.read(chat_err(sandbox)), session_kept: outcome.session && File.exist?(outcome.session) }
  end

  def dates = { "GIT_AUTHOR_DATE" => "2026-10-28T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-10-28T00:00:00Z" }

  def runner(sandbox, upstream)
    project = sandbox.project.to_s
    paths = Lain::Paths.new
    Lain::Chores::Runner.new(
      queue: Lain::Chores::Queue.at(project, paths:),
      backend: Lain::CLI::IsolationBackend.resolve("worktree", root: project, paths:),
      lain: E2E::PlainChat::EXE, land: ->(lease) { Lain::CLI::Land.new(cwd: lease, paths:, spawner: drainer(sandbox)) },
      notices: Lain::Notices::Null.new, paths:, max_cost: 1, chat_timeout: patience, wait_timeout: patience,
      spawner: spawner(sandbox, upstream)
    )
  end

  # The runner names no model, so the stand-in's flags ride after its own.
  def spawner(sandbox, upstream)
    # The fence this process would use, so the chat is confined in every checkout as the commit hook's is.
    lent = { "LAIN_ENV_PASS" => dates.keys.join(","), "CARGO_TARGET_DIR" => Lain::Paths::Shipped.cargo_target }
    env = sandbox.env.merge(dates, lent)
    lambda do |*argv, **options|
      flags = ["--provider", "ollama", "--model", "lfm2.5:latest", "--num-ctx", "32768", "--seed", "1",
               "--temperature", "0", "--no-nvim", "--api-base", upstream.url]
      Process.spawn(env, *argv, *flags, unsetenv_others: true, **options, err: chat_err(sandbox))
             .tap { sandbox.track(_1) }
    end
  end

  # The runner here lives in rspec, which the default spawner rightly declines to re-exec as lain.
  def drainer(sandbox)
    spawn = lambda do |argv, **options|
      drainers << Process.detach(Process.spawn(sandbox.env, *argv, unsetenv_others: true, **options)
                                        .tap { sandbox.track(_1) })
    end
    Lain::Isolation::MergeCoordinator::Spawner.new(spawn:, program: E2E::PlainChat::EXE)
  end

  # The drainer writes the landing's result, which ends the wait, and only then lets its lock go and exits;
  # the journey waits for that exit, so the leak check never races it.
  def drainers = @drainers ||= []

  def chat_err(sandbox) = sandbox.dir.join("chat.err").to_s

  def patience = E2E::Cassette.recording? ? 600 : 60

  it "lands the chat's commit on the main branch" do
    expect(journey.fetch(:outcome).status).to eq(:landed),
                                              "#{journey.fetch(:outcome).summary}\n#{journey.fetch(:chat_err)}"
    expect(journey.fetch(:landed).strip).to eq("hi")
  end

  it "marks the chore done with the landed sha and the session path" do
    outcome = journey.fetch(:outcome)

    expect(journey.fetch(:line)).to eq("- [x] #{chore}  <!-- landed #{outcome.sha} #{outcome.session} -->")
    expect(journey.fetch(:session_kept)).to be(true)
  end

  it "leaves the main checkout's tracked files as they were" do
    expect(journey.fetch(:after)).to eq(journey.fetch(:status))
  end
end
