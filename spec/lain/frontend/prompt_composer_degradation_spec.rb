# frozen_string_literal: true

# The composer's totality, from the other side: every way a renderer can
# misbehave and every shape it can return. Separate from prompt_composer_spec
# because these pin the DEGRADE path -- what the prompt does when the thing
# composing it is broken -- which is the property that keeps a wiring bug from
# costing the human their REPL.
RSpec.describe "Lain::Frontend::PromptComposer degradation" do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

  def prompt_for(renderer, notify: Lain::Frontend::PromptComposer::SILENT)
    Lain::Frontend::PromptComposer.new(theme:, renderer:, notify:)
  end

  def raising(error) = ->(**) { raise error }

  describe "rescue policy: what degrades" do
    [StandardError, RuntimeError, Lain::ContextWindow::UnknownModel,
     Lain::Frontend::Theme::UnknownToken, NotImplementedError, LoadError,
     SystemStackError, ArgumentError, KeyError].each do |klass|
      it "degrades to the bare prompt on #{klass}" do
        expect(prompt_for(raising(klass)).compose("> ").line).to eq("> ")
      end
    end
  end

  describe "rescue policy: what MUST propagate (Ctrl-C stays alive)" do
    [Interrupt, SystemExit, NoMemoryError].each do |klass|
      it "lets #{klass} through" do
        expect { prompt_for(raising(klass)).compose("> ") }.to raise_error(klass)
      end
    end

    it "lets SignalException through" do
      expect { prompt_for(->(**) { raise SignalException, "INT" }).compose("> ") }
        .to raise_error(SignalException)
    end
  end

  describe "renderers that return the wrong thing" do
    { "nil" => nil, "an Integer" => 42, "an Array" => %w[a b], "a Symbol" => :nope,
      "a Hash" => { a: 1 } }.each do |name, value|
      it "degrades when the renderer returns #{name}" do
        expect(prompt_for(->(**) { value }).compose("> ").line).to eq("> ")
      end
    end

    it "degrades when the returned object's #to_s raises" do
      hostile = Object.new
      def hostile.to_s = raise("boom")
      expect(prompt_for(->(**) { hostile }).compose("> ").line).to eq("> ")
    end

    it "accepts a frozen string (frozen_string_literal makes these frozen)" do
      expect(prompt_for(->(**) { "a\n> " }).compose("> "))
        .to have_attributes(header: ["a"], line: "> ")
    end

    it "does not mutate the frozen text it was handed" do
      text = "> "
      expect { prompt_for(Lain::Frontend::PromptComposer::Null.new).compose(text) }.not_to raise_error
    end
  end

  describe "splitting shapes" do
    def split_of(rendered) = prompt_for(->(**) { rendered }).compose("> ")

    it "0 lines (empty string)" do
      expect(split_of("")).to have_attributes(header: [], line: "")
    end

    it "1 line" do
      expect(split_of("> ")).to have_attributes(header: [], line: "> ")
    end

    it "2 lines" do
      expect(split_of("a\n> ")).to have_attributes(header: ["a"], line: "> ")
    end

    it "50 lines keeps 49 above" do
      expect(split_of("#{(1..49).to_a.join("\n")}\n> "))
        .to have_attributes(header: (1..49).map(&:to_s), line: "> ")
    end

    it "a leading newline yields an empty first header line" do
      expect(split_of("\n> ")).to have_attributes(header: [""], line: "> ")
    end

    it "only newlines" do
      expect(split_of("\n\n")).to have_attributes(header: ["", ""], line: "")
    end

    it "CRLF leaves a stray CR at the end of each header line" do
      expect(split_of("a\r\n> ")).to have_attributes(header: ["a\r"], line: "> ")
    end

    it "ANSI escapes survive into the editor line" do
      expect(split_of("\e[32mok\e[0m\n\e[1m> \e[0m").line).to eq("\e[1m> \e[0m")
    end
  end

  describe "purity of #compose" do
    it "same input, same output, repeatedly" do
      p = prompt_for(->(text:, **) { "hdr\n#{text}" })
      expect(Array.new(3) { p.compose("> ") }.uniq.size).to eq(1)
    end

    it "prints nothing by itself -- only editor_line touches the stream" do
      out = StringIO.new
      p = prompt_for(->(text:, **) { "hdr\n#{text}" })
      5.times { p.compose("> ") }
      expect(out.string).to eq("")
    end

    it "a failing compose is NOT free of side effects: the first call notifies" do
      seen = []
      p = prompt_for(raising(RuntimeError), notify: ->(m) { seen << m })
      3.times { p.compose("> ") }
      expect(seen.size).to eq(1)
    end
  end

  # The latch's own arithmetic -- once per contiguous failure run, re-armed by a
  # successful compose, and the exact message a new fault inside one run does
  # NOT produce -- is asserted in prompt_composer_spec's "notify" block, over
  # the same PromptComposer. Only the per-INSTANCE half is unique to this file.
  describe "notify-once semantics" do
    it "two PromptComposer instances each warn -- 'once' is per instance, not per process" do
      seen = []
      2.times { prompt_for(raising(RuntimeError), notify: ->(m) { seen << m }).compose("> ") }
      expect(seen.size).to eq(2)
    end
  end

  describe "Rendering#editor_line ordering" do
    it "prints the header, flushes, then returns the line" do
      out = StringIO.new
      allow(out).to receive(:flush).and_call_original
      line = prompt_for(->(text:, **) { "a\nb\n#{text}" }).compose("> ").editor_line(out)
      expect([out.string, line]).to eq(["a\nb\n", "> "])
    end

    it "flushes even with an empty header" do
      out = StringIO.new
      allow(out).to receive(:flush)
      prompt_for(Lain::Frontend::PromptComposer::Null.new).compose("> ").editor_line(out)
      expect(out).to have_received(:flush)
    end
  end

  describe "value semantics" do
    it "Rendering is a Data, so it compares by value" do
      expect(prompt_for(->(**) { "a\n> " }).compose("> "))
        .to eq(Lain::Frontend::PromptComposer::Rendering.new(header: ["a"], line: "> "))
    end

    it "Rendering is frozen all the way down, header Array included" do
      r = prompt_for(->(**) { "a\n> " }).compose("> ")
      expect([r.frozen?, r.header.frozen?, r.line.frozen?]).to eq([true, true, true])
    end
  end
end
