# frozen_string_literal: true

require "json"
require "tmpdir"
require "time"

# The one reader of the published state struct, and the one renderer of the HUD
# line every surface shows. Before this object there were three Ruby readers
# that each parsed the file (or the live feed), compared `cache_deadline`
# against a clock and drew their own glyph, plus two copies of a jq program that
# did the same in a shell -- and `cli/command/status.rb`'s own comment admitted
# the duplication rather than resolving it.
#
# Both halves are pure functions over a Hash, which is why every example here
# runs without a file, a tmux server or a jq binary. The file-reading half gets
# its own describe, because "absence is not an error" is the contract every
# caller leans on at a prompt.
RSpec.describe Lain::StatusFeed::Reading do
  let(:now) { Time.utc(2026, 9, 13, 12, 0, 0) }

  def reading(**state) = described_class.new(state.transform_keys(&:to_s))

  describe "warmth" do
    it "reports warm while the published deadline is still ahead of the clock" do
      expect(reading(cache_deadline: (now + 300).iso8601).warmth(now:)).to eq(:warm)
    end

    it "reports cold once the published deadline has passed" do
      expect(reading(cache_deadline: (now - 1).iso8601).warmth(now:)).to eq(:cold)
    end

    # Neither warm nor cold: nothing has published a deadline, and a caller that
    # renders "cold" for that is asserting a cache went stale when none was ever
    # written. Every caller distinguishes the two -- the prompt renders nothing,
    # `/status` says so in words.
    it "reports nothing at all when no deadline has been published" do
      expect(reading(fleet: []).warmth(now:)).to eq(:unpublished)
    end

    it "reports nothing rather than raising on a deadline that is not a timestamp" do
      expect(reading(cache_deadline: "half past").warmth(now:)).to eq(:unpublished)
    end
  end

  describe "reading a published file" do
    around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

    def path = File.join(@dir, "state.json")

    def written(body)
      File.write(path, body)
      described_class.at(path)
    end

    it "takes the struct a publish left on disk" do
      taken = written(JSON.generate({ "cache_deadline" => (now + 300).iso8601, "fleet" => %w[a b],
                                      "inbox_count" => 3 }))

      expect(taken.warmth(now:)).to eq(:warm)
      expect(taken.fleet_size).to eq(2)
      expect(taken.inbox_count).to eq(3)
    end

    it "reports nothing, and does not raise, when no file has been published" do
      taken = nil

      expect { taken = described_class.at(File.join(@dir, "never", "written.json")) }.not_to raise_error
      expect(taken.warmth(now:)).to eq(:unpublished)
      expect(taken.fleet_size).to eq(0)
    end

    it "reports nothing, and does not raise, on bytes that are not JSON" do
      expect { written("{half a jso") }.not_to raise_error
      expect(written("{half a jso").warmth(now:)).to eq(:unpublished)
    end

    # A syntactically valid file that is not a struct at all. Checked rather
    # than rescued: `["cache_deadline"]` on an Array raises TypeError and on
    # `null` raises NoMethodError, and two rescues for one wrong shape is a
    # guard wearing a handler's clothes.
    it "reports nothing on valid JSON that is not an object" do
      expect(written("[1, 2, 3]").warmth(now:)).to eq(:unpublished)
      expect(written("null").warmth(now:)).to eq(:unpublished)
    end
  end

  # The line the tmux status bar, `lain up`'s status-right and the editor plugin
  # all show. It is rendered HERE, once, and published as a field -- which is
  # what lets every one of those read a string instead of carrying a copy of the
  # derivation.
  describe "the HUD line" do
    def hud(**state) = reading(**state).hud(now:)

    def warm(**overrides)
      { cache_deadline: (now + 300).iso8601, fleet: %w[a b], inbox_count: 3 }.merge(overrides)
    end

    it "opens with the warm marker and names the fleet and the inbox" do
      expect(hud(**warm)).to eq("🔥 fleet:2 inbox:3 ")
    end

    it "opens with the cold marker once the deadline has passed" do
      expect(hud(**warm(cache_deadline: (now - 300).iso8601))).to eq("❄ fleet:2 inbox:3 ")
    end

    it "opens with the cold marker when nothing has published a deadline" do
      expect(hud(**warm(cache_deadline: nil))).to eq("❄ fleet:2 inbox:3 ")
    end

    it "names a parked approval and the context occupancy" do
      expect(hud(**warm(approvals_pending: 1, occupancy: 0.34))).to eq("🔥 fleet:2 inbox:3 approve:1 ctx:34% ")
    end

    # A state written before these fields existed (an older `lain`, or the
    # pre-first-turn publish where occupancy is genuinely absent) renders the
    # line it always did -- "approve:0 ctx:--" on every quiet chat is noise.
    it "says nothing about a segment whose key the state carries as nil" do
      expect(hud(**warm(approvals_pending: nil, occupancy: nil, run_tokens: nil, mode_lighter: nil)))
        .to eq("🔥 fleet:2 inbox:3 ")
    end

    it "says nothing about an approval queue that is empty, and does name an empty context" do
      expect(hud(**warm(approvals_pending: 0, occupancy: 0.0))).to eq("🔥 fleet:2 inbox:3 ctx:0% ")
    end

    # {Lain::ContextWindow.default} answers an unmatched model -- every Ollama
    # id -- with a conservative 8,192, so a real 32k local window publishes 4.0.
    # The published number stays honest; the bar is where nonsense gets trimmed,
    # because a pegged 100% reads as "full", which a human can act on.
    it "clamps the occupancy percentage at 100" do
      expect(hud(**warm(occupancy: 2.44))).to eq("🔥 fleet:2 inbox:3 ctx:100% ")
    end

    # A guessed window is a floor somebody picked, so a percentage divided by
    # it can read 61% on a context 15% full. The number stays; the mark says
    # nobody vouched for its denominator.
    it "marks an occupancy measured against a guessed window" do
      expect(hud(**warm(occupancy: 0.61, window_guessed: true))).to eq("🔥 fleet:2 inbox:3 ctx:~61% ")
    end

    it "leaves an occupancy against a vouched window unmarked" do
      expect(hud(**warm(occupancy: 0.61, window_guessed: false))).to eq("🔥 fleet:2 inbox:3 ctx:61% ")
    end

    it "names the run's token spend" do
      expect(hud(**warm(run_tokens: 27_997))).to eq("🔥 fleet:2 inbox:3 run:27997 ")
    end

    # A genuinely zero spend is a real reading, not an absence -- the same
    # distinction the occupancy segment draws, and only ABSENCE is silent. A
    # `positive?` guard here would read as "quiet until the first turn", which
    # is what a nil already says and what a measured zero must not.
    it "renders a zero spend, since only ABSENCE is silent" do
      expect(hud(**warm(run_tokens: 0))).to eq("🔥 fleet:2 inbox:3 run:0 ")
    end

    # The lighter arrives ALREADY COMPOSED (the posture's plus every active
    # layer's, empty under the silent default posture), so this renderer carries
    # no copy of the mode ladder.
    it "names the composed mode lighter, and nothing when it is empty" do
      expect(hud(**warm(mode_lighter: "MAN AA"))).to eq("🔥 fleet:2 inbox:3 MAN AA ")
      expect(hud(**warm(mode_lighter: ""))).to eq("🔥 fleet:2 inbox:3 ")
    end

    it "renders every optional segment in one line, in the published order" do
      expect(hud(**warm(approvals_pending: 2, occupancy: 0.5, run_tokens: 120, mode_lighter: "AUTO")))
        .to eq("🔥 fleet:2 inbox:3 approve:2 ctx:50% run:120 AUTO ")
    end

    # The trailing space is the LAST thing appended, whatever the optional
    # segments did, so the last segment never sits hard against the right edge
    # of a status bar.
    it "always ends with exactly one space" do
      expect(hud(**warm)).to end_with(" ")
      expect(hud(**warm)).not_to end_with("  ")
    end

    # {Lain::StatusFeed::ModeState} calls `mode_lighter` the first FREE-FORM
    # string this feed publishes -- a degradation path can put a foreign
    # journal's raw posture name in it -- so "the vocabulary is closed" is not
    # something this renderer may assume. tmux reads `#` as the start of its own
    # format syntax, and a `"` or a `\` ends the field early for the shell that
    # extracts it back out of the JSON. Every other segment is a count or a
    # clamped percentage and can carry none of the three.
    it "strips what a status bar and a shell extract cannot survive out of a free-form lighter" do
      expect(hud(**warm(mode_lighter: "ODD\"\\#NAME"))).to eq("🔥 fleet:2 inbox:3 ODDNAME ")
    end

    it "composes nothing a multiplexer would read as its own format syntax" do
      expect(hud(**warm(approvals_pending: 9, occupancy: 0.99, run_tokens: 1, mode_lighter: "a#b\"c")))
        .not_to include("#")
    end
  end

  # The live feed's own struct, read by the same object that reads the file --
  # `prompt_composer.rb`'s RunState takes these two and makes its own judgment
  # about the second, which stays there because a threshold is not a reading.
  describe "the fields a prompt reads" do
    it "counts an absent fleet as empty rather than raising" do
      expect(reading(inbox_count: 0).fleet_size).to eq(0)
    end

    it "reads a refusal streak, and a state written before the field as zero" do
      expect(reading(derivation_refusal_streak: 3).derivation_refusal_streak).to eq(3)
      expect(reading(fleet: []).derivation_refusal_streak).to eq(0)
    end
  end

  # The pane's header: the HUD line every surface shows, and the top of the
  # fleet tree under it. The pane holds nothing of the chat, so what it draws
  # it was told -- and this is where it is composed.
  describe "the input pane's header" do
    def row(role, depth: 0, turns: 0, state: "running", task: "", started: now)
      { "spawn" => "blake3:#{role}", "role" => role, "task" => task, "worker" => nil,
        "state" => state, "turns" => turns, "depth" => depth, "started" => started.utc.iso8601 }
    end

    it "is the HUD alone while nothing is running" do
      expect(reading(fleet: [], fleet_tree: []).header(now:)).to eq("\u2744 fleet:0 inbox:0 ")
    end

    it "draws each row under the HUD, indented by its depth" do
      tree = [row("dev", turns: 2, task: "port the parser", started: now - 90),
              row("test_engineer", depth: 1, task: "write the specs")]

      expect(reading(fleet_tree: tree).header(now:).lines.map(&:chomp).drop(1))
        .to eq(["  dev  running  2t  port the parser",
                "    test_engineer  running  0t  write the specs"])
    end

    # The header IS the frame the chat publishes, and a pane redraws on a
    # changed frame -- printing the header where the line editor left the
    # cursor. An age column would make the frame differ from itself once a
    # second, so a human at an untouched prompt would watch their pane
    # scroll. Measured in a real six-row pane: seven redraws in eight seconds.
    it "does not change with the clock alone, so an idle pane is not redrawn" do
      reading = reading(fleet_tree: [row("dev", task: "port the parser", started: now - 5)])

      expect(reading.header(now:)).to eq(reading.header(now: now + 90))
    end

    # The whole row, not the task alone: the indent and four columns are drawn
    # beside it, and 96 characters of CJK are 214 terminal columns. The lead
    # this header sets its tree in from counts too -- it is drawn, so a budget
    # that excused it would put the line two columns past the terminal's edge,
    # wrap it, and cost the pane the row the clamp exists to save.
    it "clamps a row, its lead included, to the terminal columns it is drawn in" do
      tree = [row("dev", task: "\u65E5\u672C\u8A9E" * 40)]

      drawn = reading(fleet_tree: tree).header(now:).lines.last.chomp

      expect(Lain::Ext::Prompt.width(drawn)).to be <= Lain::StatusFeed::Fleet::Row::COLUMNS
      expect(drawn).to end_with("\u2026")
    end

    # The header sits above a prompt a human is typing at, so it takes the top
    # of the tree and says what it left rather than pushing the prompt off.
    it "takes the top rows and says how many it left" do
      tree = Array.new(described_class::HEADER_ROWS + 3) { |index| row("r#{index}") }

      expect(reading(fleet_tree: tree).header(now:).lines.last.chomp).to eq("  +3 more")
    end

    # Fleet prunes the oldest ended rows, so the newest ended child is the last
    # one in the tree and a plain head-take would hide the failure a human needs.
    it "shows the newest ended children when nothing is running, and counts the rest" do
      tree = [row("old", state: "done", started: now - 30),
              row("mid", state: "done", started: now - 20),
              row("new", state: "failed", started: now - 10)]

      expect(reading(fleet_tree: tree).header(now:).lines.map(&:chomp).drop(1))
        .to eq(["  mid  done  0t", "  new  failed  0t", "  +1 more"])
    end

    it "puts running rows first and never shows a child without its parent" do
      tree = [row("lead", started: now - 40),
              row("worker", depth: 1, started: now - 35),
              row("sib_a", state: "done", started: now - 30),
              row("sib_b", state: "failed", started: now - 20)]

      expect(reading(fleet_tree: tree).header(now:).lines.map(&:chomp).drop(1))
        .to eq(["  lead  running  0t", "    worker  running  0t", "  +2 more"])
    end

    it "brings the parent of a shown child along, even when the parent has ended" do
      tree = [row("lead", state: "done", started: now - 40),
              row("worker", depth: 1, started: now - 35),
              row("other", state: "done", started: now - 30)]

      expect(reading(fleet_tree: tree).header(now:).lines.map(&:chomp).drop(1))
        .to eq(["  lead  done  0t", "    worker  running  0t", "  +1 more"])
    end

    # A state published before the field existed, and the one a --no-journal
    # run never writes at all, both read as no fleet rather than as a failure.
    it "is the HUD alone for a state that carries no tree" do
      expect(reading(fleet: ["blake3:a"]).header(now:)).to eq(reading(fleet: ["blake3:a"]).hud(now:))
    end
  end
end
