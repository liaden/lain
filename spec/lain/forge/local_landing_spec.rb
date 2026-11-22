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
  let(:signoff) { Lain::Epic::Signoff.from_journal(decisions.map(&:to_journal)) }
  let(:plan) { ->(issue_id) { planned << issue_id } }
  let(:scope) { ->(_issue_id) {} }
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
  # anchors it.
  def worker(id, files)
    ref = Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.#{id}.1").ref
    sha = CommitBuilder.call(@repo, parent: tip, files:, message: "work on #{files.keys.join(", ")}", ref:)
    [sha, ref]
  end

  def red_worker(id, attempt: 1)
    git("switch", "-q", "--detach", tip)
    path = "spec/unit/models/order_spec.rb"
    FileUtils.mkdir_p(File.join(@repo, File.dirname(path)))
    File.write(File.join(@repo, path), "RSpec.describe Order do\nend\n")
    git("add", path)
    git("commit", "-q", "-m", Lain::Epic::RedCommit.subject(path, "c0ffee"))
    sha = git("rev-parse", "HEAD")
    git("update-ref", Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.#{id}.#{attempt}").ref, sha)
    git("switch", "-q", "epic/demo")
    sha
  end

  def approve(issue_id, sha, verdict: Lain::Approval::Verdict::Approve.new, policy: "hands_off",
              answered_by: "human")
    digest = Lain::Epic::Submission.implementation(slug: "demo", issue_id:, digest: sha).digest
    decisions << Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: "demo", stage: "implementation",
                                              verdict:, answered_by:, policy:,
                                              latency: 0.0, issue_id:)
  end

  def hold(issue_id, sha) = approve(issue_id, sha, verdict: Lain::Approval::Verdict::Hold.new, policy: "interactive")

  def deny(issue_id, sha) = approve(issue_id, sha, verdict: Lain::Approval::Verdict::Deny.new, policy: "signoff")

  def park(issue_id, sha) = approve(issue_id, sha, verdict: Lain::Epic::GateDecision::Deferred.new, policy: "deferred")

  def second_attempt(id)
    git("switch", "-q", "--detach", tip)
    sha = commit("README" => "attempt 2\n")
    git("switch", "-q", "epic/demo")
    anchor(id, 2, sha)
    sha
  end

  # What landing makes of issue a's anchored commits: the sha it admits, or which refusal it gives.
  def landed_or_refused(issue_id = "a")
    landing.anchored(issue_id).worker.sha
  rescue Lain::Epic::Gate::NotApproved => e
    { "waits for sign-off" => :parked, "the human asked it to wait" => :held,
      "no worker commit is anchored" => :unanchored }.find { |words, _| e.message.include?(words) }&.last || e.message
  end

  def anchor(id, attempt, sha)
    git("update-ref", Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.#{id}.#{attempt}").ref, sha)
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

      expect { landing.call("b", sha:, ref:) }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
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

      expect { landing.call("b", sha:, ref:) }.to raise_error(Lain::Epic::Gate::NotApproved, /issue b/)
      expect(contains?(sha)).to be(false)
    end

    it "does not count a digest approved and then denied as approved" do
      sha, = worker("a", "README" => "a's work\n")
      approve("a", sha)
      deny("a", sha)

      expect(landed_or_refused).to eq(:unanchored)
    end

    # The partition's standing is one digest, so approving a newer commit of an
    # issue withdraws the older one's approval rather than leaving 2 to land.
    it "withdraws an older commit's approval once a newer commit of the issue is approved" do
      older, = worker("a", "README" => "a's work\n")
      newer = second_attempt("a")
      approve("a", older)
      approve("a", newer)

      expect(landed_or_refused).to eq(newer)
    end

    # A deferral after the approval parks the digest again for sign-off, so it is
    # not landed while it waits, however the partition stood before.
    it "does not count a digest approved and then parked again as approved" do
      sha, = worker("a", "README" => "a's work\n")
      approve("a", sha)
      park("a", sha)

      expect(landed_or_refused).to eq(:parked)
    end

    it "reads a digest denied and then parked again as parked, not denied" do
      sha, = worker("a", "README" => "a's work\n")
      deny("a", sha)
      park("a", sha)

      expect(landed_or_refused).to eq(:parked)
    end

    it "counts a digest denied and then approved as approved" do
      sha, = worker("a", "README" => "a's work\n")
      deny("a", sha)
      approve("a", sha)

      expect(landed_or_refused).to eq(sha)
    end

    # Read as "not approved", a damaged decision sent the human to approve a
    # commit their journal may already hold a decision on. It is a record the
    # fold cannot read, so it is refused as one, in one line.
    it "refuses a gate_decision whose verdict is no verdict word, naming the record" do
      approve("a", "a" * 40)
      line = decisions.first.to_journal.merge("verdict" => "maybe")

      expect { Lain::Epic::Signoff.from_journal([line]) }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Epic::SignoffQueue::UnreadableRecord)
        expect(error.message).to include("gate_decision", "demo/implementation/a", "verdict", "nothing was decided")
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

    it "raises, naming the command, when git cannot list the anchors, rather than finding none" do
      sha, = worker("a", "README" => "a's work\n")
      approve("a", sha)
      broken = lambda do |*argv, **options|
        listing = argv.include?("for-each-ref")
        Lain::Shell::Out.new(*(listing ? ["sh", "-c", "echo bad ref >&2; exit 128"] : argv), **options)
      end

      expect { described_class.new(**wiring, shell_out_factory: broken).anchored("a") }
        .to raise_error(Lain::Isolation::Checkout::Failed, /git for-each-ref failed.*bad ref/m)
    end

    it "lists one sha's subjects once when it is checked and then admitted" do
      sha, ref = worker("a", "README" => "a's work\n")
      approve("a", sha)

      landing.anchored("a")
      landing.admit("a", sha:, ref:)

      expect(calls.count { |argv| argv.include?("--format=%s") }).to eq(1)
    end

    # A hold is no verdict: the human asked the agent to wait, so it neither
    # refuses the commit nor withdraws an approval it already carries.
    context "when the human answered the implementation gate hold" do
      it "offers the held commit for approval through lain epic submit, not a re-run" do
        sha, = worker("a", "README" => "a's work\n")
        hold("a", sha)

        expect { landing.anchored("a") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
          expect(error.message).to include(sha, "lain epic submit implementation demo --issue a --digest #{sha}")
          expect(error.message).not_to include("re-run the issue", "no worker commit is anchored")
        }
      end

      it "reads the commit held, neither approved nor denied" do
        sha, = worker("a", "README" => "a's work\n")
        hold("a", sha)

        expect(landed_or_refused).to eq(:held)
      end

      it "reads a hold after an approval as approved, not held, as the sign-off queue does" do
        sha, = worker("a", "README" => "a's work\n")
        approve("a", sha)
        hold("a", sha)

        expect(landed_or_refused).to eq(sha)
      end

      it "reads a hold over an approval as not held once a later commit is approved, which alone stands" do
        older, = worker("a", "README" => "a's work\n")
        newer = second_attempt("a")
        approve("a", older)
        hold("a", older)
        approve("a", newer)

        expect(landed_or_refused).to eq(newer)
      end

      it "reads a hold after a park as parked, not held, as the sign-off queue does" do
        sha, = worker("a", "README" => "a's work\n")
        park("a", sha)
        hold("a", sha)

        expect(landed_or_refused).to eq(:parked)
      end

      it "reads a hold after a denial as held, not denied" do
        sha, = worker("a", "README" => "a's work\n")
        deny("a", sha)
        hold("a", sha)

        expect(landed_or_refused).to eq(:held)
      end

      it "refuses a decision written before verdicts were recorded as one missing its verdict" do
        approve("a", "a" * 40)
        old = decisions.first.to_journal.except("verdict").merge("approved" => true)

        expect { Lain::Epic::Signoff.from_journal([old]) }
          .to raise_error(Lain::Epic::SignoffQueue::UnreadableRecord, /verdict must be one of/) { |error|
            expect(error.message).not_to include("rewrite")
          }
      end

      it "still lands a commit approved before the hold on the same digest" do
        sha, ref = worker("a", "README" => "a's work\n")
        approve("a", sha)
        hold("a", sha)

        landing.call("a", sha:, ref:)

        expect(contains?(sha)).to be(true)
      end
    end

    context "when the implementation gate parked the commit for sign-off" do
      it "says the commit waits and names lain epic queue, not an unanchored worker" do
        sha, = worker("a", "README" => "a's work\n")
        park("a", sha)

        expect { landing.anchored("a") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
          expect(error.message).to include("waits for sign-off", sha, "lain epic queue")
          expect(error.message).not_to include("no worker commit is anchored", "re-run the issue")
        }
      end

      it "says the same when the commit is named directly" do
        sha, ref = worker("a", "README" => "a's work\n")
        park("a", sha)

        expect { landing.admit("a", sha:, ref:) }.to raise_error(Lain::Epic::Gate::NotApproved, /waits for sign-off/)
      end

      it "lands once a later sign-off approves it" do
        sha, ref = worker("a", "README" => "a's work\n")
        park("a", sha)
        approve("a", sha, policy: "signoff")

        landing.call("a", sha:, ref:)

        expect(contains?(sha)).to be(true)
      end

      it "refuses an approved attempt while a newer attempt is parked, naming the parked one" do
        first, = worker("farewell", "README" => "attempt 1\n")
        approve("farewell", first)
        git("switch", "-q", "--detach", tip)
        second = commit("README" => "attempt 2\n")
        git("switch", "-q", "epic/demo")
        anchor("farewell", 2, second)
        park("farewell", second)
        before = tip

        expect { landing.land(landing.anchored("farewell")) }
          .to raise_error(Lain::Epic::Gate::NotApproved) { |error|
            expect(error.message).to include("waits for sign-off", second)
            expect(error.message).not_to include(first)
          }
        expect(tip).to eq(before)
      end

      it "lands the newer attempt approved after it was parked, though an older attempt is still parked" do
        first, = worker("farewell", "README" => "attempt 1\n")
        park("farewell", first)
        second = second_attempt("farewell")
        park("farewell", second)
        approve("farewell", second, policy: "signoff")

        landing.land(landing.anchored("farewell"))

        expect([contains?(second), contains?(first)]).to eq([true, false])
      end

      it "refuses an approved attempt while a newer attempt is held, naming the hold and how to answer it" do
        first, = worker("farewell", "README" => "attempt 1\n")
        approve("farewell", first)
        second = second_attempt("farewell")
        hold("farewell", second)
        before = tip

        expect { landing.land(landing.anchored("farewell")) }
          .to raise_error(Lain::Epic::Gate::NotApproved) { |error|
            expect(error.message).to include("held #{second}", "asked it to wait",
                                             "lain epic submit implementation demo --issue farewell --digest #{second}")
            expect(error.message).not_to include(first)
          }
        expect(tip).to eq(before)
      end

      it "still reports a human denial as a denial" do
        sha, = worker("a", "README" => "a's work\n")
        deny("a", sha)

        expect { landing.anchored("a") }.to raise_error(Lain::Epic::Gate::NotApproved, /no worker commit is anchored/)
      end
    end

    it "refuses an anchored commit no gate approved, naming lain epic submit implementation with its sha" do
      sha, = worker("a", "README" => "a's work\n")

      expect { landing.anchored("a") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
        expect(error.message).to include("implementation gate", sha,
                                         "lain epic submit implementation demo --issue a --digest #{sha}")
      }
    end

    it "refuses an approved commit nobody anchored, naming the driver and not epic submit" do
      git("switch", "-q", "--detach", tip)
      sha = commit("README" => "hand made\n")
      git("switch", "-q", "epic/demo")
      approve("a", sha)

      expect { landing.anchored("a") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
        expect(error.message).to include("no worker commit is anchored for issue a", "driver")
        expect(error.message).not_to include("epic submit")
      }
    end

    it "does not take the anchor of an issue whose id continues this one's after a dot" do
      worker("a.1", "README" => "a.1's work\n")

      expect { landing.anchored("a") }.to raise_error(Lain::Epic::Gate::NotApproved, /no worker commit is anchored/)
    end

    it "finds an anchor for an id Naming rewrites, one with a double dot" do
      sha, = worker("a..b", "README" => "a..b's work\n")

      expect { landing.anchored("a..b") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
        expect(error.message).to include(sha)
      }
    end

    it "does not take another issue's anchor for this issue's" do
      worker("ab", "README" => "ab's work\n")

      expect { landing.anchored("a") }.to raise_error(Lain::Epic::Gate::NotApproved, /no worker commit is anchored/)
    end

    it "refuses when only the failing-test commit is anchored, naming no sha to approve" do
      sha = red_worker("greet")

      expect { landing.anchored("greet") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
        expect(error.message).to include("only the failing-test commit is anchored for issue greet; re-run the issue")
        expect(error.message).not_to include(sha, "epic submit")
      }
    end

    context "when an issue was re-run and its first attempt's commit was denied" do
      it "names no sha when the later attempt anchored only its failing-test commit" do
        old, = worker("greet", "README" => "attempt 1\n")
        deny("greet", old)
        red_worker("greet", attempt: 2)

        expect { landing.anchored("greet") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
          expect(error.message).to include("only the failing-test commit is anchored for issue greet; re-run the issue")
          expect(error.message).not_to include(old, "epic submit")
        }
      end

      it "offers the newest attempt's commit and not an older one" do
        old, = worker("greet", "README" => "attempt 1\n")
        git("switch", "-q", "--detach", tip)
        newest = commit("README" => "attempt 2\n")
        git("switch", "-q", "epic/demo")
        anchor("greet", 2, newest)

        expect { landing.anchored("greet") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
          expect(error.message).to include(newest)
          expect(error.message).not_to include(old)
        }
      end

      context "with an issue id long enough that Naming cuts the attempt number off" do
        let(:long_id) { "x" * 70 }

        it "still offers every anchor, whichever attempt it was" do
          first, = worker(long_id, "README" => "attempt 1\n")
          git("switch", "-q", "--detach", tip)
          second = commit("README" => "attempt 2\n")
          git("switch", "-q", "epic/demo")
          anchor(long_id, 2, second)

          expect { landing.anchored(long_id) }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
            expect(error.message).to include(first, second)
          }
        end

        it "still withholds a denied one among them" do
          first, = worker(long_id, "README" => "attempt 1\n")
          deny(long_id, first)
          git("switch", "-q", "--detach", tip)
          second = commit("README" => "attempt 2\n")
          git("switch", "-q", "epic/demo")
          anchor(long_id, 2, second)

          expect { landing.anchored(long_id) }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
            expect(error.message).to include(second)
            expect(error.message).not_to include(first)
          }
        end
      end

      it "offers no denied commit even when it is the newest anchored" do
        old, = worker("greet", "README" => "attempt 1\n")
        deny("greet", old)

        expect { landing.anchored("greet") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
          expect(error.message).not_to include(old)
        }
      end
    end

    it "refuses a failing-test commit an implementation gate approved, and moves nothing to done" do
      sha = red_worker("greet")
      approve("greet", sha)

      expect { landing.anchored("greet") }.to raise_error(Lain::Epic::Gate::NotApproved) { |error|
        expect(error.message).to include("only the failing-test commit is anchored for issue greet")
        expect(error.message).not_to include(sha)
      }
      expect { landing.call("greet", sha:, ref: "refs/lain/worker/x") }
        .to raise_error(Lain::Epic::Gate::NotApproved,
                        /#{sha} holds only issue greet's failing tests; re-run the issue/)
      expect(contains?(sha)).to be(false)
      expect(transitions).to be_empty
    end

    it "refuses a named failing-test commit no gate approved, offering no approval of it" do
      sha = red_worker("greet")

      expect { landing.call("greet", sha:, ref: "refs/lain/worker/x") }
        .to raise_error(Lain::Epic::Gate::NotApproved) { |error|
          expect(error.message).to include("#{sha} holds only issue greet's failing tests; re-run the issue")
          expect(error.message).not_to include("epic submit")
        }
      expect(contains?(sha)).to be(false)
    end

    # The issue's standing is one commit, so two approvals leave only the newer to land.
    it "admits the newer of two approved commits for one issue, the older one's approval withdrawn" do
      first, = worker("a1", "README" => "one\n")
      second, = worker("a2", "README" => "two\n")
      approve("a", first)
      approve("a", second)

      expect(landing.anchored("a").worker.sha).to eq(second)
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

  # Scenario: landing refuses a change outside scope unless the gate admitted it
  describe "the issue's allowed paths, checked over the whole diff" do
    let(:scope) { ->(_issue_id) { ["docs/m0-findings.md"] } }

    def scoped_worker = worker("a", "docs/m0-findings.md" => "findings\n", "spike/src/main.rs" => "fn main() {}\n")

    def admitting(note, sha) = approve("a", sha, verdict: Lain::Approval::Verdict::Approve.new(note:))

    it "refuses a change outside them the gate did not admit, naming only that path, and lands nothing" do
      sha, ref = scoped_worker
      approve("a", sha)
      before = tip

      expect { landing.call("a", sha:, ref:) }.to raise_error(described_class::OutsideScope) { |error|
        expect(error.message).to include("changes outside the issue's allowed paths", "spike/src/main.rs",
                                         "approve, admit spike/src/main.rs")
        expect(error.message).not_to include("docs/m0-findings.md")
      }
      expect(tip).to eq(before)
      expect(transitions).to be_empty
    end

    it "lands it when the approving answer admitted the path's directory" do
      sha, ref = scoped_worker
      admitting("admit spike/", sha)

      expect(landing.call("a", sha:, ref:).landed.first.report.kind).to eq(:merged)
    end

    it "matches an admitted prefix by whole path segments, never by a bare string prefix" do
      sha, ref = scoped_worker
      admitting("admit spi", sha)

      expect { landing.call("a", sha:, ref:) }.to raise_error(described_class::OutsideScope, %r{spike/src/main\.rs})
    end

    it "counts a deleted file outside them" do
      git("switch", "-q", "--detach", tip)
      git("rm", "-q", "app/models/order.rb")
      git("commit", "-q", "-m", "drop the order")
      sha = git("rev-parse", "HEAD")
      git("switch", "-q", "epic/demo")
      anchor("a", 1, sha)
      approve("a", sha)

      expect { landing.anchored("a") }.to raise_error(described_class::OutsideScope, %r{app/models/order\.rb})
    end

    it "asks the scope of the issue being landed" do
      asked = []
      sha, ref = worker("a", "docs/m0-findings.md" => "findings\n")
      approve("a", sha)

      scope = ->(issue_id) { ["docs/"].tap { asked << issue_id } }

      described_class.new(**wiring, scope:).call("a", sha:, ref:)

      expect(asked).to eq(["a"])
    end

    it "does not admit a re-synced commit outside them" do
      sha, = scoped_worker
      approve("a", sha)

      expect(landing.admissible?("a", sha)).to be(false)
    end

    context "when the section lists no path" do
      let(:scope) { ->(_issue_id) { [] } }

      it "refuses any change" do
        sha, ref = worker("a", "docs/m0-findings.md" => "findings\n")
        approve("a", sha)

        expect { landing.call("a", sha:, ref:) }.to raise_error(described_class::OutsideScope, %r{docs/m0-findings\.md})
      end
    end

    context "when the section lists only ./" do
      let(:scope) do
        graph = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "a")])
        allowed = Lain::Epic::IssueView.new(issue: graph.fetch("a"), graph:,
                                            authored: "## Allowed paths\n\n- ./\n").allowed_paths
        ->(_issue_id) { allowed }
      end

      it "does not allow everything" do
        sha, ref = worker("a", "docs/m0-findings.md" => "findings\n")
        approve("a", sha)

        expect { landing.call("a", sha:, ref:) }.to raise_error(described_class::OutsideScope, %r{docs/m0-findings\.md})
      end
    end

    it "says only to take out a change no reply can admit, never to approve it again" do
      sha, ref = worker("a", "docs/m0-findings.md" => "findings\n", "my notes.md" => "notes\n")
      approve("a", sha)

      expect { landing.call("a", sha:, ref:) }.to raise_error(described_class::OutsideScope) { |error|
        expect(error.message).to include("my notes.md cannot be admitted by name; remove it from the commit")
        expect(error.message).not_to include("approve it again")
      }
    end

    it "requires a scope, so no caller lands unchecked" do
      expect { described_class.new(**wiring.except(:scope)) }.to raise_error(ArgumentError, /scope/)
    end

    # Scenario: an issue without the section is unchecked
    context "when the issue has no Allowed paths section" do
      let(:scope) { ->(_issue_id) {} }

      it "lands a change anywhere" do
        sha, ref = scoped_worker
        approve("a", sha)

        expect(landing.call("a", sha:, ref:).landed.first.report.kind).to eq(:merged)
      end
    end
  end

  # The gate reads the same placement, before any landing, so it lists what the landing will judge.
  describe "the placement the gate reads" do
    def placement(on = base)
      described_class::Placement.new(repo_root: @repo, layout: Lain::TestLayout::None, base: on,
                                     shell_out_factory: recording)
    end

    def sha = worker("a", "docs/m0-findings.md" => "findings\n", "spike/src/main.rs" => "fn main() {}\n").first

    it "states the diffstat against the working branch" do
      expect(placement.diffstat(sha)).to include(a_string_including("spike/src/main.rs"),
                                                 a_string_including("2 files changed"))
    end

    it "lists the changed paths no allowed or admitted prefix covers" do
      expect(placement.outside_scope(sha, allowed: ["docs/m0-findings.md"], admitted: [])).to eq(["spike/src/main.rs"])
      expect(placement.outside_scope(sha, allowed: ["docs/m0-findings.md"], admitted: ["spike"])).to eq([])
      expect(placement.outside_scope(sha, allowed: ["docs/m0"], admitted: [])).to eq(%w[docs/m0-findings.md
                                                                                        spike/src/main.rs])
    end

    it "lists nothing for an issue with no section" do
      expect(placement.outside_scope(sha, allowed: nil, admitted: [])).to eq([])
    end

    it "lets no empty prefix cover every path" do
      ["", ".", "/", "./"].each do |prefix|
        expect(placement.outside_scope(sha, allowed: [], admitted: [prefix]))
          .to eq(%w[docs/m0-findings.md spike/src/main.rs]), prefix.inspect
      end
    end

    it "lists every changed path for a section that allows none" do
      expect(placement.outside_scope(sha, allowed: [], admitted: [])).to eq(%w[docs/m0-findings.md spike/src/main.rs])
    end

    context "when the working branch does not exist, as for a gate asked by hand" do
      let(:missing) do
        Lain::Isolation::WorkingBranch.new("epic/missing", repo_root: @repo, git: Lain::Isolation::Checkout.new(@repo))
      end

      def built(parent, files, ref)
        CommitBuilder.call(@repo, parent:, files:, message: "work", ref: "refs/lain-spec/#{ref}")
      end

      # The commit's parent is off every branch, so a diff from any branch tip would carry the parent's file too.
      it "diffs the commit against its own parent" do
        earlier = built(tip, { "docs/m0-findings.md" => "findings\n" }, "earlier")
        commit = built(earlier, { "spike/src/main.rs" => "fn main() {}\n" }, "commit")

        expect(placement(missing).diffstat(commit)).to eq([" spike/src/main.rs | 1 +",
                                                           " 1 file changed, 1 insertion(+)"])
        expect(placement(missing).outside_scope(commit, allowed: ["docs/"], admitted: [])).to eq(["spike/src/main.rs"])
      end

      it "diffs a merge commit against its first parent, so what the merge brings in is listed" do
        side = built(tip, { "docs/m0-findings.md" => "findings\n" }, "side")
        main = built(tip, { "spike/src/main.rs" => "fn main() {}\n" }, "main")
        git("switch", "-q", "--detach", main)
        git("merge", "-q", "--no-ff", "-m", "merge the side", side)
        merge = git("rev-parse", "HEAD")
        git("switch", "-q", "epic/demo")

        expect(placement(missing).outside_scope(merge, allowed: ["spike/"],
                                                       admitted: [])).to eq(["docs/m0-findings.md"])
      end
    end
  end

  def wiring
    { epic_slug: "demo", repo_root: @repo, base:, signoff:, plan:, scope:, progress:, scribe:, queue:, layout:,
      shell_out_factory: recording }
  end
end
