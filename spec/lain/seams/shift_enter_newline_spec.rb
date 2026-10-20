# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"

# Shift+Enter reaches a program only if the program asked tmux for it, so the
# editor's request and its reset are judged against a real tmux server with
# extended-keys on and a real pane running the real LineEditor, never a double.
RSpec.describe "Shift+Enter in a pane", :seam do
  let(:repo) { File.expand_path("../../..", __dir__) }
  let(:socket) { "lain-se#{Process.pid}#{SecureRandom.hex(3)}" }
  let(:dir) { @dir ||= Dir.mktmpdir("shift-enter") }
  let(:env) { { "TMUX_TMPDIR" => dir } }
  let(:submitted) { File.join(dir, "submitted") }
  let(:script) do
    <<~RUBY
      require "lain"
      line = Lain::Frontend::LineEditor.new.read("you> ")
      File.write(ARGV[0], line.inspect)
      require "io/console"
      got = $stdin.raw do
        File.write("\#{ARGV[0]}.ready", "")
        $stdin.readpartial(32)
      end
      File.write("\#{ARGV[0]}.after", got.inspect)
    RUBY
  end

  around do |example|
    example.run
  ensure
    tmux("kill-server")
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def tmux(*args) = Open3.capture3(env, "tmux", "-L", socket, *args)

  def start_pane
    File.write(File.join(dir, "pane.rb"), script)
    tmux("new-session", "-d", "-x", "100", "-y", "20", "-c", repo,
         "ruby -I lib #{File.join(dir, "pane.rb")} #{submitted}")
    tmux("set-option", "-s", "extended-keys", "on")
    wait_for { tmux("capture-pane", "-p").first.include?("you>") }
  end

  def wait_for(timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "timed out" unless yield
  end

  it "inserts a newline and submits the whole draft on Enter" do
    start_pane
    tmux("send-keys", "ab")
    tmux("send-keys", "S-Enter")
    tmux("send-keys", "cd", "Enter")
    wait_for { File.size?(submitted) }

    expect(File.read(submitted)).to eq("ab\ncd".inspect)
  end

  it "hands the next program a plain CR for Shift+Enter once the read returns" do
    start_pane
    tmux("send-keys", "x", "Enter")
    wait_for { File.exist?(submitted) }
    wait_for { File.exist?("#{submitted}.ready") }
    tmux("send-keys", "S-Enter")
    wait_for { File.size?("#{submitted}.after") }

    expect(File.read("#{submitted}.after")).to eq("\r".inspect)
  end
end
