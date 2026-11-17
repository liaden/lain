# frozen_string_literal: true

RSpec.describe Lain::CLI::Wiring::InputProducer do
  # The fleet tree is read through lain://status and lain watch; the pane's
  # header is the HUD line alone, so a child starting or ending never changes
  # its row count.
  describe "the input pane's header" do
    let(:running) do
      Array.new(3) do |index|
        { "spawn" => "blake3:c#{index}", "role" => "dev", "task" => "port the parser", "state" => "running",
          "turns" => 1, "depth" => 0, "started" => "2026-09-20T12:00:00Z" }
      end
    end

    it "is 1 line holding the HUD and the fleet count, naming no child, while children run" do
      state = { "fleet" => %w[a b c], "fleet_tree" => running, "inbox_count" => 0 }
      header = described_class.new(human: nil, attended: true, cockpit: nil, pending: nil, stdin: nil, notes: nil,
                                   paths: Lain::Paths.new, root: "/work", switchboard: nil, commands: -> { [] },
                                   status_feed: instance_double(Lain::StatusFeed, state:)).hud_line

      expect(header.lines.size).to eq(1)
      expect(header).to include("fleet:3").and(satisfy { |line| !line.include?("dev") })
    end

    it "ends with the review count the poll wrote" do
      Dir.mktmpdir do |home|
        paths = Lain::Paths.new(env: { "HOME" => home, "XDG_STATE_HOME" => File.join(home, "state") })
        FileUtils.mkdir_p(File.dirname(paths.review_counts))
        File.write(paths.review_counts, JSON.generate("hud" => "rv 3+1", "stale" => true))
        state = { "fleet" => [], "inbox_count" => 0 }
        header = described_class.new(human: nil, attended: true, cockpit: false, pending: nil, stdin: nil, notes: nil,
                                     paths:, root: "/work", switchboard: nil, commands: -> { [] },
                                     status_feed: instance_double(Lain::StatusFeed, state:)).hud_line

        expect(header).to end_with(" rv 3+1?")
      end
    end
  end
end
