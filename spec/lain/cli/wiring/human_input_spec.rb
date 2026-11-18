# frozen_string_literal: true

RSpec.describe Lain::CLI::Wiring::HumanInput do
  let(:runtime) { Dir.mktmpdir }
  let(:paths) { Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => runtime })) }
  let(:tty) { instance_double(Lain::Frontend::TTY) }
  let(:piped) { StringIO.new }

  after { FileUtils.rm_rf(runtime) }

  def human(input: nil, attended: true, stdin: piped)
    described_class.new(input:, attended:, stdin:, paths:, cwd: "/work")
  end

  it "names no socket unless --input asks for one" do
    expect(human.socket_name).to be_nil
  end

  it "names the socket --input socket:<name> puts the human on" do
    expect(human(input: "socket:side").socket_name).to eq("side")
  end

  it "keeps the alternate screen for a chat reading its own terminal, and gives it up to a pane" do
    expect([human.alternate_screen?, human(input: "socket:side").alternate_screen?]).to eq([true, false])
  end

  it "is a pane only when attended and over a socket" do
    expect([human(input: "socket:side").pane?, human(input: "socket:side", attended: false).pane?, human.pane?])
      .to eq([true, false, false])
  end

  it "records history for a pane's human" do
    expect(human(input: "socket:side").history_for(tty)).to be_a(Lain::Frontend::Intake::Discretion)
  end

  it "records no history for a script's pipe, or an unattended run" do
    expect([human.history_for(tty), human(attended: false).history_for(tty)])
      .to all(be(Lain::Frontend::Intake::Unrecorded))
  end

  it "records history for a stdin that is a terminal" do
    terminal = Class.new(StringIO) { def tty? = true }.new

    expect(human(stdin: terminal).history_for(tty)).to be_a(Lain::Frontend::Intake::Discretion)
  end

  it "binds the socket under the paths and working directory it was given" do
    expect(human(input: "socket:side").socket_path)
      .to eq(Lain::CLI::InputSocket.path(name: "side", paths:, cwd: "/work"))
  end
end
