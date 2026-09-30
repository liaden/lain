# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# `exe/lain` is a script, not a lib file; it guards its own `LainCLI.start`, so
# loading it here defines the Thor commands without running one.
load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Epic)

# `lain epic land ISSUE_ID [SLUG]` is the command boundary over
# {Lain::Forge::LocalLanding}: it finds the worker's anchored commit the
# implementation gate approved, lands it onto `epic/<slug>` in this checkout,
# and moves the issue to done. It pushes nothing; the epic reaches the remote
# once, through `lain epic finish`.
#
# Drives real git in a throwaway project that is its own repository, with the
# epic home and the session journals under a throwaway XDG state home.
RSpec.describe Lain::CLI::EpicLand, :seam do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", root)
      FileUtils.mkdir_p(sessions_dir)
      git("branch", "-M", "main")
      commit("app/models/order.rb" => "class Order\nend\n")
      git("switch", "-q", "-c", "epic/demo")
      write_layout
      write_epic
      example.run
    end
  end

  def root = @root ||= File.join(File.realpath(@tmp), "project")
  def state_home = File.join(@tmp, "state")
  def paths = @paths ||= Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  def config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates: {}))
  def sessions_dir = paths.sessions_dir

  def home(slug = "demo") = Lain::Epic::Home.resolve(config:, paths:, root:, slug:)

  def issue(id) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", status: "in_flight")
  def graph = Lain::Epic::Graph.new(issues: %w[a b c].map { |id| issue(id) })

  def write_epic
    home.write_epic(graph)
    %w[a b c].each { |id| home.plan(id).write("the plan for #{id}\n") }
  end

  # Untracked, so the parent checkout stays clean for the merge.
  def write_layout
    write_config(root, "tests preset: :rspec, source_roots: %w[app]\n")
  end

  def shell(*args)
    Mixlib::ShellOut.new("git", "-C", root, *args,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command
  end

  def git(*) = shell(*).tap(&:error!).stdout.strip

  def commit(files)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), body)
    end
    git("add", *files.keys)
    git("commit", "-q", "-m", "work on #{files.keys.join(", ")}")
    git("rev-parse", "HEAD")
  end

  def tip = git("rev-parse", "refs/heads/epic/demo")

  def contains?(sha) = shell("merge-base", "--is-ancestor", sha, "refs/heads/epic/demo").exitstatus.zero?

  # A worker's commit, anchored where a handback anchors it.
  def worker(id, files)
    git("switch", "-q", "--detach", tip)
    sha = commit(files)
    git("update-ref", Lain::Isolation::Worktree::Handback::Naming.new(id).ref, sha)
    git("switch", "-q", "epic/demo")
    sha
  end

  # --- the gate's records ----------------------------------------------------

  def session(*records, name: "fixture.ndjson", at: "2026-01-01T00:00:00Z")
    File.open(File.join(sessions_dir, name), "a") do |io|
      journal = Lain::Journal.new(io:, clock: -> { at })
      records.each { |record| journal.record(record) }
    end
  end

  def decision(stage, issue_id, digest)
    Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug: "demo", stage:, approved: true,
                                     answered_by: "human", policy: "hands_off", latency: 0.0, issue_id:)
  end

  def plan_approval(issue_id)
    plan = Lain::Epic::Submission.issue_plan(text: "the plan for #{issue_id}\n", slug: "demo", issue_id:,
                                             criteria_digest: nil)
    decision("issue_plan", issue_id, plan.digest)
  end

  # The handback record a landing of the issue journals as it merges.
  def landed_record(issue_id, sha)
    Lain::Telemetry::Handback.new(worker_key: "demo/#{issue_id}", outcome: :merged, sha:, fast_forward: true,
                                  ref: Lain::Isolation::Worktree::Handback::Naming.new(issue_id).ref)
  end

  def implementation_approval(issue_id, sha)
    decision("implementation", issue_id,
             Lain::Epic::Submission.implementation(slug: "demo", issue_id:, digest: sha).digest)
  end

  let(:calls) { [] }
  let(:recording) do
    lambda do |*argv, **options|
      calls << argv
      Lain::Shell::Out.new(*argv, **options)
    end
  end

  def command = described_class.new(root:, paths:, config:, shell_out_factory: recording)

  def journal_records
    Dir.children(sessions_dir).sort
       .flat_map { |name| Lain::Journal.records(File.foreach(File.join(sessions_dir, name))).to_a }
  end

  def progress = Lain::Epic::Progress.fold(journal_records, graph: home.read_epic, epic_slug: "demo")

  describe "an approved issue lands locally and is done" do
    it "puts the approved commit on epic/demo, moves the issue to done, and pushes nothing" do
      sha = worker("a", "README" => "a's work\n")
      session(plan_approval("a"), implementation_approval("a", sha))

      output = command.land("a", "demo")

      expect(contains?(sha)).to be(true)
      expect(progress.status("a")).to eq(Lain::Epic::DONE)
      expect(output).to include("landed a at #{sha} onto epic/demo", "a moved in_flight -> done", "nothing was pushed")
      expect(calls.flatten).not_to include("push")
    end
  end

  describe "an unapproved issue, or a misplaced test in the diff, blocks the landing" do
    it "refuses b naming the gate, refuses c listing the file and its right path, and leaves epic/demo alone" do
      worker("b", "README" => "b's work\n")
      c_sha = worker("c", "spec/order_extra_spec.rb" => "RSpec.describe Order do\nend\n")
      session(plan_approval("b"), plan_approval("c"), implementation_approval("c", c_sha))
      before = tip

      expect { command.land("b", "demo") }.to raise_error(Lain::Approval::Gate::NotApproved, /implementation gate/)
      expect { command.land("c", "demo") }.to raise_error(Lain::Forge::LocalLanding::MisplacedTests) { |error|
        expect(error.message).to include("spec/order_extra_spec.rb", "spec/unit/models/order_spec.rb")
      }
      expect(tip).to eq(before)
      expect(%w[b c].map { |id| progress.status(id) }).to all(eq("in_flight"))
    end

    it "refuses an issue whose plan is not approved as it stands now" do
      sha = worker("a", "README" => "a's work\n")
      session(implementation_approval("a", sha))

      expect { command.land("a", "demo") }.to raise_error(Lain::CLI::EpicSubmit::PlanNotApproved, /issue_plan/)
      expect(contains?(sha)).to be(false)
    end
  end

  # Scenario: landing and finishing refuse over a torn sign-off too. A skipped
  # line is a decision nobody made, and this fold was never named in the list
  # of sign-off readers -- it is safe because refusing is the default.
  describe "a torn implementation sign-off" do
    it "refuses, naming the file and the line, and leaves epic/demo alone" do
      sha = worker("a", "README" => "a's work\n")
      session(plan_approval("a"), implementation_approval("a", sha))
      path = File.join(sessions_dir, "fixture.ndjson")
      lines = File.readlines(path)
      File.write(path, lines[0] + lines[1][0, lines[1].size / 2])
      before = tip

      expect { command.land("a", "demo") }
        .to raise_error(Lain::CLI::SessionJournals::Unreadable, /fixture\.ndjson.*line 2/)
      expect(tip).to eq(before)
      expect(contains?(sha)).to be(false)
    end
  end

  describe "a crash mid-landing resumes" do
    it "moves the issue to done and does not merge again" do
      sha = worker("a", "README" => "a's work\n")
      git("merge", "-q", "--ff-only", sha)
      session(plan_approval("a"), implementation_approval("a", sha), landed_record("a", sha))
      calls.clear

      output = command.resume("a", "demo")

      expect(progress.status("a")).to eq(Lain::Epic::DONE)
      expect(tip).to eq(sha)
      expect(calls.flatten).not_to include("merge")
      expect(output).to include("resumed a at #{sha}", "a moved in_flight -> done")
    end

    it "refuses a resume when nothing was ever merged, naming the issue" do
      sha = worker("a", "README" => "a's work\n")
      session(plan_approval("a"), implementation_approval("a", sha))

      expect { command.resume("a", "demo") }.to raise_error(Lain::Error, /does not hold issue a's approved commit/)
    end
  end

  describe "a commit epic/demo already holds" do
    it "is refused when no landing of the issue put it there, and the issue stays in flight" do
      sha = worker("a", "README" => "a's work\n")
      git("merge", "-q", "--ff-only", sha)
      session(plan_approval("a"), implementation_approval("a", sha))

      expect { command.land("a", "demo") }.to raise_error(Lain::Forge::LocalLanding::AlreadyOnBranch, %r{epic/demo})
      expect(progress.status("a")).to eq("in_flight")
    end
  end

  describe "which epic, and what to type" do
    it "refuses a bare issue id, naming the command's arguments" do
      expect { command.land(" ", "demo") }
        .to raise_error(Lain::Error, /lain epic land ISSUE_ID \[SLUG\]/)
    end

    it "refuses an unnamed choice between epics, advising the land spelling" do
      home("other").write_epic(graph)

      expect { command.land("a") }.to raise_error(Lain::CLI::Epic::Ambiguous, /name one: lain epic land ISSUE_ID SLUG/)
    end

    it "advises the resume spelling when a resume is what refused" do
      home("other").write_epic(graph)

      expect { command.resume("a") }
        .to raise_error(Lain::CLI::Epic::Ambiguous, /name one: lain epic land --resume ISSUE_ID SLUG/)
    end

    # Through the Thor command object rather than `LainCLI::Epic.start`, which
    # calls `Kernel#exit` on a Thor::Error and would kill the rspec process.
    it "hands --resume the same slug positional as a landing" do
      allow(described_class).to receive(:new).and_return(instance_double(described_class, resume: "resumed"))

      LainCLI::Epic.new([], { resume: true }).land("a", "demo")

      expect(described_class.new).to have_received(:resume).with("a", "demo")
    end
  end
end
