# frozen_string_literal: true

require "async"

module Lain
  module Review
    class Queue
      # Hands a row's review to the chat running in the row's checkout, with
      # the row named beside it: lain-daemon pushes it to the newest attended
      # chat there, and that chat marks the row seen only when the human
      # presses Enter at the offer. A pull request with no local clone opens in
      # the browser instead, and nothing is sent.
      class Delivery
        # What became of a row. `chat` is the live record the offer went to,
        # `others` the other attended chats in that checkout, and `field` what
        # a refusing chat named.
        #
        # `outcome` is the chat's own answer (`:held`, `:crowded`, `:repeat`,
        # `:refused`), or `:silent` when the chat never gave one before the
        # daemon stopped waiting or the chat went away. This side's own are
        # `:browsed`, and for a checkout with no chat whatever {Pending#hold} answers.
        Result = Data.define(:outcome, :chat, :others, :field)

        REPLIES = %w[held crowded repeat refused].freeze
        UNOFFERED = "cannot offer the review through lain-daemon: %<reason>s"
        private_constant :REPLIES

        # @param account [#environment] the GitHub account `gh` runs as
        # @param pending [Pending] keeps the review for a checkout with no chat
        # @param notes [#puts] told why the daemon could not be asked
        # @param daemon [#call] answers a {Core::Client} or a {Daemon::Absent}; called once per row
        # @param shell_out_factory [#call] builds the `gh` runner
        def initialize(account:, pending:, notes:, daemon: -> { Daemon.ensure(paths: Paths.new) },
                       shell_out_factory: Shell::Out.public_method(:new))
          @account = account
          @pending = pending
          @notes = notes
          @daemon = daemon
          @shell_out_factory = shell_out_factory
        end

        # @param row [Row]
        # @param request [Request] the row's own, or one loaded from it with a focus
        # @return [Result]
        # @raise [Lain::Error] when `gh` cannot open a pull request in the browser
        def call(row, request = row.request)
          return browsed(request) if request.repo_root.nil?

          mark = Mark.of(row)
          answer = sent(request, mark)
          return result(@pending.hold(request, mark)) unless opened_by_chat?(answer)

          delivered(answer)
        end

        private

        # A chat with no editor answers `plain`: it showed nothing, so the review is held for a cockpit.
        def opened_by_chat?(answer) = answer&.fetch("session", nil) && answer["outcome"] != "plain"

        def result(outcome, chat: nil, others: [], field: nil)
          Result.new(outcome:, chat:, others:, field:)
        end

        def delivered(answer)
          outcome = REPLIES.include?(answer["outcome"]) ? answer["outcome"].to_sym : :silent
          result(outcome, chat: LiveSessions::Record.from_h(answer["session"]),
                          others: answer.fetch("others").map { |fields| LiveSessions::Record.from_h(fields) },
                          field: answer["field"])
        end

        # A daemon that cannot be asked is a checkout with no chat, so the review is held.
        def sent(request, mark)
          Sync do
            client = @daemon.call
            client.is_a?(Daemon::Absent) ? nil : offered(client, request, mark)
          end
        rescue StandardError => e
          @notes.puts(format(UNOFFERED, reason: e.message))
          nil
        end

        def offered(client, request, mark)
          client.call("offer.send", [{ "root" => request.repo_root, "request" => request.to_h, "row" => mark.to_h }])
        ensure
          client.stop
        end

        def browsed(request)
          url = request.to_h.fetch("url")
          shell = @shell_out_factory.call("gh", "pr", "view", "--web", url, environment: @account.environment)
                                    .run_command
          raise Error, "gh could not open #{url}: #{shell.stderr.to_s.strip}" unless Shell::Out.ok?(shell)

          result(:browsed)
        end
      end
    end
  end
end
