# frozen_string_literal: true

require "tmpdir"

RSpec.describe "plugin/herdr" do
  let(:manifest) { Lain::Ext::Toml.parse(File.read(File.join(Lain::Paths::Shipped::GEM_ROOT, "plugin/herdr/herdr-plugin.toml"))) }
  let(:argv) { manifest.fetch("panes").find { |pane| pane["id"] == "run" }.fetch("command") }

  around do |example|
    Dir.mktmpdir("lain-herdr-plugin") do |dir|
      @status = File.join(dir, "status")
      example.run
    end
  end

  def launch(command, **extra)
    Process.spawn({ "LAIN_RUN_COMMAND" => command, "LAIN_RUN_STATUS" => @status, **extra }, *argv, pgroup: true)
  end

  def await_status
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.05 until File.exist?(@status) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def recorded = File.read(@status).strip

  it "declares the lain plugin" do
    expect(manifest.values_at("id", "name")).to eq(%w[lain lain])
  end

  it "runs a command and records its exit" do
    Process.wait(launch("exit 7"))

    expect(recorded).to eq("7")
  end

  it "records the exit of a command that execs" do
    Process.wait(launch("export X=1; exec sh -c 'exit 5'"))

    expect(recorded).to eq("5")
  end

  it "closes a clean pane even when asked to keep failures" do
    _, status = Process.wait2(launch("exit 0", "LAIN_KEEP_FAILED" => "1"))

    expect([recorded, status.exitstatus]).to eq(["0", 0])
  end

  it "holds a failed pane until it is killed when asked to" do
    pid = launch("exit 3", "LAIN_KEEP_FAILED" => "1")
    await_status
    sleep 0.2

    expect([recorded, Process.wait(pid, Process::WNOHANG)]).to eq(["3", nil])
  ensure
    Process.kill("KILL", -pid) if pid
    Process.wait(pid) if pid
  end

  it "closes a failed pane when not asked to hold it" do
    _, status = Process.wait2(launch("exit 3"))

    expect([recorded, status.exitstatus]).to eq(["3", 3])
  end
end
