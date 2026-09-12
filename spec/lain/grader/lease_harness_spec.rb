# frozen_string_literal: true

require "fileutils"

# The lease harness adapts {Lain::Grader::TestHarness} to the arm grader duck:
# an arm hands its grader a trajectory, and this answers with the verdict of the
# SUBJECT'S OWN SUITE, run in the checkout the lease is holding and narrowed to
# one level root.
#
# Two invariants carry the whole object. It grades where the work is -- the
# lease's own checkout, never the process cwd -- and it grades BEFORE the lease
# is released, because a released worktree is a removed directory and a suite
# that cannot be found grades as a suite that failed.
RSpec.describe Lain::Grader::LeaseHarness do
  # A method rather than a group-level local: a local assigned in the class body
  # is not in scope inside the helpers defined below it.
  def subject_project = File.expand_path("../../fixtures/altitude/subjects/order-total", __dir__)

  # A real Lease over a real copy of the fixture subject, whose release really
  # removes the checkout -- which is what lets "the worktree still existed when
  # graded" be an assertion rather than a hope.
  def leased(project = subject_project)
    Dir.mktmpdir("lain-lease-harness") do |dir|
      checkout = File.join(dir, "checkout")
      FileUtils.mkdir_p(checkout)
      FileUtils.cp_r(File.join(project, "."), checkout)
      yield Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: checkout, env: ENV.to_h),
                                       on_release: -> { FileUtils.remove_entry(checkout) },
                                       origin: Lain::Isolation::Lease::Origin.new(path: checkout)),
            checkout
    end
  end

  # The level roots come from the subject's OWN `[tests]` table, so what is
  # under test is the layout wiring an arm would really have, not a root this
  # spec invented.
  def level_in(checkout, name) = Lain::Config.test_layout(root: checkout).mapping.level(name)

  # A Timeline-shaped stand-in for what an arm actually hands its grader. It is
  # deliberately never consulted: the subject's suite is the judgement.
  def trajectory = Lain::Timeline.empty(store: Lain::Store.new)

  describe "#grade — the subject's own suite, at one level root", :seam do
    # Scenario: an arm's run is graded by the subject's own suite, before
    # retirement.
    it "grades 2 of 3 for the unit root, and does not pass" do
      leased do |lease, checkout|
        grade = described_class.new(lease:, level: level_in(checkout, "unit")).grade(trajectory)

        expect(grade).to be_a(Lain::Grader::Grade)
        expect(grade.score).to eq(2.0 / 3)
        expect(grade).not_to be_pass
        expect(grade.why).to include("refunds a line")
      end
    end

    # The narrowing is what makes the number mean "this level", and the fixture
    # commits a passing example at a SECOND level root so a harness that ran the
    # whole suite would grade 3 of 4 here instead.
    it "runs only the level root it was bound to, never the whole suite" do
      leased do |lease, checkout|
        seam = described_class.new(lease:, level: level_in(checkout, "seam")).grade(trajectory)

        expect(seam.why).to eq("all 1 examples passed")
        expect(seam).to be_pass
      end
    end

    it "runs the suite in the lease's own checkout, not the process cwd" do
      roots = []
      leased do |lease, checkout|
        factory = lambda do |root, **options|
          roots << root
          Lain::Grader::TestHarness.new(root, **options)
        end
        described_class.new(lease:, level: level_in(checkout, "unit"), harness: factory).grade(trajectory)

        expect(roots).to eq([checkout])
        expect(roots).not_to include(Dir.pwd)
      end
    end

    # Scenario (the second half): the worktree still existed when graded. A
    # harness that released first would grade a directory that is no longer
    # there, and rspec's own LoadError would read as an arm whose work failed.
    it "grades while the checkout is still on disk, and releases nothing itself" do
      leased do |lease, checkout|
        standing = nil
        factory = lambda do |root, **options|
          standing = Dir.exist?(root)
          Lain::Grader::TestHarness.new(root, **options)
        end
        grade = described_class.new(lease:, level: level_in(checkout, "unit"), harness: factory).grade(trajectory)

        expect(standing).to be(true)
        expect(lease).not_to be_released
        expect(grade.score).to eq(2.0 / 3)
        # And the release really would have taken it, which is what the
        # assertion above is worth anything for.
        lease.release
        expect(Dir.exist?(checkout)).to be(false)
      end
    end

    # The arm seam is `grade(timeline)`. This answers it, and answers it the
    # same whatever it is handed, because the trajectory is not the evidence.
    it "answers the arm grader duck, reading nothing off the trajectory" do
      leased do |lease, checkout|
        harness = described_class.new(lease:, level: level_in(checkout, "unit"))

        expect(harness.grade(trajectory)).to eq(harness.grade(:not_a_timeline_at_all))
      end
    end
  end

  # {Lain::Arm::NoIsolation}'s lease carries NO WorkerEnv at all -- it is the
  # honest "this run leased nothing", and it is what an arm gets when no
  # isolation was injected. A grader bound there cannot run a suite anywhere, so
  # it must say which thing is missing rather than die of a NoMethodError on nil
  # three frames from the fact.
  describe "a lease that holds no checkout" do
    def level = Lain::TestLayout::Mapping::Level.new(name: "unit", root: "spec/unit", shape: :mirrored)

    it "refuses by name, saying a grade needs a checkout to run in" do
      harness = described_class.new(lease: Lain::Arm::NoIsolation::LEASE, level:)

      expect { harness.grade(nil) }.to raise_error(described_class::NoCheckout, /checkout/)
    end

    it "names the level it was asked to grade, so the refusal says what was being judged" do
      harness = described_class.new(lease: Lain::Arm::NoIsolation::LEASE, level:)

      expect { harness.grade(nil) }.to raise_error(described_class::NoCheckout, /unit/)
    end

    # The refusal is about the LEASE, so it fires before anything tries to
    # detect a framework or spawn a runner.
    it "refuses before it builds a harness at all" do
      built = []
      harness = described_class.new(lease: Lain::Arm::NoIsolation::LEASE, level:,
                                    harness: ->(root, **) { built << root })

      expect { harness.grade(nil) }.to raise_error(described_class::NoCheckout)
      expect(built).to be_empty
    end
  end

  # An epic arm settles one issue at a time, so it holds one Grade per issue and
  # the arm's Run carries ONE. The roll-up is that fold, and it is pure.
  describe ".rolled_up — one grade per issue, folded into the run's own" do
    def grade(score, why, pass: score >= 1.0) = Lain::Grader::Grade.new(score:, pass:, why:)

    it "scores the mean of its issues and passes only when every issue did" do
      rolled = described_class.rolled_up("a" => grade(1.0, "all 3 examples passed"),
                                         "b" => grade(0.5, "1/2 examples passed; failed: refunds"))

      expect(rolled.score).to eq(0.75)
      expect(rolled).not_to be_pass
    end

    it "passes when every issue passed" do
      rolled = described_class.rolled_up("a" => grade(1.0, "all 3 examples passed"),
                                         "b" => grade(1.0, "all 1 examples passed"))

      expect(rolled).to be_pass
      expect(rolled.score).to eq(1.0)
    end

    it "names every issue in its reason, so a folded score stays readable" do
      rolled = described_class.rolled_up("a" => grade(1.0, "all 3 examples passed"),
                                         "b" => grade(0.5, "1/2 examples passed; failed: refunds"))

      expect(rolled.why).to include("a").and include("b").and include("failed: refunds")
    end

    # A zero would read as an arm that failed every issue it was given, which is
    # the one reading a bench must never invent -- so nothing to fold is a
    # refusal, the way the suite grader refuses a timeline naming no task.
    it "refuses to fold nothing, rather than scoring an unrun arm as zero" do
      expect { described_class.rolled_up({}) }
        .to raise_error(described_class::NothingGraded, /no issue/i)
    end
  end
end
