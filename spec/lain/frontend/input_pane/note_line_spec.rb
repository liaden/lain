# frozen_string_literal: true

RSpec.describe Lain::Frontend::InputPane::NoteLine do
  subject(:line) { described_class.new(tty:, view:) }

  let(:tty) do
    Class.new do
      attr_reader :out

      def initialize = @out = []
      def print_prompt(text) = @out << text
      def render_note(text) = @out << "note:#{text}"
      def render_held(text) = @out << "held:#{text}"
      def render_human_note(text) = @out << "human:#{text}"
    end.new
  end
  let(:draft) { Struct.new(:shown) { def rows(_columns) = 1 }.new("abc") }
  let(:view) { -> { ["fleet:1", draft, 80] if drawn } }
  let(:drawn) { true }

  describe "#say" do
    it "takes back the header and draft, says the note, and draws both again beneath it" do
      line.say("dropped 1 held line")

      expect(tty.out).to eq(["\e[1A\r\e[J", "note:dropped 1 held line", "\r\e[Kfleet:1\nabc"])
    end

    it "says a held or human note through the terminal call for its kind" do
      line.say("ls", "held")
      line.say("hi", "human")

      expect(tty.out.grep(/\A(held|human):/)).to eq(%w[held:ls human:hi])
    end

    it "walks up every row a wrapped draft covers" do
      draft.define_singleton_method(:rows) { |_columns| 3 }
      line.say("x")

      expect(tty.out.first).to eq("\e[3A\r\e[J")
    end

    context "when no header and draft are drawn" do
      let(:drawn) { false }

      it "only says the note" do
        line.say("dropped 1 held line")

        expect(tty.out).to eq(["note:dropped 1 held line"])
      end
    end
  end

  describe "#redraw" do
    it "replaces the header in one write and answers its row count" do
      rows = line.redraw("fleet:2\nrow b")

      expect([tty.out, rows]).to eq([["\e[1A\r\e[J\r\e[Kfleet:2\nrow b\nabc"], 2])
    end
  end
end
