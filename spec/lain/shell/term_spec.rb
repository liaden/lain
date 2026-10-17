# frozen_string_literal: true

require "json"

RSpec.describe Lain::Shell::Term do
  let(:term) { described_class.of(%w[grep -n foo lib/a.rb], %w[head -3]) }

  describe ".of" do
    it "builds one pipeline whose stages are the argvs in order, discarding nothing" do
      expect(term.pipelines.size).to eq(1)
      expect(term.stages.map(&:argv)).to eq([%w[grep -n foo lib/a.rb], %w[head -3]])
      expect(term.stages.map(&:discards)).to all(be_empty)
    end
  end

  describe "#stages" do
    it "reads every pipeline's stages in order" do
      second = described_class::Pipeline.new(stages: [described_class::Stage.new(argv: %w[pwd], discards: [])])
      sequence = described_class.new(pipelines: [*term.pipelines, second])

      expect(sequence.stages.map(&:argv)).to eq([%w[grep -n foo lib/a.rb], %w[head -3], %w[pwd]])
    end
  end

  describe "#words" do
    it "is every word of every stage, programs included" do
      expect(term.words).to eq(%w[grep -n foo lib/a.rb head -3])
    end
  end

  describe "#programs" do
    it "is each stage's first word, as written" do
      expect(described_class.of(%w[/bin/cat a], %w[wc -l]).programs).to eq(%w[/bin/cat wc])
    end
  end

  describe "NONE" do
    it "is empty, with no stages and no words" do
      expect(described_class::NONE).to be_empty
      expect(described_class::NONE.stages).to eq([])
      expect(described_class::NONE.words).to eq([])
    end

    it "is the verdict's term for a command it did not allow" do
      expect(Lain::Shell::Verdict::NO_TERM).to be(described_class::NONE)
    end
  end

  describe "#empty?" do
    it "is false for a term with a stage" do
      expect(term).not_to be_empty
    end
  end

  it "is deeply frozen, even when built from mutable Strings and Arrays" do
    built = described_class.of([+"ls", +"-la"])
    expect(built).to be_deeply_frozen
    expect(described_class::NONE).to be_deeply_frozen
  end

  describe described_class::Stage do
    it "keeps the streams it discards" do
      stage = described_class.new(argv: %w[ls missing], discards: %i[stderr])
      expect(stage.discards).to eq(%i[stderr])
    end

    it "refuses a stream it does not know, rather than ignoring it" do
      expect { described_class.new(argv: %w[ls], discards: %i[stdin]) }
        .to raise_error(ArgumentError, /stdin/)
    end

    it "refuses an argv that is not an Array, rather than reading a String as its characters" do
      expect { described_class.new(argv: "ls -la", discards: []) }
        .to raise_error(ArgumentError, /argv must be an Array/)
    end

    it "refuses a word that is not a String, which Open3 would read as spawn options" do
      expect { described_class.new(argv: ["ls", { chdir: "/" }], discards: []) }
        .to raise_error(ArgumentError, /String/)
    end
  end

  describe described_class::Pipeline do
    it "refuses a stage that is not a Stage" do
      expect { described_class.new(stages: [%w[ls -la]]) }
        .to raise_error(ArgumentError, /stages must be Term::Stage/)
    end
  end

  it "refuses a pipeline that is not a Pipeline" do
    expect { described_class.new(pipelines: [[%w[ls -la]]]) }
      .to raise_error(ArgumentError, /pipelines must be Term::Pipeline/)
  end

  describe "the shell_arm journal shape" do
    it "names each pipeline's stages, with argv and discards" do
      quiet = described_class::Stage.new(argv: %w[ls missing], discards: %i[stderr])
      written = described_class.new(pipelines: [described_class::Pipeline.new(stages: [quiet, *term.stages])])

      expect(written.to_journal).to eq(
        "pipelines" => [[{ "argv" => %w[ls missing], "discards" => %w[stderr] },
                         { "argv" => %w[grep -n foo lib/a.rb], "discards" => [] },
                         { "argv" => %w[head -3], "discards" => [] }]]
      )
    end

    it "reads back from a parsed journal line into an equal, shareable term" do
      stage = described_class::Stage.new(argv: %w[ls missing], discards: %i[stderr])
      written = described_class.new(pipelines: [described_class::Pipeline.new(stages: [stage])])
      line = JSON.parse(JSON.generate(written.to_journal))

      expect(described_class.from_journal(line)).to eq(written)
      expect(described_class.from_journal(line)).to be_deeply_frozen
    end

    it "reads an empty journal shape back as NONE itself" do
      expect(described_class.from_journal({ "pipelines" => [] })).to be(described_class::NONE)
    end
  end
end
