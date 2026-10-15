# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"

# Shift+Tab is a key only a terminal can send, so it is pressed in a real tmux
# pane running this checkout's `lain input`, against a chat process holding a
# real Switchboard behind a real Intake and InputSocket. The chat reads no
# stdin: every key reaches it over the socket, as it does in a cockpit.
RSpec.describe "the approval key in an input pane", :seam do
  # `parked` holds one call on the board's queue with its `[y/N]` drawn;
  # `unpublished` draws nothing, as a run in flight with no prompt open does;
  # anything else reads one `you>` line. The `vi` shape raises the vi layer.
  let(:chat_script) do
    <<~RUBY
      require "lain"
      require "json"

      dir, path, shape, approval = ARGV
      journal = Lain::Journal.new(io: File.open(File.join(dir, "journal.ndjson"), "a").tap { |io| io.sync = true })
      heard = File.open(File.join(dir, "heard.ndjson"), "a").tap { |io| io.sync = true }
      board = Lain::CLI::Switchboard.new(journal:, model: "spec-model", toolset: Lain::Toolset.new,
                                         approval: approval.to_sym)
      rail = Lain::Frontend::Intake.new(on_cycle: -> { board.cycle_approval(surface: Lain::CLI::Switchboard::KEY_SURFACE) })
      layers = shape == "vi" ? %w[vi] : []
      welcomed = -> { File.write(File.join(dir, "welcomed"), "").then { [] } }
      socket = Lain::CLI::InputSocket.new(rail:, path:, layers: -> { layers }, commands: welcomed).bind
      File.write(File.join(dir, "bound"), "")
      Sync do |task|
        socket.start(task)
        if shape == "parked"
          policy = Lain::Frontend::ApprovalPolicy.new(reader: ->(asked) { rail.read(:approval, asked) },
                                                     output: File.open(File::NULL, "w"))
          watching = task.async { policy.watch(board.approvals) }
          call = Lain::Effect::ToolCall.new(tool_use_id: "c1", name: "bash", input: { "command" => "rm -rf build" })
          settled = board.approvals.adjudicate(call, nil)
          heard.puts(JSON.generate({ "approved" => settled.approved? }))
          watching.stop
        elsif shape == "unpublished"
          Async::Task.current.sleep(0.05) until File.exist?(File.join(dir, "done"))
          heard.puts(JSON.generate({ "heard" => rail.read(:you, "you> ") }))
        else
          heard.puts(JSON.generate({ "heard" => rail.read(:you, "you> ") }))
        end
      end
      socket.stop
    RUBY
  end

  let(:repo) { File.expand_path("../../..", __dir__) }
  let(:dir) { @dir ||= Dir.mktmpdir("approval-key") }
  let(:socket) { "lain-ak#{Process.pid}#{SecureRandom.hex(3)}" }
  let(:path) { File.join(dir, "input.sock") }
  let(:env) do
    { "TMUX_TMPDIR" => dir, "TERM" => "xterm", "INPUTRC" => File.join(dir, "no-inputrc"),
      "XDG_STATE_HOME" => File.join(dir, "state"), "XDG_RUNTIME_DIR" => File.join(dir, "run"),
      "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_CACHE_HOME" => File.join(dir, "cache") }
  end

  let(:own_script) do
    <<~RUBY
      require "lain"
      dir, shape = ARGV
      approval = +"AUTO"
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: $stdout,
                                    input: Lain::Frontend::StdinPump.keys($stdin),
                                    prompt_renderer: ->(text:, **) { "lighter \#{approval}\n\#{text}" },
                                    history_path: File.join(dir, "history"), state_path: File.join(dir, "state.json"))
      cycle = lambda do
        approval.replace(approval == "AUTO" ? "ASK" : "AUTO")
        File.write(File.join(dir, "cycled"), "+", mode: "a")
      end
      rail = Lain::Frontend::Intake.new(screen: tty, on_cycle: cycle)
      Sync do |task|
        pumping = Lain::Frontend::StdinPump.new(rail:, screen: tty, input: $stdin).start(task)
        File.write(File.join(dir, "ready"), "")
        Async::Task.current.sleep(0.05) until shape != "late" || File.exist?(File.join(dir, "go"))
        File.write(File.join(dir, "heard.ndjson"), "\#{JSON.generate({ "heard" => rail.read(:you, "you> ") })}\n")
        pumping.stop
      end
    RUBY
  end

  around do |example|
    example.run
  ensure
    tmux("kill-server")
    reap(@chat)
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def tmux(*args) = Open3.capture3(env, "tmux", "-L", socket, *args)

  def press(*keys) = tmux("send-keys", *keys)

  def screen = tmux("capture-pane", "-p").first

  # The chat, then the pane typing into it, up to the pane drawing `prompt`.
  def cockpit(shape, approval:, prompt:)
    start_chat(shape, approval)
    wait_for { File.exist?(File.join(dir, "bound")) }
    tmux("new-session", "-d", "-x", "100", "-y", "20", "-c", repo,
         "#{RbConfig.ruby} -I lib exe/lain input --socket #{path}")
    wait_for { screen.include?(prompt) }
  end

  # A chat's own terminal: the real StdinPump started on it, as a chat with no
  # pane runs, so the key is bound by #start and nothing else. Its prompt
  # carries a header row naming the approval the key last flipped to. `late`
  # opens `you>` only once the spec says so, as a run in flight does.
  def own_terminal(shape = "plain")
    File.write(File.join(dir, "own.rb"), own_script)
    tmux("new-session", "-d", "-x", "100", "-y", "20", "-c", repo,
         "#{RbConfig.ruby} -I lib #{dir}/own.rb #{dir} #{shape}")
    wait_for { File.exist?(File.join(dir, "ready")) }
  end

  # A pane typing into a chat with no prompt open, once the pane's terminal
  # ends a read at ESC, which is when the key can arrive as it is pressed.
  def idle_pane
    start_chat("unpublished", :auto)
    wait_for { File.exist?(File.join(dir, "bound")) }
    tmux("new-session", "-d", "-x", "100", "-y", "20", "-c", repo,
         "#{RbConfig.ruby} -I lib exe/lain input --socket #{path}")
    wait_for { File.exist?(File.join(dir, "welcomed")) }
    pane_tty = tmux("display-message", "-p", "\#{pane_tty}").first.strip
    wait_for { Open3.capture2("stty", "-F", pane_tty, "-a").first.include?("eol = ^[") }
  end

  def start_chat(shape, approval)
    @chat = Process.spawn(env, RbConfig.ruby, "-I", File.join(repo, "lib"), "-e", chat_script,
                          dir, path, shape, approval.to_s,
                          in: File::NULL, out: File.join(dir, "chat.err"), err: %i[child out])
  end

  def lines_of(name) = File.exist?(File.join(dir, name)) ? File.readlines(File.join(dir, name)) : []

  def heard = lines_of("heard.ndjson").map { |line| JSON.parse(line) }

  def flips
    Lain::Journal.records(lines_of("journal.ndjson"), type: "mode_switch").select { |record| record["surface"] == "key" }
                 .map { |record| record.values_at("from_approval", "to_approval") }.to_a
  end

  def wait_for(timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "timed out; the chat said:\n#{lines_of("chat.err").join}" unless yield
  end

  def reap(pid)
    return if pid.nil?

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  it "flips auto to ask at once while a call is parked, and the call still waits for its answer" do
    cockpit("parked", approval: :auto, prompt: "y/N")

    press("BTab")
    wait_for { flips.any? }
    parked_through_the_flip = heard.empty?
    press("y", "Enter")
    wait_for { heard.any? }

    expect([flips, parked_through_the_flip, heard])
      .to eq([[%w[auto ask]], true, [{ "approved" => true }]])
  end

  it "flips approval at an idle you>, and leaves the draft as it was typed" do
    cockpit("idle", approval: :ask, prompt: "you>")

    press("draft")
    press("BTab")
    wait_for { flips.any? }
    press("Enter")
    wait_for { heard.any? }

    expect([flips, heard]).to eq([[%w[ask auto]], [{ "heard" => "draft" }]])
  end

  it "cycles from a chat's own terminal, bound by the pump as it starts, and leaves the draft as typed" do
    own_terminal
    wait_for { screen.include?("you>") }

    press("draft")
    press("BTab")
    wait_for { lines_of("cycled").any? }
    press("Enter")
    wait_for { heard.any? }

    expect([lines_of("cycled").join, heard]).to eq(["+", [{ "heard" => "draft" }]])
  end

  it "redraws the open prompt's header with the level the key flipped to, the draft kept" do
    own_terminal
    # The prompt, not only its header: a key pressed before the read opens is
    # typed ahead, and dropped by design.
    wait_for { screen.include?("lighter AUTO") && screen.include?("you>") }

    press("draft")
    press("BTab")
    wait_for { screen.include?("lighter ASK") }
    drawn = screen
    press("Enter")
    wait_for { heard.any? }

    expect([drawn.include?("lighter AUTO"), drawn[/^.*you> .*$/], heard])
      .to eq([false, "you> draft", [{ "heard" => "draft" }]])
  end

  it "drops a Shift+Tab typed while no prompt was drawn rather than flipping late at you>" do
    own_terminal("late")

    press("ab")
    press("BTab")
    sleep 0.2
    FileUtils.touch(File.join(dir, "go"))
    wait_for { screen.include?("you>") }
    press("Enter")
    wait_for { heard.any? }

    expect([lines_of("cycled"), heard]).to eq([[], [{ "heard" => "ab" }]])
  end

  it "sends the key from the pane at once while the chat has no prompt open" do
    idle_pane

    press("BTab")
    wait_for { flips.any? }
    sleep 0.2

    expect([flips, screen.include?("^[")]).to eq([[%w[auto ask]], false])
  end

  # Mid-run, the pane's terminal is still the kernel's line editor, so a
  # correction typed there has to reach the chat as corrected.
  it "sends a line typed into an idle pane whole, Z and a correction included" do
    idle_pane

    press("Zx")
    press("BSpace", "BSpace")
    press("Zoom", "Enter")
    sleep 0.3
    FileUtils.touch(File.join(dir, "done"))
    wait_for { heard.any? }

    expect([heard, flips]).to eq([[{ "heard" => "Zoom" }], []])
  end

  it "takes a lone ESC to vi command mode with the key bound" do
    cockpit("vi", approval: :ask, prompt: "you>")

    press("abc")
    press("Escape")
    wait_for { screen.include?("[cmd]") }
    press("x")
    press("Enter")
    wait_for { heard.any? }

    expect(heard).to eq([{ "heard" => "ab" }])
  end
end
