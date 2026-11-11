# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "tmpdir"

module Lain
  module CLI
    # {TmuxSurface}'s public messages over the herdr CLI, so `/fork`, `/btw` and {FleetWindows} open
    # their panes in herdr unchanged. Every pane is the lain plugin's `run` pane: herdr closes a pane
    # the moment its command exits and reports no status, so the plugin's script writes the status to
    # a file this surface reads back.
    class HerdrSurface
      # An {Up::TmuxUnavailable}, so the callers' existing rescue catches it.
      class Unavailable < Up::TmuxUnavailable
      end

      PLUGIN = "lain"
      ENTRYPOINT = "run"
      TIMEOUT = 10
      # A popup's status is never read, and the plugin's script writes one wherever it is told.
      NO_STATUS = File::NULL

      Placement = TmuxSurface::Placement
      WindowState = TmuxSurface::WindowState

      # @param target [Herdr::Target] the herdr server to open panes in
      # @param shell_out_factory [#call] `Shell::Out.new`, or a double
      # @param status_dir [String] where a pane's exit status is written; a file is deleted once its
      #   status is read or its tab is gone
      def initialize(target:, shell_out_factory: Shell::Out.public_method(:new),
                     status_dir: File.join(Dir.tmpdir, "lain-herdr-#{Process.uid}"))
        @target = target
        @shell_out_factory = shell_out_factory
        @status_dir = status_dir
        @statuses = {}
      end

      # @param command [String] shell command the pane runs
      # @param name [String, nil] the tab's label
      # @param target_session [String, nil] accepted for {TmuxSurface}'s signature; herdr has no sessions
      # @param cwd [String, nil] the pane's start directory
      # @param keep_failed [Boolean] hold the pane when its command exits non-zero
      # @return [Placement]
      def window(command:, name: nil, target_session: nil, cwd: nil, keep_failed: false)
        # The tab opens in the pane the plugin runs in, so a tmux session names nothing here.
        target_session => nil | String
        path = status_path
        tab_id = opened_tab(open_pane("tab", command, path, cwd:, keep_failed:))
        @statuses[tab_id] = path
        rename(tab_id, name) if name
        Placement.new(kind: :window, target: name, degraded: false, reason: nil)
      end

      # @param target [String] a tmux-style target; only the label after `=` is read
      # @return [WindowState] status nil until the pane's script has recorded one
      def window_state(target:)
        tabs = listed_tabs
        forget_closed(tabs)
        tab = tabs.find { |candidate| candidate["label"] == label_of(target) }
        WindowState.new(target:, status: tab && recorded_status(tab["tab_id"]))
      end

      # @return [Placement] a window instead, marked degraded, when herdr will not show a popup
      def popup(command:, title: nil, width: nil, height: nil, cwd: nil)
        open_pane("popup", command, NO_STATUS, cwd:, width:, height:)
        Placement.new(kind: :popup, target: title, degraded: false, reason: nil)
      rescue Unavailable => e
        reason = e.message.include?("ui_busy") ? "ui_busy" : "popup_unavailable"
        window(command:, name: title, cwd:).with(degraded: true, reason:)
      end

      # @return [self]
      def rename_window(target:, name:)
        tab = listed_tabs.find { |candidate| candidate["label"] == label_of(target) }
        raise Unavailable, "herdr tab #{target} not found" unless tab

        rename(tab.fetch("tab_id"), name)
        self
      end

      # @param _env [#[]] unread: this surface is chosen only for a linked plain herdr pane
      # @return [true]
      def windows_from_here?(_env) = true

      # herdr panes inherit the server's own environment, so there is nothing to inspect.
      def missing_from_global_environment(_names) = []

      private

      def open_pane(placement, command, status, cwd:, keep_failed: false, width: nil, height: nil)
        args = ["plugin", "pane", "open", "--plugin", PLUGIN, "--entrypoint", ENTRYPOINT, "--placement", placement]
        args += ["--cwd", cwd] if cwd
        args += ["--width", width.to_s] if width
        args += ["--height", height.to_s] if height
        args += ["--env", "LAIN_RUN_COMMAND=#{command}", "--env", "LAIN_RUN_STATUS=#{status}"]
        args += ["--env", "LAIN_KEEP_FAILED=1"] if keep_failed
        JSON.parse(herdr(*args))
      rescue JSON::ParserError => e
        raise Unavailable, "herdr plugin pane open answered something unreadable: #{e.message}"
      end

      def opened_tab(reply)
        tab_id = reply.dig("result", "plugin_pane", "pane", "tab_id")
        tab_id or raise Unavailable, "herdr plugin pane open answered something unreadable: #{reply}"
      end

      def rename(tab_id, name) = herdr("tab", "rename", tab_id, name)

      def listed_tabs = JSON.parse(herdr("tab", "list")).dig("result", "tabs") || []

      def label_of(target) = target.to_s.sub(/\A.*?:(?==)/, "").delete_prefix("=")

      def status_path
        FileUtils.mkdir_p(@status_dir)
        File.join(@status_dir, SecureRandom.hex(8))
      end

      def recorded_status(tab_id)
        path = @statuses[tab_id]
        status = Integer(File.read(path).strip, exception: false) if path && File.exist?(path)
        discard(tab_id) if status
        status
      end

      def forget_closed(tabs)
        open_ids = tabs.map { |tab| tab["tab_id"] }
        (@statuses.keys - open_ids).each { |tab_id| discard(tab_id) }
      end

      def discard(tab_id) = FileUtils.rm_f(@statuses.delete(tab_id))

      def herdr(*args)
        answer = @shell_out_factory.call(@target.bin, *args, environment: @target.environment, timeout: TIMEOUT)
                                   .tap(&:run_command)
        unless Shell::Out.ok?(answer)
          raise Unavailable,
                "herdr #{args.first(3).join(" ")} failed: #{answer.stdout.strip} #{answer.stderr.strip}"
        end

        answer.stdout
      rescue SystemCallError, Shell::Out::Timeout => e
        raise Unavailable, "herdr could not run: #{e.message}"
      end
    end
  end
end
