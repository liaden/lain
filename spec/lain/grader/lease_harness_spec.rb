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
  def trajectory = Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)

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

  describe "#identity" do
    it "names the class and the level" do
      leased do |lease, checkout|
        level = level_in(checkout, "unit")

        expect(described_class.new(lease:,
                                   level:).identity).to eq(
                                     "class" => described_class.name, "level" => level.name.to_s
                                   )
      end
    end

    it "differs between harnesses sealed over different test trees" do
      leased do |lease, checkout|
        level = level_in(checkout, "unit")
        plain = described_class.new(lease:, level:).identity
        sealed = described_class.new(lease:, level:, sealed: "a" * 64).identity
        other = described_class.new(lease:, level:, sealed: "b" * 64).identity

        expect([plain, other]).to all(satisfy { |identity| identity != sealed })
        expect(sealed).to include("sealed" => "a" * 64)
        expect(Ractor.shareable?(sealed)).to be(true)
      end
    end
  end

  describe "sealing the level's test tree" do
    def edit_test(checkout)
      File.write(File.join(checkout, "spec/unit/order_total_spec.rb"), "# an arm made its own tests easier\n")
    end

    def sealed_harness(lease, checkout, pristine:)
      level = level_in(checkout, "unit")
      described_class.new(lease:, level:, pristine: described_class.manifest(pristine, level:))
    end

    it "seals the same tree to the same digest, and a different tree to a different one" do
      leased do |_lease, checkout|
        level = level_in(checkout, "unit")
        before = Lain::Canonical.digest(described_class.manifest(checkout, level:))

        expect(before).to match(/\Ablake3:\h{64}\z/).and eq(Lain::Canonical.digest(described_class.manifest(
                                                                                     subject_project, level:
                                                                                   )))
        edit_test(checkout)
        expect(Lain::Canonical.digest(described_class.manifest(checkout, level:))).not_to eq(before)
      end
    end

    it "does not seal source files, so an arm may change them" do
      leased do |_lease, checkout|
        level = level_in(checkout, "unit")
        before = Lain::Canonical.digest(described_class.manifest(checkout, level:))
        File.write(File.join(checkout, "lib/order_total.rb"), "# the arm's real work\n", mode: "a")

        expect(Lain::Canonical.digest(described_class.manifest(checkout, level:))).to eq(before)
      end
    end

    # The helper and the runner config decide what the level's tests do and
    # which of them run, so editing them is editing the tests.
    it "seals the whole test directory, so a spec_helper or a sibling level is covered" do
      leased do |lease, checkout|
        harness = sealed_harness(lease, checkout, pristine: subject_project)
        File.write(File.join(checkout, "spec/spec_helper.rb"), "exit 0\n")

        expect { harness.grade(trajectory) }
          .to raise_error(described_class::Tampered) { |error| expect(error.paths).to eq(["spec/spec_helper.rb"]) }
      end
    end

    it "seals the root files that decide what runs, such as .rspec" do
      leased do |lease, checkout|
        harness = sealed_harness(lease, checkout, pristine: subject_project)
        File.write(File.join(checkout, ".rspec"), "--pattern nothing_matches\n")

        expect { harness.grade(trajectory) }
          .to raise_error(described_class::Tampered) { |error| expect(error.paths).to eq([".rspec"]) }
      end
    end

    it "names a file that was deleted" do
      leased do |lease, checkout|
        harness = sealed_harness(lease, checkout, pristine: subject_project)
        FileUtils.rm(File.join(checkout, "spec/unit/order_check.rb"))

        expect { harness.grade(trajectory) }
          .to raise_error(described_class::Tampered) { |error| expect(error.paths).to eq(["spec/unit/order_check.rb"]) }
      end
    end

    it "names a file that was made unreadable, rather than dying of EACCES" do
      leased do |lease, checkout|
        harness = sealed_harness(lease, checkout, pristine: subject_project)
        path = File.join(checkout, "spec/unit/order_check.rb")
        File.chmod(0o000, path)

        expect { harness.grade(trajectory) }
          .to raise_error(described_class::Tampered) { |error| expect(error.paths).to eq(["spec/unit/order_check.rb"]) }
      ensure
        File.chmod(0o644, path) if path && File.exist?(path)
      end
    end

    it "catches a changed mode with unchanged content" do
      leased do |lease, checkout|
        harness = sealed_harness(lease, checkout, pristine: subject_project)
        File.chmod(0o755, File.join(checkout, "spec/unit/order_check.rb"))

        expect { harness.grade(trajectory) }
          .to raise_error(described_class::Tampered) { |error| expect(error.paths).to eq(["spec/unit/order_check.rb"]) }
      end
    end

    it "raises Tampered naming the changed test paths, before any suite runs" do
      leased do |lease, checkout|
        harness = sealed_harness(lease, checkout, pristine: subject_project)
        edit_test(checkout)
        FileUtils.touch(File.join(checkout, "spec/unit/added_spec.rb"))

        expect { harness.grade(trajectory) }
          .to raise_error(described_class::Tampered) { |error|
            expect(error.paths).to contain_exactly("spec/unit/added_spec.rb", "spec/unit/order_total_spec.rb")
            expect(error.message).to include("spec/unit/order_total_spec.rb")
          }
      end
    end

    it "grades an untouched test tree as the suite's own verdict" do
      leased do |lease, checkout|
        File.write(File.join(checkout, "lib/order_total.rb"), "\n", mode: "a")
        grade = sealed_harness(lease, checkout, pristine: subject_project).grade(trajectory)

        expect(grade.score).to eq(2.0 / 3)
      end
    end

    describe "when new tests are allowed" do
      def lenient(lease, checkout)
        level = level_in(checkout, "unit")
        described_class.new(lease:, level:, pristine: described_class.manifest(subject_project, level:),
                            new_tests: true)
      end

      it "grades a checkout that gained a test file" do
        leased do |lease, checkout|
          FileUtils.touch(File.join(checkout, "spec/unit/added_spec.rb"))

          expect { lenient(lease, checkout).grade(trajectory) }.not_to raise_error
        end
      end

      it "still names an edited pristine test file" do
        leased do |lease, checkout|
          File.write(File.join(checkout, "spec/unit/order_check.rb"), "# edited\n")
          FileUtils.touch(File.join(checkout, "spec/unit/added_spec.rb"))

          expect { lenient(lease, checkout).grade(trajectory) }
            .to raise_error(described_class::Tampered) { |error|
                  expect(error.paths).to eq(["spec/unit/order_check.rb"])
                }
        end
      end

      it "still names a root file the arm added" do
        leased do |lease, checkout|
          File.write(File.join(checkout, "Rakefile"), "\n")

          expect { lenient(lease, checkout).grade(trajectory) }
            .to raise_error(described_class::Tampered) { |error| expect(error.paths).to eq(["Rakefile"]) }
        end
      end
    end

    it "still refuses on a bare digest, with no paths to name" do
      leased do |lease, checkout|
        level = level_in(checkout, "unit")
        harness = described_class.new(lease:, level:,
                                      sealed: Lain::Canonical.digest(described_class.manifest(checkout, level:)))
        edit_test(checkout)

        expect { harness.grade(trajectory) }.to raise_error(described_class::Tampered) { |error|
          expect(error.paths).to eq([])
        }
      end
    end
  end
end
