# frozen_string_literal: true

module Lain
  module Frontend
    class TTY
      # What {Bell} hands a summoning note to while the `notify` layer is up: an
      # escape sequence the terminal turns into a desktop notification, then
      # tmux's message, then the `notify-feed` program. Each step is its own
      # failure domain -- a note rings after it is on the screen, so none may cost
      # the render or a later step. A deferred notifier keeps the first and last
      # steps for {#notify}, which a chat with an agent-state tracker calls once a
      # wait has outlasted its delay.
      class Notifier
        SOURCE = "lain"

        # Would end the sequence early, or break a feed record's line.
        CONTROL = /[[:cntrl:]]/

        ESC = "\e"

        # Hands a note's bytes to a {Countdown}'s writer lock, so an escape
        # sequence never interleaves with a tick, a menu or a streamed chunk.
        Drawn = Data.define(:countdown) do
          def print(bytes) = countdown.draw(bytes)

          def flush = nil
        end

        # @param env [#[]] the chat process's environment, read for the terminal's kind
        # @param feed [#call] takes source, title and body ({Notices::Feed})
        # @param tmux [#call] takes the note ({TmuxMessage})
        # @param output [#print, #flush] where the sequence is written; {TTY} rebinds it to its own writer
        # @param project [String, nil] named in the title; absent, the title is the source
        # @param mask [#call] takes the note's text and answers it with secrets masked
        # @param deferred [Boolean] whether {#call} leaves the sequence and the feed to {#notify}
        def self.for(env:, feed:, tmux: TmuxMessage.new, output: $stdout, project: nil, mask: :itself.to_proc,
                     deferred: false)
          new(sequence: sequence_for(env), wrap: !env["TMUX"].to_s.empty?, feed:, tmux:, output:, mask:,
              title: project.to_s.empty? ? SOURCE : project.to_s, deferred:, bound: [])
        end

        # The notifier a chat builds: the machine's `notify-feed`, and the text
        # masked with the secrets read afresh per note, so a value learned
        # mid-session is masked too.
        #
        # @param secrets [#to_a] answers the secret values known right now
        # @param project [#to_s] the project's root, whose basename is the feed title
        # @param env [#[]] the chat process's environment
        # @param output [#print, #flush] where the sequence is written
        # @param deferred [Boolean] see {.for}
        def self.for_chat(secrets, project, env: ENV, output: $stdout, deferred: false)
          mask = ->(text) { Sensitivity::TextMask.text(text, secrets:) }
          self.for(env:, feed: Notices.for(env:), project: File.basename(project.to_s), mask:, output:, deferred:)
        end

        def self.sequence_for(env)
          if env["TERM_PROGRAM"] == "iTerm.app" then ->(_title, text) { "#{ESC}]9;#{text}\a" }
          elsif !env["KITTY_WINDOW_ID"].to_s.empty? then ->(_title, text) { "#{ESC}]99;;#{text}#{ESC}\\" }
          else ->(title, text) { "#{ESC}]777;notify;#{title};#{text}\a" }
          end
        end
        private_class_method :sequence_for

        def initialize(**parts)
          @parts = parts
          @sequence, @wrap, @feed, @tmux, @output, @mask, @title, @deferred, @bound =
            parts.values_at(:sequence, :wrap, :feed, :tmux, :output, :mask, :title, :deferred, :bound)
        end

        # A deferred notifier remembers the last output it was bound to, because the terminal rebinds
        # its copy and the original is what the notices hold.
        #
        # @return [Notifier] this one writing to `output` instead
        def bound_to(output)
          self.class.new(**@parts, output:).tap { @bound.replace([_1]) }
        end

        # @return [nil]
        def call(note)
          text = plain(note)
          quietly { deliver(text) } unless @deferred
          quietly { @tmux.call(text) }
          nil
        end

        # The desktop notification and the feed entry, to the output the terminal bound.
        #
        # @return [nil]
        def notify(note)
          (@bound.first || self).deliver(plain(note))
          nil
        end

        protected

        def deliver(text)
          title = plain(@title)
          quietly { write(@sequence.call(title.tr(";", " "), text.tr(";", " "))) }
          quietly { @feed.call(SOURCE, title, text) }
        end

        private

        # Masked before it is cut, so a cut cannot split a secret into
        # something no mask recognises. The note is model-written.
        def plain(note) = @mask.call(note.to_s.scrub).gsub(CONTROL, " ")[0, TmuxMessage::LIMIT]

        def write(sequence)
          @output.print(@wrap ? "#{ESC}Ptmux;#{sequence.gsub(ESC, ESC * 2)}#{ESC}\\" : sequence)
          @output.flush
        end

        def quietly
          yield
        rescue StandardError
          nil
        end
      end
    end
  end
end
