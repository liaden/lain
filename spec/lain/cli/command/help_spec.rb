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

  it "lists every registered command with its one-line usage" do
    text = help.call("", env)

    expect(text).to include(Lain::CLI::Command::Quit.new.usage)
    expect(text).to include(help.usage)
  end

  it "lists the catalog's skills beside the commands" do
    expect(help.call("", env)).to include("/brew", "steep the pot")
  end

  it "sees a command registered after it was built -- the registry reference is live" do
    late = Struct.new(:name) do
      def usage = "/#{name} -- landed by a later card"

      def call(_args, _env) = ""
    end
    registry.register(late.new("status"))

    expect(help.call("", env)).to include("/status -- landed by a later card")
  end

  it "renders an honest empty skills section" do
    bare = described_class.new(registry:, catalog: Lain::Skill::Catalog.new({}))

    expect(bare.call("", env)).to include("(none)")
  end

  it "returns rendered text and never prints" do
    text = nil
    expect { text = help.call("", env) }.not_to output.to_stdout

    expect(text).to be_a(String)
  end
end
