# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Release do
  subject(:command) { described_class.new(cwd: root, ledger:, sensitivity:) }

  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:root) { Dir.mktmpdir("release-root") }
  let(:related) { Dir.mktmpdir("release-related") }
  let(:rules) { Lain::Sensitivity::Rules.new(related: [related]) }
  let(:sensitivity) { Lain::Sensitivity.new(home: root, cwd: root, rules:) }
  let(:env) { build_command_env }
  let(:region) { Struct.new(:digest).new("blake3:aaa") }

  after { [root, related].each { |dir| FileUtils.remove_entry(dir) } }

  it "is the /release command and describes itself" do
    expect(command.name).to eq("release")
    expect(command.usage).to include("/release PATH")
  end

  it "forgets a decline, so the file asks again" do
    path = File.join(root, "config/master.key")
    ledger.decline(path, [region])

    reply = command.call("config/master.key", env)

    expect(ledger.declined?(path, region)).to be(false)
    expect(reply).to include("config/master.key")
  end

  it "forgets a lapse the same way and counts both" do
    path = File.join(root, "a.key")
    ledger.lapse(path, [region])

    expect(command.call(path, env)).to include("1 ")
    expect(ledger.lapsed?(path, region)).to be(false)
  end

  it "says region in the singular for one forgotten and regions for two" do
    one = File.join(root, "one.key")
    two = File.join(root, "two.key")
    ledger.decline(one, [region])
    ledger.decline(two, [region, Struct.new(:digest).new("blake3:bbb")])

    expect(command.call(one, env)).to include("forgot 1 declined or lapsed region, so")
    expect(command.call(two, env)).to include("forgot 2 declined or lapsed regions, so")
  end

  it "says nothing was declined for a path with nothing to forget" do
    expect(command.call("README.md", env)).to include("nothing was declined for README.md")
  end

  it "refuses a path under a related directory, which is masked and never released" do
    reply = command.call(File.join(related, "notes.env"), env)

    expect(reply).to include("related directories are masked and never released")
  end

  it "asks for a path when given none" do
    expect(command.call("  ", env)).to include("/release PATH")
  end
end
