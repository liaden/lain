# frozen_string_literal: true

require "json"

RSpec.describe Lain::Shell::Executable do
  describe ".unresolved" do
    subject(:executable) { described_class.unresolved(+"cat", anomalies: [:ld_preload]) }

    it "names the program and knows nothing else about it" do
      expect(executable).to have_attributes(name: "cat", resolved: nil, realpath: nil, chain: [], shadowed: [],
                                            anomalies: [:ld_preload], klass: :unresolved, fresh: false,
                                            run_files: [], wrappers: [], skipped: [])
    end

    it "is Ractor-shareable" do
      expect(executable).to be_deeply_frozen
    end
  end

  describe "#to_journal" do
    it "is JSON-safe, with each wrapper journalled the same way" do
      wrapper = described_class.unresolved("nice", anomalies: [:ld_preload])
      executable = described_class.new(name: "cat", resolved: "/usr/bin/cat", realpath: "/usr/bin/cat",
                                       chain: ["/usr/bin/cat"], shadowed: [], anomalies: [:empty_path_entry],
                                       klass: :system, fresh: false, run_files: [], wrappers: [wrapper],
                                       skipped: ["/home/u/noexec/cat"])

      expect(executable.to_journal).to eq(
        "name" => "cat", "resolved" => "/usr/bin/cat", "realpath" => "/usr/bin/cat", "chain" => ["/usr/bin/cat"],
        "shadowed" => [], "anomalies" => ["empty_path_entry"], "klass" => "system", "fresh" => false,
        "run_files" => [], "wrappers" => [wrapper.to_journal], "skipped" => ["/home/u/noexec/cat"]
      )
      expect(JSON.parse(JSON.generate(executable.to_journal))).to eq(executable.to_journal)
    end
  end

  describe "#programs" do
    it "lists every wrapper that runs it, outermost first, then itself" do
      inner = described_class.unresolved("ruby", wrappers: [described_class.unresolved("bundle")])
      outer = described_class.unresolved("nice")
      executable = described_class.unresolved("x", wrappers: [outer, inner])

      expect(executable.programs.map(&:name)).to eq(%w[nice bundle ruby x])
    end
  end

  describe ".bar" do
    def stage(klass, name: "x", fresh: false, anomalies: [], run_files: [], wrappers: [])
      path = klass == :unresolved ? nil : "/somewhere/#{klass}/bin/#{name}"
      described_class.new(name:, resolved: path, realpath: path, chain: [], shadowed: [], anomalies:, klass:,
                          fresh:, run_files:, wrappers:)
    end

    def run_file(klass, fresh: false) = Lain::Shell::Executable::RunFiles::Entry.new(path: "/p/script", klass:, fresh:)

    it "names nothing for a call whose every stage is system" do
      expect(described_class.bar([stage(:system), stage(:system)])).to eq([])
    end

    it "names nothing for an unchanged user or project stage with unchanged run files" do
      expect(described_class.bar([stage(:user), stage(:project, run_files: [run_file(:project)])])).to eq([])
    end

    it "names nothing for a call with no stage, since there is nothing to bar" do
      expect(described_class.bar([])).to eq([])
    end

    it "bars a stage written this session" do
      expect(described_class.bar([stage(:system), stage(:project, fresh: true)]))
        .to eq(["x -> /somewhere/project/bin/x: written this session"])
    end

    it "bars a run file written this session" do
      expect(described_class.bar([stage(:system, run_files: [run_file(:project, fresh: true)])]))
        .to eq(["x runs /p/script: written this session"])
    end

    it "bars an unresolved run file" do
      expect(described_class.bar([stage(:system, run_files: [run_file(:unresolved)])]))
        .to eq(["x runs /p/script: not resolved"])
    end

    it "bars an unresolved stage" do
      expect(described_class.bar([stage(:system), described_class.unresolved("x")])).to eq(["x: not resolved"])
    end

    it "bars a PATH or env anomaly on any stage" do
      expect(described_class.bar([stage(:system, anomalies: [:project_path_entry])]))
        .to eq(["PATH has an entry inside the project"])
    end

    it "bars a wrapper the stage runs under as surely as the stage" do
      expect(described_class.bar([stage(:system, wrappers: [stage(:project, name: "nice", fresh: true)])]))
        .to eq(["nice -> /somewhere/project/bin/nice: written this session"])
    end

    it "reads each stage's class and freshness, not its name: a planted-sounding name that resolved clean passes" do
      expect(described_class.bar([stage(:system, name: "bin/cat [project; written this session]")])).to eq([])
    end

    it "names why each stage, run file and wrapper is barred, and an anomaly once" do
      script = Lain::Shell::Executable::RunFiles::Entry.new(path: "/p/x.rb", klass: :project, fresh: true)
      stages = [stage(:project, name: "cat", fresh: true, anomalies: [:ld_preload]),
                stage(:system, name: "ruby", run_files: [script], anomalies: [:ld_preload]),
                stage(:system, name: "head", wrappers: [described_class.unresolved("nohup")])]

      expect(described_class.bar(stages)).to eq(["cat -> /somewhere/project/bin/cat: written this session",
                                                 "LD_PRELOAD is set", "ruby runs /p/x.rb: written this session",
                                                 "nohup: not resolved"])
    end
  end

  it "deep-freezes what it is built from, so a resolved Executable is Ractor-shareable" do
    wrapper = described_class.unresolved(+"nice")
    executable = described_class.new(name: +"cat", resolved: +"/usr/bin/cat", realpath: +"/usr/bin/cat",
                                     chain: [+"/usr/bin/cat"], shadowed: [+"/bin/cat"], anomalies: [],
                                     klass: :system, fresh: false, run_files: [], wrappers: [wrapper])

    expect(executable).to be_deeply_frozen
  end
end
