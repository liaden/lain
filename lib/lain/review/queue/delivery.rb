# frozen_string_literal: true

require "socket"

module Lain
  module Review
    class Queue
      # Hands a row's review to the chat running in the row's checkout, over
      # that chat's input socket, and marks the row seen only when the chat
      # says it took the offer. A pull request with no local clone opens in
      # the browser instead, and nothing is sent.
      class Delivery
        # What became of a row. `chat` is the live record the offer went to,
        # `others` the other live chats in that checkout, `skipped` those whose
        # socket never greeted, and `field` what a refusing chat named.
        #
        # `outcome` is the chat's own answer (`:held`, `:crowded`, `:repeat`,
        # `:refused`), or `:silent` when a chat that greeted gave none, which
        # an older chat with no reply does. This side's own are `:browsed`, and
        # for a checkout with no chat whatever {Pending#hold} answers.
        Result = Data.define(:outcome, :chat, :others, :skipped, :field)

        REPLIES = %w[held crowded repeat refused].freeze
        # A chat greets the moment it accepts, so a short wait is enough to call
        # a silent socket dead. Its reply waits on rebuilding the line, and a
        # dirty tree's snapshot can take far longer than the greeting.
        GREETING = 5
        REPLY = 30
        private_constant :REPLIES

        # @param live_sessions [LiveSessions] the chats running now
        # @param log [Log] where a held row is marked seen
        # @param account [#environment] the GitHub account `gh` runs as
        # @param pending [Pending] keeps the review for a checkout with no chat
        # @param shell_out_factory [#call] builds the `gh` runner
        # @param greeting [Numeric] seconds a socket has to greet; its reply then has {REPLY}
        def initialize(live_sessions:, log:, account:, pending:, shell_out_factory: Shell::Out.public_method(:new),
                       greeting: GREETING)
          @live_sessions = live_sessions
          @log = log
          @account = account
          @shell_out_factory = shell_out_factory
          @greeting = greeting
          @pending = pending
        end

        # @param row [Row]
        # @param request [Request] the row's own, or one loaded from it with a focus
        # @return [Result]
        # @raise [Lain::Error] when `gh` cannot open a pull request in the browser
        def call(row, request = row.request)
          return browsed(request) if request.repo_root.nil?

          chats = @live_sessions.in(request.repo_root).select(&:input_socket)
          chat, at, io = chats.each_with_index.lazy.map { |live, index| [live, index, greeted(live)] }.find(&:last)
          skipped = chats.take(at || chats.size)
          return result(@pending.hold(request), skipped:) unless io

          offered(row, request, io).with(chat:, others: chats - skipped - [chat], skipped:)
        end

        private

        def result(outcome, chat: nil, others: [], skipped: [], field: nil)
          Result.new(outcome:, chat:, others:, skipped:, field:)
        end

        def browsed(request)
          url = request.to_h.fetch("url")
          shell = @shell_out_factory.call("gh", "pr", "view", "--web", url, environment: @account.environment)
                                    .run_command
          raise Error, "gh could not open #{url}: #{shell.stderr.to_s.strip}" unless Shell::Out.ok?(shell)

          result(:browsed)
        end

        # A socket is trusted with the offer only once it has said hello, so
        # one that never would is skipped with nothing sent to it.
        def greeted(live)
          io = UNIXSocket.new(live.input_socket)
          return io if awaited(io, "context", @greeting)

          io.close
          nil
        rescue IOError, SystemCallError
          nil
        end

        def offered(row, request, io)
          io.write(CLI::InputSocket::Codec.dump({ "v" => "offer", "request" => request.to_h }))
          reply = awaited(io, "offered", REPLY) || {}
          outcome = REPLIES.include?(reply["outcome"]) ? reply["outcome"].to_sym : :silent
          seen(row) if outcome == :held
          result(outcome, field: reply["field"])
        rescue IOError, SystemCallError
          result(:silent)
        ensure
          io.close
        end

        def seen(row) = @log.append(Log::Event.new(kind: :opened, at: nil, row_id: row.id, head_sha: row.head_sha))

        # The first frame of `kind` before the deadline; the chat's prompt
        # frames reach every client, this one included, and are passed over.
        def awaited(io, kind, bound)
          io.timeout = bound
          deadline = clock + bound
          Enumerator.produce { line_before(io, deadline) }.lazy.take_while(&:itself)
                    .map { |line| CLI::InputSocket::Codec.load(line) }.find { |frame| frame&.fetch("v", nil) == kind }
        end

        def line_before(io, deadline)
          left = deadline - clock
          left.positive? && io.wait_readable(left) ? io.gets : nil
        rescue IOError, SystemCallError
          nil
        end

        def clock = RunClock::MONOTONIC.call
      end
    end
  end
end
