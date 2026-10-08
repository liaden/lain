# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Help do
  let(:registry) { Lain::CLI::Command::Registry.new([Lain::CLI::Command::Quit.new]) }
  let(:catalog) do
    Lain::Skill::Catalog.new(
      { brew: Lain::Skill.new(name: "brew", description: "steep the pot", scaffold: "scaffold") }
    )
  end
  let(:help) { described_class.new(registry:, catalog:) }
  let(:env) { instance_double(Lain::CLI::Command::Env) }

  before { registry.register(help) }

  it "lists every registered command with its one-line description" do
    text = help.call("", env).text

    expect(text).to include("/quit", "end the session")
    expect(text).to include("/help", "list commands and skills")
  end

  it "lists the catalog's skills beside the commands" do
    expect(help.call("", env).text).to include("/brew", "steep the pot")
  end

  it "sees a command registered after it was built -- the registry reference is live" do
    late = Struct.new(:name) do
      def usage = "/#{name} -- landed by a later card"

      def call(_args, _env) = ""
    end
    registry.register(late.new("status"))

    expect(help.call("", env).text).to match(%r{/status\s+landed by a later card})
  end

  it "renders an honest empty skills section" do
    bare = described_class.new(registry:, catalog: Lain::Skill::Catalog.new({}))

    expect(bare.call("", env).text).to include("(none)")
  end

  it "returns a renderable and never prints" do
    rendered = nil
    sized = described_class.new(registry:, catalog:, width: -> { 80 })
    expect { rendered = sized.call("", env) }.not_to output.to_stdout

    expect(rendered).to be_a(Lain::Renderable)
  end

  describe "the renderable it answers" do
    it "names its section headers with a bold token, not dim" do
      headers = help.call("", env).select { |segment| segment.token == :heading }.map(&:text)

      expect(headers).to eq(["commands:", "skills:"])
      expect(Lain::Frontend::Theme::DEFAULT_TOKENS[:heading]).to include(:bold)
    end

    it "renders more than one token -- the listing is never one flat colour" do
      expect(help.call("", env).map(&:token).uniq.size).to be > 2
    end

    it "keeps the section order, commands above skills" do
      expect(help.call("", env).text).to match(/\Acommands:\n.*\n\nskills:\n/m)
    end
  end

  describe "the columns" do
    let(:registry) { Lain::CLI::Command::Registry.new([]) }
    let(:catalog) { Lain::Skill::Catalog.new({}) }
    let(:help) { described_class.new(registry:, catalog:, width: -> { 60 }) }

    def command(name, description)
      Struct.new(:name, :usage) do
        def call(_args, _env) = ""
      end.new(name, "/#{name} -- #{description}")
    end

    it "starts every description at the same column" do
      [command("a", "alpha"), command("midlen", "beta"), command("muchlongername", "gamma")]
        .each { |entry| registry.register(entry) }
      lines = help.call("", env).text.lines.grep(/alpha|beta|gamma/)

      expect(lines.map { |line| line.index(/alpha|beta|gamma/) }.uniq.size).to eq(1)
    end

    it "wraps a long description under its own column within the width" do
      registry.register(command("tool", "word " * 24))
      lines = help.call("", env).text.lines.map(&:chomp).drop_while { |line| !line.include?("/tool") }
                  .take_while { |line| !line.empty? }
      padding = " " * lines.first.index("word")

      expect(lines.size).to be > 1
      expect(lines).to all(satisfy { |line| line.length <= 60 })
      expect(lines.drop(1)).to all(start_with("#{padding}word"))
    end

    it "puts the description under a name too long for the column" do
      registry.register(command("review#{"x" * 50}", "alpha"))
      lines = help.call("", env).text.lines.map(&:chomp)

      expect(lines).to include("#{" " * 24}alpha")
    end

    it "renders at 80 columns when the width source raises" do
      registry.register(command("tool", "word " * 30))
      allow(TTY::Screen).to receive(:width).and_raise(NoMethodError)
      lines = described_class.new(registry:, catalog:).call("", env).text.lines

      expect(lines.map { |line| line.chomp.length }.max).to be_between(61, 80)
    end

    it "falls back to the terminal's width in production construction" do
      real = described_class.new(registry:, catalog:)
      registry.register(command("tool", "short"))

      expect(real.call("", env).text).to include("/tool", "short")
    end
  end
end
