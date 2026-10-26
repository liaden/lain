# frozen_string_literal: true

require "io/console"
require "strscan"

module Lain
  module Frontend
    # The human's side of `lain gateway`: each request is shown whole and
    # waits for a yes. The only gateway file that writes to a terminal.
    #
    # JSON lets a body put any amount of whitespace between its tokens, and a
    # string any amount of characters that draw as nothing, and enough of
    # either scrolls the payload off the screen before the question. So a long
    # run of them, or a stack of blank lines, is shown as a count, and the
    # question repeats the endpoint and the size.
    class GatewayConsole
      AFFIRMATIVE = /\Ay(es)?\z/i
      HEADER = "\n--- POST %<endpoint>s, %<bytes>d bytes\n"
      FLAGGED = "flagged: %<reasons>s\n"
      QUESTION = "\nForward POST %<endpoint>s, %<bytes>d bytes? [y/N] "
      ANNOUNCE = "lain gateway: %<url>s\ntoken: %<token_file>s\nlog: %<log>s\n"
      CAVEAT = "note: %<caveat>s\n"
      # A string with its escapes, or the rest of an unterminated one.
      STRING = /"(?:[^"\\]|\\.)*"?/m
      BLANK = /[ \t\r\n]+/
      # Longer than any indentation a pretty-printer writes.
      LONGEST_RUN = 16
      # Characters that draw as nothing, where JSON allows them raw: inside a string.
      INVISIBLE = /[\p{Zs}\u2800\u3164\u115F\u1160\uFFA0]{#{LONGEST_RUN + 1},}/
      NEWLINES = /\A\n+\z/

      # The human's input ended, so no answer can be read.
      class Unanswered < Lain::Error; end

      # @param input [#gets] where the human's answer is read; the gateway is no
      #   chat, so it reads its own terminal rather than an Intake
      # @param output [#write] where the request and the question are shown
      def initialize(input:, output:)
        @input = input
        @output = output
        @lock = Mutex.new
      end

      # @param url [String] the gateway's URL, which carries no token
      # @param token_file [String] where the chat reads the token; the token itself is never shown
      # @param log [String] the gateway's own log
      # @param caveats [Array<String>] what this gateway does not check, said once at start
      # @return [void]
      def announce(url:, token_file:, log:, caveats: [])
        @lock.synchronize do
          show(format(ANNOUNCE, url:, token_file:, log:) + caveats.map { format(CAVEAT, caveat: _1) }.join)
        end
      end

      # @param request [Gateway::Server::Request]
      # @return [Boolean] whether the human said to forward it
      # @raise [Unanswered] at the end of input
      def approve?(request)
        @lock.synchronize do
          show(shown(request))
          discard_typeahead
          answer = @input.gets or raise Unanswered, "the console's input has ended"
          AFFIRMATIVE.match?(answer.strip)
        end
      end

      private

      # A file or a pipe buffers, and the question has no newline to flush it.
      def show(text)
        @output.write(text)
        @output.flush
      end

      def shown(request)
        flagged = request.flagged.empty? ? "" : format(FLAGGED, reasons: request.flagged.join("; "))
        named = { endpoint: legible(request.endpoint), bytes: request.bytes }
        format(HEADER, **named) + flagged + legible(condensed(Utf8.legible(request.body))) + format(QUESTION, **named)
      end

      def condensed(text)
        scanner = StringScanner.new(text)
        shown = +""
        shown << (string(scanner.scan(STRING)) || between(scanner.scan(BLANK)) || scanner.getch) until scanner.eos?
        shown
      end

      def string(text) = text&.gsub(INVISIBLE) { counted(_1) }

      def between(run)
        return run unless run && (run.size > LONGEST_RUN || run.count("\n") > 1)

        counted(run)
      end

      def counted(run)
        noun = run.match?(NEWLINES) ? "newline" : "blank character"
        "[#{run.size} #{noun}#{"s" unless run.size == 1}]"
      end

      # A line typed while an earlier request was on screen must not answer this one.
      def discard_typeahead
        @input.iflush if @input.respond_to?(:tty?) && @input.tty?
      end

      def legible(text) = Project::Trust.legible(Utf8.legible(text))
    end
  end
end
