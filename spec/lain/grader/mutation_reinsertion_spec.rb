# frozen_string_literal: true

require "fileutils"

# Tests the agent wrote are graded by putting known bugs back into the source
# and counting how many the tests notice. Each mutant is applied in a scratch
# copy beside the lease, so the lease is never written to.
RSpec.describe Lain::Grader::MutationReinsertion do
  def subject_project = File.expand_path("../../fixtures/altitude/subjects/tally-tests", __dir__)

  def mutations_dir = "#{subject_project}.mutations"

  def mutations
    Dir.glob("#{mutations_dir}/*.patch").map do |path|
      described_class::Mutation.new(name: File.basename(path, ".patch"), patch_path: path)
    end
  end

  def leased(project = subject_project)
    Dir.mktmpdir("lain-mutation-reinsertion") do |dir|
      checkout = File.join(dir, "checkout")
      FileUtils.mkdir_p(checkout)
      FileUtils.cp_r(File.join(project, "."), checkout)
      trust_project(checkout)
      yield Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: checkout, env: ENV.to_h),
                                       on_release: -> { FileUtils.remove_entry(checkout) },
                                       origin: Lain::Isolation::Lease::Origin.new(path: checkout)),
            checkout, dir
    end
  end

  def level_in(checkout) = Lain::Config.test_layout(root: checkout).mapping.level("unit")

  def graded(lease, checkout, base: subject_project, **)
    described_class.new(lease:, level: level_in(checkout), mutations:, base:, **)
  end

  # The pattern is read from the pristine base, since the arm cannot change a root file.
  def project_with(rspec_options)
    Dir.mktmpdir("lain-mutation-project") do |project|
      FileUtils.cp_r(File.join(subject_project, "."), project)
      trust_project(project)
      File.write(File.join(project, ".rspec"), rspec_options)
      yield project
    end
  end

  def tree(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { |path| File.file?(File.join(root, path)) }
       .sort.to_h { |path| [path, File.binread(File.join(root, path))] }
  end

  def write_tests(checkout, body, name: "agent_check.rb")
    File.write(File.join(checkout, "spec/unit", name), "require_relative \"../../lib/tally\"\n\n#{body}")
  end

  def thorough = <<~RUBY
    RSpec.describe Tally do
      it("adds an amount") { expect(described_class.new.add(:a, 3).count(:a)).to eq(3) }
      it("refuses zero") { expect { described_class.new.add(:a, 0) }.to raise_error(ArgumentError) }
      it("totals the amounts") { expect(described_class.new.add(:a, 2).add(:b, 3).total).to eq(5) }
      it("names the most counted key") { expect(described_class.new.add(:a).add(:b, 4).top).to eq(:b) }
    end
  RUBY

  def weak = <<~RUBY
    RSpec.describe Tally do
      it("adds an amount") { expect(described_class.new.add(:a, 3).count(:a)).to eq(3) }
      it("refuses zero") { expect { described_class.new.add(:a, 0) }.to raise_error(ArgumentError) }
      it("totals the amounts") { expect(described_class.new.add(:a, 2).add(:b, 3).total).to eq(5) }
    end
  RUBY

  # Answers each run in turn from a script and records where it ran.
  def scripted(passes, seen)
    queue = passes.dup
    runner = Class.new do
      define_method(:grade) do |worker_env, paths:|
        seen << { cwd: worker_env.cwd, paths:, entries: Dir.glob("**/*", base: worker_env.cwd) }
        pass = queue.shift
        Lain::Grader::Grade.new(score: pass ? 1.0 : 0.0, pass:, why: pass ? "green" : "red")
      end
    end
    ->(_root) { runner.new }
  end

  describe "#grade with the subject's own suite", :seam do
    it "scores tests that catch every planted bug 1, listing 4 of 4 killed" do
      leased do |lease, checkout|
        write_tests(checkout, thorough)
        grade = graded(lease, checkout).grade

        expect([grade.score, grade.pass?, grade.why]).to eq([1.0, true, "4 of 4 mutations killed"])
      end
    end

    it "scores 0.75 for tests that miss 1 of 4, and names the survivor" do
      leased do |lease, checkout|
        write_tests(checkout, weak)
        grade = graded(lease, checkout).grade

        expect([grade.score, grade.pass?]).to eq([0.75, false])
        expect(grade.why).to eq("3 of 4 mutations killed; survived: top-picks-least")
      end
    end

    it "does not credit tests that fail on correct code, and applies no mutation" do
      leased do |lease, checkout|
        write_tests(checkout, weak.sub("eq(5)", "eq(6)"))
        grade = graded(lease, checkout).grade

        expect([grade.score, grade.pass?, grade.why]).to eq([0.0, false, "the tests fail on correct code"])
      end
    end

    it "runs only the files the agent added, not the subject's own checks" do
      leased do |lease, checkout|
        write_tests(checkout, weak)
        seen = []
        graded(lease, checkout, harness: scripted([true] * 5, seen)).grade

        expect(seen.map { |run| run[:paths] }.uniq).to eq([["spec/unit/agent_check.rb"]])
      end
    end

    it "leaves the lease byte-identical and no scratch copy behind" do
      leased do |lease, checkout, dir|
        write_tests(checkout, thorough)
        before = tree(checkout)
        graded(lease, checkout).grade

        expect(tree(checkout)).to eq(before)
        expect(Dir.children(dir)).to eq(["checkout"])
      end
    end

    it "leaves the lease byte-identical when a run raises" do
      leased do |lease, checkout, dir|
        write_tests(checkout, thorough)
        before = tree(checkout)
        raising = ->(_root) { Class.new { def grade(*, **) = raise("boom") }.new }

        expect { graded(lease, checkout, harness: raising).grade }.to raise_error("boom")
        expect(tree(checkout)).to eq(before)
        expect(Dir.children(dir)).to eq(["checkout"])
      end
    end
  end

  describe "a patch that does not fit the pristine source" do
    it "is skipped in its own column, counts as not killed, and fails the grade as broken fixture data" do
      leased do |lease, checkout, dir|
        write_tests(checkout, thorough)
        broken = File.join(dir, "broken.patch")
        File.write(broken, File.read(mutations.first.patch_path).sub("amount.positive?", "amount.never?"))
        listed = [described_class::Mutation.new(name: "broken", patch_path: broken), *mutations.drop(1)]
        grade = described_class.new(lease:, level: level_in(checkout), mutations: listed, base: subject_project).grade

        expect(grade.score).to eq(0.75)
        expect(grade).not_to be_pass
        expect(grade.why).to eq("3 of 4 mutations killed; skipped (broken fixture data, the patch does not fit " \
                                "the pristine source): broken")
      end
    end
  end

  describe "edits the arm made to the source" do
    def grade_after_editing(&edit)
      leased do |lease, checkout|
        write_tests(checkout, thorough)
        yield(File.join(checkout, "lib/tally.rb"))
        return graded(lease, checkout).grade
      end
    end

    it "cannot make every mutant fail, so a guard that raises in each scores as pristine source would" do
      grade = grade_after_editing do |source|
        File.write(source, "#{File.read(source)}\nraise 'mutated' unless File.read(__FILE__).size == 0\n")
      end

      expect([grade.score, grade.why]).to eq([1.0, "4 of 4 mutations killed"])
      expect(grade_after_editing { |_source| nil }.score).to eq(1.0)
    end

    it "cannot make a patch stop applying" do
      grade = grade_after_editing do |source|
        File.write(source, File.read(source).gsub("amount.positive?", "amount.positive? "))
      end

      expect([grade.score, grade.why]).to eq([1.0, "4 of 4 mutations killed"])
    end

    it "is judged by a copy of the base, so the clean run never sees a broken edit" do
      grade = grade_after_editing { |source| File.write(source, "raise 'broken'\n") }

      expect(grade.score).to eq(1.0)
    end
  end

  describe "which new files count as the agent's tests" do
    it "ignores a new file that does not match the level's test pattern" do
      leased do |lease, checkout|
        File.write(File.join(checkout, "spec/unit/helper.rb"), "")
        seen = []
        grade = graded(lease, checkout, harness: scripted([], seen)).grade

        expect([grade.pass?, grade.why]).to eq([false, "the agent wrote no tests"])
        expect(seen).to be_empty
      end
    end

    [%(--pattern "**/*_spec.rb,**/*_check.rb"\n), "--pattern\n**/*_check.rb,**/*_x.rb\n",
     "--pattern=**/*_a.rb,**/*_check.rb\n"].each do |options|
      it "reads the pattern #{options.inspect} the way rspec does" do
        project_with(options) do |project|
          leased(project) do |lease, checkout|
            write_tests(checkout, weak)
            seen = []
            graded(lease, checkout, base: project, harness: scripted(Array.new(5, true), seen)).grade

            expect(seen.map { |run| run[:paths] }.uniq).to eq([["spec/unit/agent_check.rb"]])
          end
        end
      end
    end

    ["--pattern\n", "--pattern \"unclosed\n"].each do |options|
      it "fails loudly, naming it, when .rspec holds the unreadable #{options.inspect}" do
        project_with(options) do |project|
          leased(project) do |lease, checkout|
            write_tests(checkout, weak)

            expect { graded(lease, checkout, base: project).grade }
              .to raise_error(described_class::UnreadablePattern, /--pattern/)
          end
        end
      end
    end

    it "grades a test that requires a helper the agent added under spec/support on its merits" do
      leased do |lease, checkout|
        FileUtils.mkdir_p(File.join(checkout, "spec/support"))
        File.write(File.join(checkout, "spec/support/my_helper.rb"),
                   "def tally_with(*keys) = keys.each_with_object(Tally.new) { |k, t| t.add(k) }\n")
        write_tests(checkout, "require_relative \"../support/my_helper\"\n#{thorough}")

        expect(graded(lease, checkout).grade.score).to eq(1.0)
      end
    end

    it "does not copy an added symlink into the scratch trees" do
      leased do |lease, checkout|
        write_tests(checkout, weak)
        File.symlink("/etc/hostname", File.join(checkout, "spec/unit/link_check.rb"))
        seen = []
        graded(lease, checkout, harness: scripted([true] * 5, seen)).grade

        expect(seen.map { |run| run[:paths] }.uniq).to eq([["spec/unit/agent_check.rb"]])
        expect(seen.flat_map { |run| run[:entries] }).not_to include("spec/unit/link_check.rb")
      end
    end

    it "does not let an empty helper kill the grade of real tests beside it" do
      leased do |lease, checkout|
        write_tests(checkout, thorough)
        File.write(File.join(checkout, "spec/unit/helper.rb"), "")

        expect(graded(lease, checkout).grade.score).to eq(1.0)
      end
    end
  end

  describe "when the agent wrote no tests" do
    it "fails without running anything" do
      leased do |lease, checkout|
        seen = []
        grade = graded(lease, checkout, harness: scripted([], seen)).grade

        expect([grade.pass?, grade.why]).to eq([false, "the agent wrote no tests"])
        expect(seen).to be_empty
      end
    end
  end

  describe "the seal" do
    it "still raises Tampered when a pristine test file is edited" do
      leased do |lease, checkout|
        File.write(File.join(checkout, "spec/unit/tally_check.rb"), "# edited\n")

        expect { graded(lease, checkout).grade }
          .to raise_error(Lain::Grader::LeaseHarness::Tampered) { |e| expect(e.paths).to eq(["spec/unit/tally_check.rb"]) }
      end
    end

    it "still raises Tampered when a pristine test file is deleted" do
      leased do |lease, checkout|
        FileUtils.rm(File.join(checkout, "spec/unit/tally_check.rb"))

        expect { graded(lease, checkout).grade }.to raise_error(Lain::Grader::LeaseHarness::Tampered)
      end
    end

    it "still raises Tampered when a root file is added" do
      leased do |lease, checkout|
        write_tests(checkout, thorough)
        File.write(File.join(checkout, "Rakefile"), "\n")

        expect { graded(lease, checkout).grade }
          .to raise_error(Lain::Grader::LeaseHarness::Tampered) { |e| expect(e.paths).to eq(["Rakefile"]) }
      end
    end

    it "refuses a lease holding no checkout" do
      lease = Struct.new(:worker_env).new(nil)

      expect { described_class.new(lease:, level: level_in(subject_project), mutations:, base: subject_project).grade }
        .to raise_error(Lain::Grader::LeaseHarness::NoCheckout)
    end
  end

  describe "#identity" do
    it "names the class, the level, the seal and a digest of the mutation set" do
      leased do |lease, checkout|
        identity = graded(lease, checkout).identity

        expect(identity).to include("class" => "Lain::Grader::MutationReinsertion", "level" => "unit")
        expect(identity.keys).to include("sealed", "mutations")
        expect(Ractor.shareable?(identity)).to be(true)
      end
    end

    it "changes when the mutation set changes" do
      leased do |lease, checkout|
        fewer = described_class.new(lease:, level: level_in(checkout), mutations: mutations.drop(1),
                                    base: subject_project)

        expect(fewer.identity.fetch("mutations")).not_to eq(graded(lease, checkout).identity.fetch("mutations"))
      end
    end
  end
end
