# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Held do
  subject(:command) { described_class.new(rail:) }

  let(:rail) { Lain::Frontend::Intake.new }

  def env = build_command_env

  def hold(*lines) = lines.each { rail.hold(_1) }

  it "registers as /held with a usage naming both forms" do
    expect([command.name, command.usage]).to match(["held", a_string_starting_with("/held").and(include("clear"))])
  end

  it "lists each held line, in the order typed" do
    hold("fix the bug", "then the docs")

    expect(command.call("", env)).to eq("held for you>:\n  1. fix the bug\n  2. then the docs")
  end

  it "says nothing is held when nothing is" do
    expect(command.call("", env)).to eq("nothing held")
  end

  it "drops every held line on clear, and says how many" do
    hold("one", "two")

    expect([command.call("clear", env), rail.held_lines]).to eq(["dropped 2 held lines", []])
  end

  it "refuses an argument it does not know, leaving the lines held" do
    hold("one")

    expect { command.call("everything", env) }.to raise_error(Lain::Error, /clear/)
    expect(rail.held_lines).to eq(["one"])
  end

  it "lists the 2 lines, then none once cleared, through the registry the human types into" do
    registry = Lain::CLI::Command::Registry.new([command])
    hold("a", "b")
    typed = ["/held", "/held clear", "/held"].map { registry.dispatch(_1, env) { raise "unmatched" } }

    expect(typed).to eq(["held for you>:\n  1. a\n  2. b", "dropped 2 held lines", "nothing held"])
  end

  describe "the rail nobody wired" do
    it "lists nothing and clears nothing" do
      [described_class::NoRail, nil].each do |rail|
        nothing = described_class.new(rail:)

        expect([nothing.call("", env), nothing.call("clear", env)]).to eq(["nothing held", "dropped 0 held lines"])
      end
    end
  end
end
