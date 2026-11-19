# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/resume [SESSION]`: ends this chat through the {Quit} exit while the cockpit's tmux server
      # respawns the chat pane with `--resume` on the named session, as {Clear} does for a fresh one.
      # Named so it cannot shadow {CLI::Resume}.
      class ResumeSession
        USAGE = "/resume [SESSION] -- restart this chat in the same cockpit on a closed or dead session " \
                "(the newest unclosed one when none is named)"

        # @param dir [String] the project's session directory
        # @param pane [String, nil] the pane this chat runs in
        # @param restart [#call] schedules the respawn; answers false outside a cockpit
        # @param probe [Liveness::Probe] asks whether the session's writer still runs
        def initialize(dir:, pane: ENV.fetch("TMUX_PANE", nil), restart: Up.method(:respawn_chat),
                       probe: Liveness::Probe.new)
          @selector = Resume::Selector.new(dir:, probe:)
          @probe = probe
          @pane = pane
          @restart = restart
          freeze
        end

        def name = "resume"

        def usage = USAGE

        def returns_action?(_args) = true

        def call(args, env)
          path = chosen(args.to_s.strip, env)
          session = File.basename(path)
          refuse_live(path, session)
          raise Error, plain_chat_refusal(session) unless restarting?(session)

          :restart
        end

        private

        def chosen(name, env)
          return @selector.call(name) unless name.empty?

          @selector.unclosed(except: env.journal_path) or raise Error, stays("no unclosed session to resume")
        rescue Resume::Refusal => e
          raise Error, stays(e.message)
        end

        def stays(reason) = "#{reason}, so this chat stays"

        # A live writer would make the resumed chat a second writer of the same file.
        def refuse_live(path, session)
          writer = Liveness::Writer.from_header(Resume.header(path))
          return unless writer.verdict(@probe) == :live

          raise Error, stays("#{session} is still open in process #{writer.pid}")
        end

        # Quitting without a waiter armed would leave a dead pane, so a tmux that refuses keeps the chat.
        def restarting?(session)
          @restart.call(pane: @pane, extra: ["--resume", session])
        rescue Up::TmuxUnavailable => e
          raise Error, "the restart could not be set up, so this chat stays: #{e.message}"
        end

        def plain_chat_refusal(session)
          stays("/resume restarts the chat pane of a `lain up` cockpit, and this plain chat has no cockpit pane " \
                "to restart -- run `lain chat --resume #{session}`")
        end
      end
    end
  end
end
