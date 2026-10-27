# frozen_string_literal: true

require "fileutils"

# A fix is graded by three runs of the level's tests: before the change, with it,
# and with it taken back out. Each run happens in a scratch copy, so the lease
# the arm worked in is never written to.
RSpec.describe Lain::Grader::ThreeArm do
  def subject_project = File.expand_path("../../fixtures/altitude/subjects/order-total", __dir__)

  def leased(project = subject_project)
    Dir.mktmpdir("lain-three-arm") do |dir|
      checkout = File.join(dir, "checkout")
      FileUtils.mkdir_p(checkout)
      FileUtils.cp_r(File.join(project, "."), checkout)
      yield Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: checkout, env: ENV.to_h),
                                       on_release: -> { FileUtils.remove_entry(checkout) },
                                       origin: Lain::Isolation::Lease::Origin.new(path: checkout)),
            checkout, dir
    end
  end

  def level_in(checkout) = Lain::Config.test_layout(root: checkout).mapping.level("unit")

  def fix(checkout)
    path = File.join(checkout, "lib/order.rb")
    File.write(path, File.read(path).sub("def refunded = nil", "def refunded = 0"))
  end

  def tree(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { |path| File.file?(File.join(root, path)) }
       .sort.to_h { |path| [path, File.binread(File.join(root, path))] }
  end

  def verdict(pass) = Lain::Grader::Grade.new(score: pass ? 1.0 : 0.0, pass:, why: pass ? "green" : "red")

  # Answers each run in turn from a script, and keeps what the tree looked like at that moment.
  def scripted(*passes, seen)
    queue = passes.dup
    spec = self
    runner = Class.new do
      define_method(:grade) do |worker_env, paths:|
        seen << { cwd: worker_env.cwd, paths:, tree: spec.tree(worker_env.cwd),
                  entries: Dir.glob("**/*", File::FNM_DOTMATCH, base: worker_env.cwd).sort }
        spec.verdict(queue.shift)
      end
    end
    ->(_root) { runner.new }
  end

  def graded(lease, checkout, base: subject_project, **)
    described_class.new(lease:, level: level_in(checkout), base:, **)
  end

  # A copy of the subject with a second source file, so one can be deleted without touching a root file.
  def with_base
    Dir.mktmpdir("lain-three-arm-base") do |base|
      FileUtils.cp_r(File.join(subject_project, "."), base)
      File.write(File.join(base, "lib/helper.rb"), "# helper\n")
      yield base
    end
  end

  describe "#grade with the subject's own suite", :seam do
    it "passes a real fix, naming all 3 results" do
      leased do |lease, checkout|
        fix(checkout)
        grade = graded(lease, checkout).grade

        expect(grade).to be_pass
        expect(grade.why).to match(%r{base failed \(2/3.*head passed \(all 3.*revert failed \(2/3}m)
      end
    end

    it "leaves the lease byte-identical and no scratch copy behind" do
      leased do |lease, checkout, dir|
        fix(checkout)
        before = tree(checkout)
        graded(lease, checkout).grade

        expect(tree(checkout)).to eq(before)
        expect(Dir.children(dir)).to eq(["checkout"])
      end
    end

    it "fails an arm that changed nothing, without calling the change a fix" do
      leased do |lease, checkout|
        grade = graded(lease, checkout).grade

        expect(grade).not_to be_pass
        expect(grade.why).to include("does not make the test pass")
      end
    end
  end

  describe "#grade, run by run" do
    it "fails with 'the test passes without the change' when base already passes" do
      leased do |lease, checkout|
        seen = []
        grade = graded(lease, checkout, harness: scripted(true, seen)).grade

        expect([grade.pass?, grade.why]).to eq([false, "the test passes without the change"])
        expect(seen.size).to eq(1)
      end
    end

    it "fails when reverting the change leaves the test passing" do
      leased do |lease, checkout|
        grade = graded(lease, checkout, harness: scripted(false, true, true, [])).grade

        expect([grade.pass?, grade.why]).to eq([false, "reverting the change does not bring the failure back"])
      end
    end

    it "runs base, head, then revert, each in a copy, narrowed to the level root" do
      leased do |lease, checkout|
        seen = []
        graded(lease, checkout, harness: scripted(false, true, false, seen)).grade

        expect(seen.map { |run| run[:cwd] }.uniq.size).to eq(3)
        expect(seen.map { |run| run[:cwd] }).not_to include(checkout)
        expect(seen.map { |run| run[:paths] }.uniq).to eq([["spec/unit"]])
      end
    end

    it "reverts source files to base and keeps the test files as the head has them" do
      leased do |lease, checkout|
        fix(checkout)
        File.write(File.join(checkout, "lib/extra.rb"), "x = 1\n")
        seen = []
        graded(lease, checkout, harness: scripted(false, true, false, seen)).grade

        head, revert = seen.values_at(1, 2).map { |run| run[:tree] }
        expect(head.fetch("lib/order.rb")).to include("def refunded = 0")
        expect(revert.fetch("lib/order.rb")).to eq(File.read(File.join(subject_project, "lib/order.rb")))
        expect(revert).not_to have_key("lib/extra.rb")
        expect(revert.slice(*head.keys.grep(%r{\Aspec/}))).to eq(head.slice(*head.keys.grep(%r{\Aspec/})))
      end
    end
  end

  describe "the revert, rebuilt from base" do
    def reverted_entries(base: subject_project, &arm_work)
      seen = []
      leased(base) do |lease, checkout|
        yield(checkout)
        graded(lease, checkout, base:, harness: scripted(false, true, false, seen)).grade
      end
      seen.last
    end

    it "gets a deleted source file back, leaving the revert equal to base" do
      with_base do |base|
        revert = reverted_entries(base:) do |checkout|
          fix(checkout)
          FileUtils.rm(File.join(checkout, "lib/helper.rb"))
        end

        expect(revert[:tree]).to eq(tree(base))
      end
    end

    it "drops an added symlink, dangling or to a directory" do
      revert = reverted_entries do |checkout|
        File.symlink("/nonexistent", File.join(checkout, "lib/dangling.rb"))
        File.symlink(checkout, File.join(checkout, "lib/dirlink"))
      end

      expect(revert[:entries]).not_to include("lib/dangling.rb", "lib/dirlink")
    end

    it "puts a file back where the arm made a directory" do
      revert = reverted_entries do |checkout|
        FileUtils.rm(File.join(checkout, "lib/order.rb"))
        FileUtils.mkdir_p(File.join(checkout, "lib/order.rb"))
        File.write(File.join(checkout, "lib/order.rb/inner.rb"), "1")
      end

      expect(revert[:entries]).not_to include("lib/order.rb/inner.rb")
      expect(revert[:tree].fetch("lib/order.rb")).to eq(File.read(File.join(subject_project, "lib/order.rb")))
    end

    it "drops an added empty directory" do
      revert = reverted_entries { |checkout| FileUtils.mkdir_p(File.join(checkout, "lib/newdir")) }

      expect(revert[:entries]).not_to include("lib/newdir")
    end
  end

  describe "cleanup and short-circuits" do
    it "leaves only the lease behind when a run raises" do
      leased do |lease, checkout, dir|
        raising = ->(_root) { Class.new { def grade(*, **) = raise("boom") }.new }

        expect { graded(lease, checkout, harness: raising).grade }.to raise_error("boom")
        expect(Dir.children(dir)).to eq(["checkout"])
      end
    end

    it "does not run the revert when the head fails" do
      leased do |lease, checkout|
        seen = []
        graded(lease, checkout, harness: scripted(false, false, seen)).grade

        expect(seen.size).to eq(2)
      end
    end
  end

  describe "the seal and the lease" do
    it "raises Tampered before any run when a test file differs from base" do
      leased do |lease, checkout|
        File.write(File.join(checkout, "spec/unit/order_check.rb"), "# edited\n")
        seen = []

        expect { graded(lease, checkout, harness: scripted(false, seen)).grade }
          .to raise_error(Lain::Grader::LeaseHarness::Tampered) { |error| expect(error.paths).to eq(["spec/unit/order_check.rb"]) }
        expect(seen).to be_empty
      end
    end

    it "refuses a lease holding no checkout" do
      lease = Struct.new(:worker_env).new(nil)

      expect { described_class.new(lease:, level: level_in(subject_project), base: subject_project).grade }
        .to raise_error(Lain::Grader::LeaseHarness::NoCheckout)
    end
  end

  describe "#identity" do
    it "says what it is: class, level, the seal and the base tree" do
      leased do |lease, checkout|
        identity = graded(lease, checkout).identity

        expect(identity).to include("class" => "Lain::Grader::ThreeArm", "level" => "unit")
        expect(identity.keys).to include("sealed", "base")
        expect(Ractor.shareable?(identity)).to be(true)
      end
    end

    it "does not raise on an unreadable base file" do
      skip "root reads anything" if Process.uid.zero?
      leased do |lease, checkout|
        with_base do |base|
          File.chmod(0o000, File.join(base, "lib/helper.rb"))

          expect { graded(lease, checkout, base:).identity }.not_to raise_error
        end
      end
    end

    it "changes when the base tree changes" do
      leased do |lease, checkout|
        Dir.mktmpdir("lain-three-arm-base") do |other|
          FileUtils.cp_r(File.join(subject_project, "."), other)
          File.write(File.join(other, "lib/order.rb"), "# other\n")

          expect(described_class.new(lease:, level: level_in(checkout), base: other).identity.fetch("base"))
            .not_to eq(graded(lease, checkout).identity.fetch("base"))
        end
      end
    end
  end
end
