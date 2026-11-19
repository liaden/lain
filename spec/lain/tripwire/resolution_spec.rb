# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Tripwire::Resolution do
  around do |example|
    Dir.mktmpdir("resolution") do |dir|
      @base = File.realpath(dir)
      example.run
    end
  end

  let(:root) { File.join(@base, "p") }
  let(:execs) { Lain::Confine::ExecRules.project(root) }

  def written(path) = path.tap { FileUtils.mkdir_p(File.dirname(_1)) }.tap { File.write(_1, "") }

  def stage(*run_files)
    { "name" => "python3", "resolved" => "/usr/bin/python3", "realpath" => "/usr/bin/python3", "chain" => [],
      "klass" => "system", "fresh" => false,
      "run_files" => run_files.map { { "path" => _1, "klass" => "project", "fresh" => true } } }
  end

  def signals(resolution)
    Lain::Tripwire::Hit.of_resolution({ "tool_use_id" => "tu_1" }, resolution).to_h { [_1.name, _1.detail] }
  end

  describe "#ran?" do
    let(:rails) { written(File.join(root, "bin/rails")) }

    def parsed(cwd)
      { "name" => "bin/rails", "resolved" => rails, "realpath" => rails, "chain" => [], "klass" => "project",
        "fresh" => false, "run_files" => [], "basis" => "parsed", "cwd" => cwd }
    end

    it "reads a relative exec path from the cwd its stage resolved in, as the trace records it" do
      expect(described_class.new([parsed(root)]).ran?("bin/rails")).to be(true)
    end

    it "matches no relative path for a stage that may run somewhere else, not even from the process's cwd" do
      rails
      Dir.chdir(root) { expect(described_class.new([parsed(nil)]).ran?("bin/rails")).to be(false) }
    end

    it "matches no relative path that lands elsewhere from that cwd" do
      expect(described_class.new([parsed(File.join(root, "sub"))]).ran?("bin/rails")).to be(false)
    end
  end

  describe "a fresh run file under the project's build output" do
    let(:built) { written(File.join(root, ".venv/bin/pytest")) }
    let(:planted) { written(File.join(root, "plant.py")) }

    it "records no fresh_run_file for what a named exec rule holds" do
      expect(signals(described_class.new([stage(built)], execs:))).to be_empty
    end

    it "still records every other fresh run file" do
      expect(signals(described_class.new([stage(built, planted)], execs:))).to eq("fresh_run_file" => [planted])
    end

    it "excuses nothing when no rule is named" do
      expect(signals(described_class.new([stage(built)]))).to eq("fresh_run_file" => [built])
    end

    it "still records a link under the build output to a file outside it" do
      far = written(File.join(@base, "elsewhere/far.py"))
      link = File.join(root, ".venv/bin/link.py").tap { FileUtils.mkdir_p(File.dirname(_1)) }
      File.symlink(far, link)

      expect(signals(described_class.new([stage(link)], execs:))).to eq("fresh_run_file" => [link])
    end

    it "still records a link spelled outside the build output that lands inside it" do
      inside = written(File.join(root, "target/x.py"))
      link = File.join(root, "run.py")
      File.symlink(inside, link)

      expect(signals(described_class.new([stage(link)], execs:))).to eq("fresh_run_file" => [link])
    end

    it "still records a run file under the build output that no longer resolves" do
      gone = File.join(root, ".venv/bin/gone.py")

      expect(signals(described_class.new([stage(gone)], execs:))).to eq("fresh_run_file" => [gone])
    end
  end
end
