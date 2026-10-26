# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Lain::CLI::Resume::Salvager do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:timeline) { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) }

  around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

  def session_file
    chronicle = Lain::CLI::Chronicle.for(enabled: true, paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @dir }),
                                         root: Dir.pwd)
    chronicle.start(context:, toolset:)
    chronicle.close
    chronicle.journal_path
  end

  describe "#close!" do
    it "continues the session file's chain from its previous last line" do
      path = session_file
      before = File.read(path).lines.last

      described_class.new(path:, timeline:).close!(head_before: nil)

      closing = JSON.parse(File.read(path).lines.last)
      expect(closing).to include("type" => "session_closed", "reason" => "salvaged",
                                 "prev" => Lain::Journal::Line.link(before))
    end

    # Two resumes of one dead session would each keep their own tip and fork the chain.
    it "refuses, naming the file, while another process holds the session file" do
      path = session_file
      holder = Lain::Journal.open(path, chain: true)

      expect { described_class.new(path:, timeline:).close!(head_before: nil) }
        .to raise_error(Lain::CLI::Resume::Refusal, /cannot resume #{File.basename(path)}: .*another process/)
    ensure
      holder&.close
    end
  end
end
