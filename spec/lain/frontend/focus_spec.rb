# frozen_string_literal: true

require "fileutils"
require "open3"
require "pty"
require "securerandom"
require "tmpdir"

RSpec.describe Lain::Frontend::Focus do
  let(:calls) { [] }
  let(:env) { { "TMUX" => "/tmp/tmux-1/default,1,0", "TMUX_PANE" => "%3" } }
  let(:answer) { "1 2\n" }
  let(:status) { 0 }
  let(:shell_out) do
    lambda do |*argv, **opts|
      calls << [argv, opts]
      instance_double(Lain::Shell::Out, run_command: nil, stdout: answer, exitstatus: status)
    end
  end

  def focus = described_class.tmux(env:, shell_out:)

  describe ".tmux" do
    it "is focused when the window is active and a client is attached" do
      expect(focus.focused?).to be(true)
    end

    it "asks about the chat's own pane under the chat's tmux session" do
      focus.focused?

      expect(calls.first).to eq(
        [["tmux", "display-message", "-p", "-t", "%3", "\#{window_active} \#{session_attached}"],
         { environment: env, timeout: 2 }]
      )
    end

    it "is not focused when another window is showing" do
      allow(self).to receive(:answer).and_return("0 2\n")

      expect(focus.focused?).to be(false)
    end

    it "is not focused when no client is attached" do
      allow(self).to receive(:answer).and_return("1 0\n")

      expect(focus.focused?).to be(false)
    end

    it "is not focused when tmux exits non-zero" do
      allow(self).to receive(:status).and_return(1)

      expect(focus.focused?).to be(false)
    end

    it "is not focused when the answer is not the probed shape" do
      allow(self).to receive(:answer).and_return("no server running\n")

      expect(focus.focused?).to be(false)
    end

    it "is not focused, and does not raise, when the call raises" do
      boom = ->(*, **) { raise Lain::Shell::Out::Timeout, "slow" }

      expect(described_class.tmux(env:, shell_out: boom).focused?).to be(false)
    end

    it "never asks tmux outside tmux" do
      outside = described_class.tmux(env: { "TMUX" => "" }, shell_out:)

      expect([outside.focused?, calls]).to eq([false, []])
    end

    it "is not focused when TMUX is set but the pane is not" do
      expect(described_class.tmux(env: { "TMUX" => "x,1,0" }, shell_out:).focused?).to be(false)
    end
  end

  describe ".for" do
    let(:herdr_calls) { [] }
    let(:herdr_answer) { true }
    let(:target) { Lain::Herdr::Target.new(bin: "herdr", pane: "w1:p1", socket: "/s", via: :cockpit) }
    let(:resolver) { Struct.new(:current).new(target) }

    def routed(env: self.env)
      calls = herdr_calls
      probe = Struct.new(:focused?).new(herdr_answer)
      herdr = lambda do |found|
        calls << found
        probe
      end
      described_class.for(env:, resolver:, shell_out:, herdr:)
    end

    it "needs both in a cockpit inside herdr" do
      allow(self).to receive(:herdr_answer).and_return(false)

      expect(routed.focused?).to be(false)
    end

    it "is focused when tmux and herdr both say so" do
      expect(routed.focused?).to be(true)
    end

    it "is not focused when herdr says so and tmux does not" do
      allow(self).to receive(:answer).and_return("0 2\n")

      expect(routed.focused?).to be(false)
    end

    it "uses tmux only when no herdr target resolves" do
      allow(resolver).to receive(:current).and_return(nil)

      expect([routed.focused?, herdr_calls]).to eq([true, []])
    end

    it "uses herdr only in a plain herdr pane" do
      env_target = target.with(via: :env)
      allow(resolver).to receive(:current).and_return(env_target)

      expect([routed(env: {}).focused?, herdr_calls, calls]).to eq([true, [env_target], []])
    end

    it "asks the resolver on every call, since the target may appear later" do
      allow(self).to receive(:herdr_answer).and_return(false)
      allow(resolver).to receive(:current).and_return(nil, target)
      focus = routed

      expect([focus.focused?, focus.focused?]).to eq([true, false])
    end
  end

  describe "against a real tmux server", :seam do
    let(:socket) { "lain-fo#{Process.pid}#{SecureRandom.hex(3)}" }
    let(:dir) { @dir ||= Dir.mktmpdir("focus") }
    let(:tmux_env) { { "TMUX_TMPDIR" => dir } }
    let(:clients) { [] }

    around do |example|
      example.run
    ensure
      clients.each do |io, pid|
        io.close unless io.closed?
        Process.kill("TERM", pid) rescue nil # rubocop:disable Style/RescueModifier
        Process.wait(pid) rescue nil # rubocop:disable Style/RescueModifier
      end
      tmux("kill-server")
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
    end

    def tmux(*args) = Open3.capture3(tmux_env, "tmux", "-L", socket, *args)

    def pane_env(pane)
      path = tmux("display-message", "-p", "-t", pane, "\#{socket_path}").first.strip
      tmux_env.merge("TMUX" => "#{path},0,0", "TMUX_PANE" => pane)
    end

    # A client on a dumb or unset TERM, as a hook or CI runner has, exits at once without attaching.
    def attach
      reader, _writer, pid = PTY.spawn(tmux_env.merge("TERM" => "xterm-256color"), "tmux", "-L", socket, "attach")
      clients << [reader, pid]
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      sleep 0.05 until tmux("display-message", "-p", "\#{session_attached}").first.strip == "1" ||
                       Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    def real_focus(pane) = described_class.tmux(env: pane_env(pane))

    before do
      tmux("new-session", "-d", "-x", "80", "-y", "20", "sleep 60")
      tmux("split-window", "-t", "0", "sleep 60")
    end

    it "counts a window with another pane selected as focused only while a client is attached" do
      chat = tmux("list-panes", "-t", "0", "-F", "\#{pane_id}").first.lines.first.strip
      tmux("select-pane", "-t", "0.1")
      detached = real_focus(chat).focused?
      attach
      attached = real_focus(chat).focused?
      tmux("new-window", "sleep 60")
      elsewhere = real_focus(chat).focused?

      expect([detached, attached, elsewhere]).to eq([false, true, false])
    end
  end
end
