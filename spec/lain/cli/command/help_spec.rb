# frozen_string_literal: true

# T9: /help answers a {Lain::Renderable} now. The WORDS are unchanged -- the
# section headers name a token so the listing under them reads as content
# rather than as one flat colour.
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

  it "lists every registered command with its one-line usage" do
    rendered = help.call("", env)

    expect(rendered.text).to include(Lain::CLI::Command::Quit.new.usage)
    expect(rendered.text).to include(help.usage)
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

    expect(help.call("", env).text).to include("/status -- landed by a later card")
  end

  it "renders an honest empty skills section" do
    bare = described_class.new(registry:, catalog: Lain::Skill::Catalog.new({}))

    expect(bare.call("", env).text).to include("(none)")
  end

  it "returns a renderable and never prints" do
    rendered = nil
    expect { rendered = help.call("", env) }.not_to output.to_stdout

    expect(rendered).to be_a(Lain::Renderable)
  end

  describe "the renderable it answers (T9)" do
    it "says exactly the words the String return said" do
      expect(help.call("", env).text)
        .to eq("commands:\n  #{Lain::CLI::Command::Quit.new.usage}\n  #{help.usage}\n\nskills:\n  " \
               "/brew -- steep the pot")
    end

    it "names its section headers with the label token" do
      headers = help.call("", env).select { |segment| segment.token == :label }.map(&:text)

      expect(headers).to include("commands:", "skills:")
    end

    it "leaves the entries out of the header's token" do
      entries = help.call("", env).reject { |segment| segment.token == :label }.map(&:text).join

      expect(entries).to include("/brew -- steep the pot", help.usage)
    end

    it "renders more than one token -- the listing is never one flat colour" do
      expect(help.call("", env).map(&:token).uniq.size).to be > 1
    end
  end
end
