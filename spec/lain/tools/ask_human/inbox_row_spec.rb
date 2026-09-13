# frozen_string_literal: true

require "pastel"
require "stringio"

# One pending question as either inbox surface lists it.
#
# The cross-surface example at the bottom is why this object exists. The
# terminal drain and the editor view each carried their own copy of the age
# arithmetic, so nothing held the two to one answer about one question -- and
# an age read off a clock is exactly the value two independent implementations
# drift on. Both surfaces are driven for real here, from ONE instant, because
# the agreement is the claim and a doubled row would assume it.
RSpec.describe Lain::Tools::AskHuman::InboxRow do
  def row(from: "orchestrator", summary: "which db?", asked_at: Time.at(1_000), now: Time.at(1_000))
    described_class.at(from:, summary:, asked_at:, now:)
  end

  describe ".at" do
    it "names a ninety-second-old question in whole minutes" do
      expect(row(now: Time.at(1_090)).age).to eq("1m")
    end

    it "counts seconds under the minute and hours past the hour" do
      expect(row(now: Time.at(1_059)).age).to eq("59s")
      expect(row(now: Time.at(4_600)).age).to eq("1h")
    end

    # An age can go BACKWARDS: `asked_at` is an observation time and the
    # instant handed in is a later read of a clock that is not monotonic, so an
    # NTP step or a suspend renders `-5s`. The runtime's own row pattern
    # matches a leading `-` for this, so rendering the negative is what keeps
    # the item answerable.
    it "renders a clock that stepped backwards rather than hiding it" do
      expect(row(now: Time.at(995)).age).to eq("-5s")
    end

    it "clamps a forty-character sender to the one column width" do
      clamped = row(from: "a" * 40)

      expect(clamped.from).to eq("a" * 19)
    end

    it "scrubs a line break out of the sender before the clamp measures it" do
      expect(row(from: "two\nlines").from).to eq("two lines")
    end
  end

  describe "#to_s" do
    it "draws sender, age and summary in one two-space-separated line" do
      expect(row(now: Time.at(1_090)).to_s).to eq("orchestrator  1m  which db?")
    end

    # A row a record naming NOBODY draws: the two spaces the sender's column
    # would have left are what the editor reads as a continuation line, so the
    # row would fold into the item above it.
    it "opens on the age when nothing named a sender" do
      expect(row(from: "").to_s).to eq("0s  which db?")
    end

    it "renders a question whose text spans lines as one row" do
      drawn = row(summary: "which db?\nand which region?")

      expect(drawn.to_s.lines.size).to eq(1)
      expect(drawn.to_s).to eq("orchestrator  0s  which db? and which region?")
    end

    # The column a surface decorates is its own; the layout is not. Handed a
    # painter, the row still joins the same fields in the same order, so a
    # coloured terminal line and a plain editor line differ by escape codes
    # alone.
    it "hands each column to a painter that wants to decorate one" do
      painted = row(now: Time.at(1_090)).drawn { |column, text| column == :age ? "[#{text}]" : text }

      expect(painted).to eq("orchestrator  [1m]  which db?")
    end
  end

  # THE HEADLINE. Both real surfaces, one question, one instant.
  describe "the terminal drain and the editor view" do
    let(:asked_at) { Time.at(910) }
    let(:now) { Time.at(1_000) }

    def age_in(line) = line[/(?<=\s)-?\d+[smh](?=\s)/]

    def terminal_line
      output = StringIO.new
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                                    pastel: Pastel.new(enabled: false), wall_clock: -> { now })
      item = Struct.new(:question, :from, :asked_at).new("which db?", "orchestrator", asked_at)
      tty.drain_inbox([item], reader: ->(_prompt) { "" }) { |_answer| raise "must not yield" }
      output.string.lines.first.chomp
    end

    def editor_line
      instant = asked_at
      view = Lain::Frontend::Neovim::InboxView.new(store: Lain::Store.new, clock: -> { instant })
      view.update(question_record("blake3:q1"))
      instant = now
      view.update(question_record("blake3:q2", question: "unrelated?")).first
    end

    def question_record(digest, from: "orchestrator", question: "which db?")
      Lain::Telemetry::Message.new(digest:, kind: :message, from:, to: "human",
                                   payload: { "question" => question }, causal_parents: [], correlation: nil)
    end

    it "name the same age for the same question at the same instant" do
      expect(age_in(terminal_line)).to eq(age_in(editor_line)).and eq("1m")
    end

    it "draw the same row, the terminal's colour aside" do
      expect(terminal_line).to eq(editor_line)
    end
  end
end
