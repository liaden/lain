# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Bench::FaultCorpus do
  let(:fixture_dir) { File.expand_path("../../fixtures/grader/faults", __dir__) }
  let(:corpus) { described_class.load(fixture_dir) }
  let(:grader) { Lain::Bench::CLI.const_get(:SuiteGrader).new(corpus.tasks) }

  describe ".load" do
    it "reads the 3 fault classes with their expected verdicts" do
      expect(corpus.faults.to_h { [_1.klass, _1.expected] })
        .to eq("cheatable" => :fail, "unstated_rule" => :pass, "ambiguous_prompt" => :pass)
    end

    it "keeps each planted trajectory as the files it writes" do
      expect(corpus.faults.first.trajectory.files.keys).to eq(["lib/pricing.rb"])
    end

    it "refuses a fault directory missing its expected verdict, naming the directory" do
      Dir.mktmpdir("lain-faults") do |dir|
        FileUtils.cp_r(Dir[File.join(fixture_dir, "*")], dir)
        FileUtils.rm(File.join(dir, "unstated_rule", "expected"))

        expect { described_class.load(dir) }
          .to raise_error(described_class::MalformedFault, /unstated_rule.*expected/)
      end
    end

    it "refuses a verdict that is neither pass nor fail" do
      Dir.mktmpdir("lain-faults") do |dir|
        FileUtils.cp_r(Dir[File.join(fixture_dir, "*")], dir)
        File.write(File.join(dir, "cheatable", "expected"), "maybe\n")

        expect { described_class.load(dir) }.to raise_error(described_class::MalformedFault, /cheatable.*maybe/)
      end
    end

    it "refuses a corpus missing a fault class" do
      Dir.mktmpdir("lain-faults") do |dir|
        expect { described_class.load(dir) }.to raise_error(described_class::MalformedFault, /cheatable/)
      end
    end
  end

  describe "#report" do
    subject(:report) { corpus.report(grader:) }

    it "shows expected, observed and agree? for every class" do
      expect(report).to include("class", "expected", "observed", "agree?")
                    .and match(/^cheatable\s+fail\s+pass\s+no/)
                    .and match(/^unstated_rule\s+pass\s+fail\s+no/)
    end

    it "reads 'cheat passed' and marks the gold check cheatable when the grader passes the cheat" do
      expect(report).to match(/cheatable.*cheat passed.*gold check is cheatable/)
    end

    it "says in each disagreeing row what the disagreement means" do
      expect(report).to match(/^unstated_rule .*no\s+gold rejects a correct answer$/)
        .and match(/^ambiguous_prompt .*no\s+gold rejects a correct answer$/)
    end

    it "splits the totals line by what the disagreements mean" do
      expect(report).to include("3 faults: 1 grader fooled, 2 gold too strict")
    end

    it "counts agreement when the grader returns the expected verdict" do
      Dir.mktmpdir("lain-faults") do |dir|
        FileUtils.cp_r(Dir[File.join(fixture_dir, "*")], dir)
        File.write(File.join(dir, "cheatable", "expected"), "pass\n")
        agreeing = described_class.load(dir)

        expect(agreeing.report(grader: Lain::Bench::CLI.const_get(:SuiteGrader).new(agreeing.tasks)))
          .to include("3 faults: 0 grader fooled, 2 gold too strict").and match(/^cheatable\s+pass\s+pass\s+yes\s*$/)
      end
    end
  end
end
