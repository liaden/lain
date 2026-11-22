# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Held do
  subject(:command) { described_class.new(rail:) }

  let(:time) { [100.0] }
  let(:lines) { Lain::Frontend::Intake::HeldLines.new(clock: -> { time.first }) }
  let(:rail) { Lain::Frontend::Intake.new(held: lines) }

  def later(seconds) = time[0] += seconds

  def env = build_command_env

  def hold(*typed)
    typed.each { rail.hold(_1) }
    later(90)
  end

  def texts = rail.held_lines

  it "registers as /held with a usage naming both forms" do
    expect([command.name, command.usage]).to match(["held", a_string_starting_with("/held").and(include("clear"))])
  end

  it "lists each held line, in the order typed" do
    hold("fix the bug", "then the docs")

    expect(command.call("", env)).to eq("held for you>:\n  1. fix the bug (typed with no prompt open, 1m ago)\n  " \
                                        "2. then the docs (typed with no prompt open, 1m ago)")
  end

  it "says nothing is held when nothing is" do
    expect(command.call("", env)).to eq("nothing held")
  end

  it "drops every held line on clear, and says how many" do
    hold("one", "two")

    expect([command.call("clear", env), texts]).to eq(["dropped 2 held lines", []])
  end

  it "refuses an argument it does not know, leaving the lines held" do
    hold("one")

    expect { command.call("everything", env) }.to raise_error(Lain::Error, /clear/)
    expect(texts).to eq(["one"])
  end

  it "lists the 2 lines, then none once cleared, through the registry the human types into" do
    registry = Lain::CLI::Command::Registry.new([command])
    hold("a", "b")
    typed = ["/held", "/held clear", "/held"].map { registry.dispatch(_1, env) { raise "unmatched" } }

    listing = "held for you>:\n  1. a (typed with no prompt open, 1m ago)\n  2. b (typed with no prompt open, 1m ago)"
    expect(typed).to eq([listing, "dropped 2 held lines", "nothing held"])
  end

  it "names the prompt a line was typed at and how long ago, in seconds under a minute" do
    listed = Sync do |task|
      reading = task.async { rail.read(:approval, "[y/N] ") }
      task.sleep(0.005) until rail.published.kind == :approval
      rail.hold("network")
      later(5)
      command.call("", env).tap { reading.stop }
    end

    expect(listed).to eq("held for you>:\n  1. network (typed at the approval prompt, 5s ago)")
  end

  it "says a line from a review offer was typed at the offer, not at a prompt" do
    lines.keep("ship it", kind: :offer)

    expect(command.call("", env)).to eq("held for you>:\n  1. ship it (typed at a review offer, 0s ago)")
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
