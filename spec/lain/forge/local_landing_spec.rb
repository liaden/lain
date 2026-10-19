# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# One approved issue's commit, landed onto its epic's working branch in this
# repository and nowhere else. Drives real git in a throwaway repository: a
# `main` holding the project's one class, and `epic/demo` cut from it.
RSpec.describe Lain::Forge::LocalLanding, :seam do
  subject(:landing) { described_class.new(**wiring) }

  around do |example|
    Dir.mktmpdir("lain-local-landing") do |repo|
      @repo = File.realpath(repo)
      @state = File.realpath(Dir.mktmpdir("lain-local-landing-state"))
      SeedRepo.derived("local_landing_epic", into: @repo) do |template|
        SeedRepo.git(template, "branch", "-M", "main")
        FileUtils.mkdir_p(File.join(template, "app/models"))
        File.write(File.join(template, "app/models/order.rb"), "class Order\nend\n")
        SeedRepo.git(template, "add", "app/models/order.rb")
        SeedRepo.git(template, "commit", "-q", "-m", "work on app/models/order.rb")
        SeedRepo.git(template, "switch", "-q", "-c", "epic/demo")
      end
      example.run
    ensure
      FileUtils.rm_rf(@state)
    end
  end

  let(:journal) { [] }
  let(:decisions) { [] }
  let(:calls) { [] }
  let(:planned) { [] }
  let(:status) { "in_flight" }
  let(:base) do
    Lain::Isolation::WorkingBranch.new("epic/demo", repo_root: @repo, git: Lain::Isolation::Checkout.new(@repo))
  end
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }) }
  let(:isolation) { Lain::Config::Isolation.from({}, path: nil) }
  let(:queue) do
    Lain::Isolation::LandingQueue.candidate(root: @repo, base:, journal:, isolation:, paths:,
                                            shell_out_factory: recording)
  end
  let(:approvals) { described_class::Approvals.from(decisions.map(&:to_journal)) }
  let(:plan) { ->(issue_id) { planned << issue_id } }
  let(:progress) { -> { instance_double(Lain::Epic::Progress, status:) } }
  let(:scribe) { Lain::Epic::Scribe.new(epic_slug: "demo", journal:) }
  let(:landings) { -> { journal.map(&:to_journal) } }
  let(:layout) { Lain::TestLayout.from({ "preset" => "rspec", "source_roots" => ["app"] }, path: "config.toml") }
  let(:recording) do
    lambda do |*argv, **options|
      calls << argv
      Lain::Shell::Out.new(*argv, **options)
    end
  end

  # Scrubbed exactly as the subject scrubs, so a pre-commit hook's
  # GIT_INDEX_FILE never points these calls at lain's own index.
  def shell(*args)
    Lain::Shell::Out.new("git", "-C", @repo, *args,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command
  end

  def git(*) = SeedRepo.git(@repo, *).stdout.strip

  def commit(files)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
      File.write(File.join(@repo, path), body)
    end
    git("add", *files.keys)
    git("commit", "-q", "-m", "work on #{files.keys.join(", ")}")
    git("rev-parse", "HEAD")
  end

  def tip = git("rev-parse", "refs/heads/epic/demo")

  def contains?(sha) = shell("merge-base", "--is-ancestor", sha, "refs/heads/epic/demo").exitstatus.zero?

  # A worker's commit, cut from the epic tip and anchored where a handback
  # anchors it; the parent goes back to the epic branch.
  def worker(id, files)
    git("switch", "-q", "--detach", tip)
    sha = commit(files)
    ref = Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.#{id}.1").ref
    git("update-ref", ref, sha)
    git("switch", "-q", "epic/demo")
    [sha, ref]
  end

  def red_worker(id)
    git("switch", "-q", "--detach", tip)
    path = "spec/unit/models/order_spec.rb"
    FileUtils.mkdir_p(File.join(@repo, File.dirname(path)))
    File.write(File.join(@repo, path), "RSpec.describe Order do\nend\n")
    git("add", path)
    git("commit", "-q", "-m", Lain::Epic::RedCommit.subject(path, "c0ffee"))
    sha = git("rev-parse", "HEAD")
    git("update-ref", Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.#{id}.1").ref, sha)
    git("switch", "-q", "epic/demo")
    sha
  end

  def approve(issue_id, sha)
    digest = Lain::Epic::Submission.implementation(slug: "demo", issue_id:, digest: sha).digest
    decisions << Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug: "demo", stage: "implementation",
                                                  approved: true, answered_by: "human", policy: "hands_off",
                                                  latency: 0.0, issue_id:)
  end

  def transitions
    journal.grep(Lain::Epic::IssueTransition).map { |move| [move.issue_id, move.from_status, move.to_status] }
  end

  def pushed? = calls.any? { |argv| argv.include?("push") }

  describe "an approved issue lands locally and is done" do
    it "puts the commit on epic/demo, moves the issue in_flight -> done, and pushes nothing" do
      sha, ref = worker("a", "README" => "a's work\n")
      approve("a", sha)

      result = landing.call("a", sha:, ref:)

      expect(contains?(sha)).to be(true)
      expect(result.landed.first).to have_attributes(issue_id: "a", done: true)
      expect(result.landed.first.report.kind).to eq(:merged)
      expect(transitions).to eq([%w[a in_flight done]])
      expect(pushed?).to be(false)
    end

    it "journals the landing's handback report beside the transition" do
      sha, ref = worker("a", "README" => "a's work\n")
      approve("a", sha)

      landing.call("a", sha:, ref:)

      expect(journal.grep(Lain::Telemetry::Handback).map { |record| [record.outcome, record.sha, record.ref] })
        .to eq([[:merged, sha, ref]])
    end
  end

  describe "what blocks a landing, before anything merges" do
    it "re-checks the issue's plan approval, because a plan edited after its implementation parked is unapproved" do
      sha, ref = worker("a", "README" => "a's work\n")
      approve("a", sha)
      unapproved = ->(_issue_id) { raise Lain::CLI::EpicSubmit::PlanNotApproved, "issue \"a\" ... issue_plan" }

      expect { described_class.new(**wiring, plan: unapproved).call("a", sha:, ref:) }
        .to raise_error(Lain::CLI::EpicSubmit::PlanNotApproved, /issue_plan/)
      expect(contains?(sha)).to be(false)
      expect(journal).to be_empty
    end

    it "refuses a commit its implementation gate never approved, naming the gate and how to approve it" do
      sha, ref = worker("b", "README" => "b's work\n")

      expect { landing.call("b", sha:, ref:) }.to raise_error(Lain::Approval::Gate::NotApproved) { |error|
        expect(error.message).to include("implementation gate", sha,
                                         "lain epic submit implementation demo --issue b --digest #{sha}")
      }
      expect(contains?(sha)).to be(false)
    end

    # The address an implementation is approved under names the commit and
    # not the issue, so only the decision's own issue field tells them apart.
    it "does not take another issue's approval of the same commit as this issue's" do
      sha, ref = worker("b", "README" => "b's work\n")
      approve("c", sha)

      expect { landing.call("b", sha:, ref:) }.to raise_error(Lain::Approval::Gate::NotApproved, /issue b/)
      expect(contains?(sha)).to be(false)
    end

    # Read as "not approved", a damaged decision sent the human to approve a
    # commit their journal may already hold a decision on. It is a record the
    # fold cannot read, so it is refused as one, in one line.
    it "refuses a gate_decision whose approved is neither true nor false, naming the record" do
      approve("a", "a" * 40)
      line = decisions.first.to_journal.merge("approved" => "maybe")

      expect { described_class::Approvals.from([line]) }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Approval::SignoffQueue::UnreadableRecord)
        expect(error.message).to include("gate_decision", "demo/implementation/a", "approved", "nothing landed")
        expect(error.message).not_to include("\n")
      }
    end

    it "needs the ref the worker's commit is anchored under" do
      sha, = worker("a", "README" => "a's work\n")
      approve("a", sha)

      expect { landing.call("a", sha:) }.to raise_error(ArgumentError, /ref/)
    end

    context "when the issue is not in flight" do
      let(:status) { "pending" }

      it "refuses, naming its status" do
        sha, ref = worker("a", "README" => "a's work\n")
        approve("a", sha)

        expect { landing.call("a", sha:, ref:) }.to raise_error(described_class::NotInFlight, /a.*pending/)
        expect(planned).to be_empty
      end
    end

    it "asks the plan before the gate, and the gate before the layout" do
      sha, ref = worker("a", "README" => "a's work\n")
      approve("a", sha)

      landing.call("a", sha:, ref:)

      expect(planned).to eq(["a"])
    end
  end

  describe "the layout, checked over the tests in the diff at the worker's commit" do
    it "refuses a misplaced test, listing the file and its right path, and leaves the branch alone" do
      sha, ref = worker("c", "spec/order_extra_spec.rb" => "RSpec.describe Order do\nend\n")
      approve("c", sha)
      before = tip

      expect { landing.call("c", sha:, ref:) }.to raise_error(described_class::MisplacedTests) { |error|
        expect(error.message).to include("spec/order_extra_spec.rb", "spec/unit/models/order_spec.rb")
      }
      expect(tip).to eq(before)
    end

    # At write time a test may come before its class. By landing time the
    # class has to exist, in the commit that lands.
    it "refuses a test whose subject no source in the commit defines" do
      sha, ref = worker("c", "spec/unit/models/refund_spec.rb" => "RSpec.describe Refund do\nend\n")
      approve("c", sha)

      expect { landing.call("c", sha:, ref:) }
        .to raise_error(described_class::MisplacedTests, %r{spec/unit/models/refund_spec\.rb.*Refund}m)
    end

    it "reads the sources from the worker's commit, so a class and its test landing together pass" do
      sha, ref = worker("c", "app/models/refund.rb" => "class Refund\nend\n",
                             "spec/unit/models/refund_spec.rb" => "RSpec.describe Refund do\nend\n")
      approve("c", sha)

      expect(landing.call("c", sha:, ref:).landed.first.report.kind).to eq(:merged)
    end

    context "when the project declares no [tests] layout" do
      let(:layout) { Lain::TestLayout::None }

      it "checks nothing" do
        sha, ref = worker("c", "spec/order_extra_spec.rb" => "RSpec.describe Order do\nend\n")
        approve("c", sha)

        expect(landing.call("c", sha:, ref:).landed.first.report.kind).to eq(:merged)
      end
    end
  end

  describe "a crash mid-landing resumes" do
    it "moves the issue to done without merging again" do
      sha, ref = worker("a", "README" => "a's work\n")
      approve("a", sha)
      crashing = instance_double(Lain::Epic::Scribe)
      allow(crashing).to receive(:issue_moved).and_raise(RuntimeError, "killed between the merge and the transition")
      expect { described_class.new(**wiring, scribe: crashing, landings:).call("a", sha:, ref:) }
        .to raise_error(RuntimeError, /killed/)
      calls.clear

      result = described_class.new(**wiring, landings:).resume("a")

      expect(result.landed.first).to have_attributes(issue_id: "a", done: true)
      expect(transitions).to eq([%w[a in_flight done]])
      expect(calls.flatten).not_to include("merge")
      expect(tip).to eq(sha)
    end

    it "refuses to resume a commit the branch holds when no landing of this issue is journaled" do
      sha, = worker("a", "README" => "a's work\n")
      approve("a", sha)
      git("merge", "-q", "--ff-only", sha)

      expect { described_class.new(**wiring, landings:).resume("a") }
        .to raise_error(Lain::Error, /no landing of issue a/)
      expect(transitions).to be_empty
    end

    it "refuses to resume a landing that never merged" do
      sha, = worker("a", "README" => "a's work\n")
      approve("a", sha)

      expect { landing.resume("a") }.to raise_error(Lain::Error, /does not hold issue a's approved commit/)
      expect(transitions).to be_empty
    end
  end

  # Already on the branch is not landed: an approval over a commit the branch
  # held all along lands no work for the issue.
  describe "a commit the branch already holds" do
    it "is refused when no landing of this issue is journaled, and the issue stays in flight" do
      sha, ref = worker("a", "README" => "a's work\n")
      approve("a", sha)
      git("merge", "-q", "--ff-only", sha)

      expect { described_class.new(**wiring, landings:).call("a", sha:, ref:) }
        .to raise_error(described_class::AlreadyOnBranch) { |error|
          expect(error.message).to include(sha, "epic/demo", "nothing lands for issue a")
        }
      expect(transitions).to be_empty
    end
  end

  # A project need not be a repository's whole tree: the diff names paths from
  # the repository's root, and the layout names them from the project's.
  describe "a project nested inside a larger repository" do
    let(:project) { File.join(@repo, "proj") }
    let(:base) do
      Lain::Isolation::WorkingBranch.new("epic/demo", repo_root: project, git: Lain::Isolation::Checkout.new(project))
    end
    let(:queue) do
      Lain::Isolation::LandingQueue.candidate(root: project, base:, journal:, isolation:, paths:,
                                              shell_out_factory: recording)
    end

    before { commit("proj/app/models/order.rb" => "class Order\nend\n") }

    def nested = described_class.new(**wiring, repo_root: project)

    it "judges the project's tests by project-relative path" do
      sha, ref = worker("c", "proj/spec/order_extra_spec.rb" => "RSpec.describe Order do\nend\n")
      approve("c", sha)

      expect { nested.call("c", sha:, ref:) }.to raise_error(described_class::MisplacedTests) { |error|
        expect(error.message).to include("spec/order_extra_spec.rb", "spec/unit/models/order_spec.rb")
        expect(error.message).not_to include("proj/spec")
      }
    end

    it "lands a correctly placed test, ignoring a test outside the project" do
      sha, ref = worker("c", "proj/spec/unit/models/order_spec.rb" => "RSpec.describe Order do\nend\n",
                             "elsewhere/spec/stray_spec.rb" => "RSpec.describe Order do\nend\n")
      approve("c", sha)

      expect(nested.call("c", sha:, ref:).landed.first.report.kind).to eq(:merged)
    end
  end

  describe "the commit, found from the handback's anchor" do
    it "lands the anchored commit the implementation gate approved, and no other" do
      unapproved, = worker("stray", "notes" => "not approved\n")
      sha, = worker("a", "README" => "a's work\n")
      approve("a", sha)

      result = landing.land(landing.anchored("a"))

      expect(result.landed.first.report.sha).to eq(sha)
      expect(contains?(unapproved)).to be(false)
    end

    it "refuses an anchored commit no gate approved, naming lain epic submit implementation with its sha" do
      sha, = worker("a", "README" => "a's work\n")

      expect { landing.anchored("a") }.to raise_error(Lain::Approval::Gate::NotApproved) { |error|
        expect(error.message).to include("implementation gate", sha,
                                         "lain epic submit implementation demo --issue a --digest #{sha}")
      }
    end

    it "refuses an approved commit nobody anchored, naming the driver and not epic submit" do
      git("switch", "-q", "--detach", tip)
      sha = commit("README" => "hand made\n")
      git("switch", "-q", "epic/demo")
      approve("a", sha)

      expect { landing.anchored("a") }.to raise_error(Lain::Approval::Gate::NotApproved) { |error|
        expect(error.message).to include("no worker commit is anchored for issue a", "driver")
        expect(error.message).not_to include("epic submit")
      }
    end

    it "does not take the anchor of an issue whose id continues this one's after a dot" do
      worker("a.1", "README" => "a.1's work\n")

      expect { landing.anchored("a") }.to raise_error(Lain::Approval::Gate::NotApproved, /no worker commit is anchored/)
    end

    it "finds an anchor for an id Naming rewrites, one with a double dot" do
      sha, = worker("a..b", "README" => "a..b's work\n")

      expect { landing.anchored("a..b") }.to raise_error(Lain::Approval::Gate::NotApproved) { |error|
        expect(error.message).to include(sha)
      }
    end

    it "does not take another issue's anchor for this issue's" do
      worker("ab", "README" => "ab's work\n")

      expect { landing.anchored("a") }.to raise_error(Lain::Approval::Gate::NotApproved, /no worker commit is anchored/)
    end

    it "refuses when only the failing-test commit is anchored, naming no sha to approve" do
      sha = red_worker("greet")

      expect { landing.anchored("greet") }.to raise_error(Lain::Approval::Gate::NotApproved) { |error|
        expect(error.message).to include("only the failing-test commit is anchored for issue greet; re-run the issue")
        expect(error.message).not_to include(sha, "epic submit")
      }
    end

    it "refuses a failing-test commit an implementation gate approved, and moves nothing to done" do
      sha = red_worker("greet")
      approve("greet", sha)

      expect { landing.anchored("greet") }.to raise_error(Lain::Approval::Gate::NotApproved) { |error|
        expect(error.message).to include("only the failing-test commit is anchored for issue greet")
        expect(error.message).not_to include(sha)
      }
      expect { landing.call("greet", sha:, ref: "refs/lain/worker/x") }
        .to raise_error(Lain::Approval::Gate::NotApproved,
                        /#{sha} holds only issue greet's failing tests; re-run the issue/)
      expect(contains?(sha)).to be(false)
      expect(transitions).to be_empty
    end

    it "refuses a named failing-test commit no gate approved, offering no approval of it" do
      sha = red_worker("greet")

      expect { landing.call("greet", sha:, ref: "refs/lain/worker/x") }
        .to raise_error(Lain::Approval::Gate::NotApproved) { |error|
          expect(error.message).to include("#{sha} holds only issue greet's failing tests; re-run the issue")
          expect(error.message).not_to include("epic submit")
        }
      expect(contains?(sha)).to be(false)
    end

    it "refuses two different approved commits for one issue, naming both" do
      first, = worker("a1", "README" => "one\n")
      second, = worker("a2", "README" => "two\n")
      approve("a", first)
      approve("a", second)

      expect { landing.anchored("a") }.to raise_error(described_class::Ambiguous) { |error|
        expect(error.message).to include(first, second)
      }
    end
  end

  describe "nothing reaches the working branch before its gate" do
    it "does not land a re-synced commit the implementation gate never approved" do
      first, first_ref = worker("a", "README" => "a's work\n")
      stale, stale_ref = worker("b", "README" => "b's work\n")
      approve("a", first)
      approve("b", stale)
      rebased = nil
      resync = lambda do |_worker, tip:|
        git("switch", "-q", "--detach", tip)
        rebased = commit("README" => "a's and b's work\n")
        git("switch", "-q", "epic/demo")
        rebased
      end

      result = landing.land([landing.admit("a", sha: first, ref: first_ref),
                             landing.admit("b", sha: stale, ref: stale_ref)], resync:)

      expect(result.landed.map { |entry| entry.report.kind }).to eq(%i[merged conflicted])
      expect(contains?(rebased)).to be(false)
      expect(transitions).to eq([%w[a in_flight done]])
    end
  end

  def wiring
    { epic_slug: "demo", repo_root: @repo, base:, approvals:, plan:, progress:, scribe:, queue:, layout:,
      shell_out_factory: recording }
  end
end
