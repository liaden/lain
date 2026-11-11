# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# The herdr binary is a stub script on a temp path: it logs each call and answers from files the
# examples write, so nothing here reaches a real herdr.
RSpec.describe Lain::CLI::HerdrSurface do
  let(:stub_herdr) do
    <<~'SH'
      #!/bin/sh
      printf '%s\n' "$*" >> "$STUB_DIR/log"
      printf 'env %s\n' "$HERDR_SOCKET_PATH" >> "$STUB_DIR/log"
      case "$*" in
        "plugin pane open"*"--placement popup"*)
          if [ -f "$STUB_DIR/popup_error" ]; then cat "$STUB_DIR/popup_error" >&2; exit 1; fi
          echo '{"id":"cli:plugin","result":{"type":"ok"}}'; exit 0 ;;
      esac
      case "$1 $2" in
        "plugin pane")
          if [ -f "$STUB_DIR/open_error" ]; then cat "$STUB_DIR/open_error" >&2; exit 1; fi
          cat "$STUB_DIR/open_reply" ;;
        "tab rename")
          if [ -f "$STUB_DIR/rename_error" ]; then cat "$STUB_DIR/rename_error" >&2; exit 1; fi ;;
        "tab list") cat "$STUB_DIR/tabs" ;;
      esac
      exit 0
    SH
  end

  let(:dir) { Dir.mktmpdir("herdr-surface-spec", ENV.fetch("TMPDIR", nil)) }
  let(:status_dir) { File.join(dir, "status") }
  let(:target) { Lain::Herdr::Target.new(bin: File.join(dir, "herdr"), pane: "w1:p1", socket: "/run/herdr.sock", via: :env) }
  let(:surface) do
    described_class.new(target:, status_dir:,
                        shell_out_factory: lambda { |*argv, **opts|
                          Lain::Shell::Out.new(*argv, **opts, environment: opts[:environment].merge("STUB_DIR" => dir))
                        })
  end

  before do
    File.write(File.join(dir, "herdr"), stub_herdr)
    File.chmod(0o755, File.join(dir, "herdr"))
    answer_open("w1:p5", "w1:t5")
    tabs([])
  end

  after { FileUtils.remove_entry(dir) }

  def answer_open(pane, tab)
    reply = { "id" => "cli:plugin",
              "result" => { "type" => "plugin_pane_opened",
                            "plugin_pane" => { "entrypoint" => "run", "plugin_id" => "lain",
                                               "pane" => { "pane_id" => pane, "tab_id" => tab } } } }
    File.write(File.join(dir, "open_reply"), JSON.generate(reply))
  end

  def tabs(list) = File.write(File.join(dir, "tabs"), JSON.generate({ "result" => { "tabs" => list } }))

  def calls = File.read(File.join(dir, "log")).lines(chomp: true).reject { |line| line.start_with?("env ") }

  def envs = File.read(File.join(dir, "log")).lines(chomp: true).select { |line| line.start_with?("env ") }

  def status_path = calls.first[/LAIN_RUN_STATUS=(\S+)/, 1]

  describe "#window" do
    it "opens a plugin pane as a tab, then labels it" do
      placement = surface.window(command: "lain watch X", name: "dev-3f2a", cwd: "/repo", keep_failed: true)

      expect(calls.first).to start_with("plugin pane open --plugin lain --entrypoint run --placement tab --cwd /repo")
      expect(calls.first).to include("--env LAIN_RUN_COMMAND=lain watch X", "--env LAIN_KEEP_FAILED=1")
      expect(calls.first).to match(%r{--env LAIN_RUN_STATUS=#{Regexp.escape(status_dir)}/})
      expect(calls.last).to eq("tab rename w1:t5 dev-3f2a")
      expect(placement).to have_attributes(kind: :window, target: "dev-3f2a", degraded: false)
    end

    it "reaches the server that owns the pane" do
      surface.window(command: "x", name: "n")

      expect(envs.first).to eq("env /run/herdr.sock")
    end

    it "raises on a misspelt keyword, as TmuxSurface does" do
      expect { surface.window(command: "x", keep_faild: true) }.to raise_error(ArgumentError, /keep_faild/)
    end

    it "accepts the session a tmux caller names" do
      expect(surface.window(command: "x", name: "n", target_session: "lain").kind).to eq(:window)
    end

    it "takes focus, as a tmux window does" do
      surface.window(command: "x", name: "n")

      expect(calls.first).not_to include("--no-focus")
    end

    it "raises Unavailable when herdr answers a reply it cannot read" do
      File.write(File.join(dir, "open_reply"), '{"result":{"type":"ok"}}')

      expect { surface.window(command: "x", name: "n") }
        .to raise_error(Lain::CLI::HerdrSurface::Unavailable, /unreadable/)
    end

    it "raises Unavailable when herdr has no workspace to open in" do
      File.write(File.join(dir, "open_reply"), "")
      File.write(File.join(dir, "open_error"), '{"error":{"code":"no_active_workspace"}}')

      expect { surface.window(command: "x", name: "n") }
        .to raise_error(Lain::CLI::TmuxSurface::TmuxUnavailable, /no_active_workspace/)
    end

    it "omits the hold flag when the pane need not be kept" do
      surface.window(command: "x", name: "n")

      expect(calls.first).not_to include("LAIN_KEEP_FAILED")
    end
  end

  describe "#window_state" do
    def open_and_rename
      surface.window(command: "x", name: "dev-3f2a", keep_failed: true)
      tabs([{ "tab_id" => "w1:t5", "label" => "dev-3f2a done" }])
    end

    it "follows a renamed window and reads the recorded status" do
      open_and_rename
      File.write(status_path, "7\n")

      expect(surface.window_state(target: "=dev-3f2a done").status).to eq(7)
    end

    it "is nil while no status is recorded" do
      open_and_rename

      expect(surface.window_state(target: "lain:=dev-3f2a done").status).to be_nil
    end

    it "deletes the status file once the final status is read" do
      open_and_rename
      File.write(status_path, "7\n")
      surface.window_state(target: "=dev-3f2a done")

      expect(File.exist?(status_path)).to be(false)
    end

    it "deletes the status file of a tab that has closed" do
      surface.window(command: "x", name: "dev-3f2a")
      File.write(status_path, "0\n")
      tabs([])

      expect(surface.window_state(target: "=dev-3f2a").status).to be_nil
      expect(File.exist?(status_path)).to be(false)
    end
  end

  describe "#popup" do
    it "opens a popup of the given size" do
      placement = surface.popup(command: "lain chat", title: "btw", width: "60%", height: 10, cwd: "/repo")

      expect(calls.first).to include("--placement popup", "--width 60%", "--height 10", "--cwd /repo")
      expect(placement).to have_attributes(kind: :popup, degraded: false)
    end

    it "takes focus, as a tmux popup does" do
      surface.popup(command: "lain chat", title: "btw")

      expect(calls.first).not_to include("--no-focus")
    end

    it "degrades for any other refusal, with its own reason" do
      File.write(File.join(dir, "popup_error"), '{"error":{"code":"no_such_plugin"}}')

      placement = surface.popup(command: "lain chat", title: "btw")

      expect(placement).to have_attributes(kind: :window, degraded: true, reason: "popup_unavailable")
    end

    it "opens a window instead when herdr is busy, and says why" do
      File.write(File.join(dir, "popup_error"), '{"error":{"code":"ui_busy"}}')

      placement = surface.popup(command: "lain chat", title: "btw")

      expect(placement).to have_attributes(kind: :window, degraded: true, reason: "ui_busy")
      expect(calls.last).to eq("tab rename w1:t5 btw")
    end
  end

  describe "#rename_window" do
    it "raises when herdr itself refuses the rename" do
      tabs([{ "tab_id" => "w1:t9", "label" => "dev" }])
      File.write(File.join(dir, "rename_error"), '{"error":{"code":"tab_not_found"}}')

      expect { surface.rename_window(target: "=dev", name: "x") }
        .to raise_error(Lain::CLI::HerdrSurface::Unavailable, /tab_not_found/)
    end

    it "raises an error callers can rescue as TmuxUnavailable for a tab herdr does not list" do
      expect { surface.rename_window(target: "=gone", name: "x") }
        .to raise_error(Lain::CLI::TmuxSurface::TmuxUnavailable, /gone/)
    end

    it "renames a listed tab" do
      tabs([{ "tab_id" => "w1:t9", "label" => "dev" }])
      surface.rename_window(target: "=dev", name: "dev done")

      expect(calls.last).to eq("tab rename w1:t9 dev done")
    end
  end

  it "raises the same error when the binary cannot run" do
    missing = described_class.new(target: target.with(bin: File.join(dir, "nope")), status_dir:)

    expect { missing.window(command: "x") }.to raise_error(Lain::CLI::TmuxSurface::TmuxUnavailable)
  end

  it "reports no variable missing from a global environment" do
    expect(surface.missing_from_global_environment(%w[A B])).to eq([])
  end

  describe "under the callers that were written for TmuxSurface" do
    let(:head) { "blake3:#{"ab12" * 16}" }
    let(:session) { "2026-07-23T10-00-00Z-chat.ndjson" }
    let(:head_turn) { instance_double(Lain::Ext::Event, role: "user", content: [{ "type" => "text", "text" => "hi" }]) }
    let(:timeline) { instance_double(Lain::Ext::Timeline, head_digest: head, head: head_turn) }
    let(:agent) { instance_double(Lain::Agent, timeline:, dispatching?: false) }
    let(:chronicle) do
      instance_double(Lain::CLI::Chronicle, journal_path: "/sessions/#{session}", catch_up: nil)
    end
    let(:env) do
      build_command_env(agent:, chronicle:, tmux_surface: surface,
                        fork_point: instance_double(Lain::CLI::ForkPoint, call: nil))
    end

    it "serves /fork" do
      reply = Lain::CLI::Command::Fork.new(environment: { "TMUX" => "x" }).call("", env)

      expect(reply).to start_with("forked into tmux window fork-ab12ab12ab12")
      expect(calls.last).to eq("tab rename w1:t5 fork-ab12ab12ab12")
    end

    it "serves /btw" do
      reply = Lain::CLI::Command::Btw.new.call("why?", env)

      expect(reply).to start_with("btw: asked in a popup")
      expect(calls.first).to include("--placement popup")
    end

    it "serves FleetWindows, opening and naming its window" do
      fleet = Lain::CLI::FleetWindows.new(surface:, role_for: ->(_record) { "researcher" }, spawner: ->(&_pump) {})
      spawn = Lain::Telemetry::Message.new(
        digest: "blake3:5aaa111122223333", kind: :spawn, from: "blake3:9f00111122223333", to: nil,
        payload: { "prefix" => "fresh", "posture" => "schema", "only" => nil,
                   "spawned_from" => "blake3:0abc111122223333", "lifecycle" => "launched" },
        causal_parents: ["blake3:0abc111122223333"], correlation: "blake3:9f00111122223333"
      )
      fleet << spawn
      fleet.drain_pending

      expect(calls.first).to include("plugin pane open", "--placement tab")
      expect(calls).to include("tab rename w1:t5 researcher-5aaa1111")
    end
  end
end
