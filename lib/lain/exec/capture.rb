# frozen_string_literal: true

module Lain
  module Exec
    Capture = Data.define(:exit_status, :stdout, :stderr, :size, :ceiling)

    # What ran, in the shape {Tools::Bash.render_output} reads. Every backend
    # returns this rather than its transport's own object, which keeps the
    # rendering -- and so the output ceiling -- one decision instead of one per
    # transport.
    #
    # `size` is every byte the command printed, and it may exceed what
    # `stdout` and `stderr` hold: the in-process arm fills a {Bounded} capture
    # and keeps counting past what it retains. `ceiling` is the most output
    # the held bytes can stand for whole, so a renderer never passes off a cut
    # capture as a complete one. Handed neither, a capture counts the bytes it
    # holds and has no ceiling, which is the daemon arm's truth -- that arm
    # buffers the whole reply, and bounding it needs a change on the Rust side.
    class Capture
      def initialize(exit_status:, stdout:, stderr:, size: stdout.bytesize + stderr.bytesize,
                     ceiling: Float::INFINITY)
        super
      end

      # A capture being filled while its command runs. It holds at most one
      # byte past its ceiling of both streams together, so a capture that was
      # cut can never be read as one that fit, counts every byte, and forwards every
      # chunk to its stream's live sink, so the human watching still sees all of
      # it while the model is handed at most what was retained.
      #
      # The pipes keep being drained past the limit rather than the command
      # being killed there: a kill would replace the command's own exit status
      # with a signal's, and the status is the one fact a refusal still reports.
      #
      # The only mutable state on the exec seam, which is why it is filled by one
      # run and finished into a frozen {Capture}.
      class Bounded
        # @param ceiling [Integer] the most output the held bytes may stand for
        # @param stdout_sink [#<<] where stdout chunks are forwarded as they arrive
        # @param stderr_sink [#<<] where stderr chunks are forwarded as they arrive
        def initialize(ceiling:, stdout_sink: Sink::Null.new, stderr_sink: Sink::Null.new)
          @ceiling = ceiling
          @retain = ceiling + 1
          @sinks = { stdout: stdout_sink, stderr: stderr_sink }
          @held = { stdout: +"", stderr: +"" }
          @size = 0
        end

        # An empty buffer adopts the encoding of the first thing appended to it,
        # so a binary chunk keeps a binary payload byte-identical on every arm.
        #
        # @param stream [Symbol] `:stdout` or `:stderr`
        # @param chunk [String] bytes as they arrived
        # @return [self]
        def take(stream, chunk)
          room = @retain - held_bytes
          @held.fetch(stream) << chunk.byteslice(0, room) if room.positive?
          @size += chunk.bytesize
          @sinks.fetch(stream) << chunk
          self
        end

        # What a timeout carries in place of a result. Built from the retained
        # bytes alone, so a flood before the kill cannot reach the message; BINARY
        # pieces, so a high byte on one stream beside text on the other cannot
        # raise in place of the timeout. Whether it is text is the tool's call.
        #
        # @return [String]
        def report
          "---- Begin captured output ----\n" \
            "STDOUT: #{@held.fetch(:stdout).b}\nSTDERR: #{@held.fetch(:stderr).b}\n" \
            "---- End captured output ----"
        end

        # @param exit_status [Integer] the status the command reported
        # @return [Capture] frozen, holding what was retained and counting it all
        def finish(exit_status)
          Capture.new(exit_status:, stdout: @held.fetch(:stdout).freeze, stderr: @held.fetch(:stderr).freeze,
                      size: @size, ceiling: @ceiling)
        end

        private

        def held_bytes = @held.values.sum(&:bytesize)
      end
    end
  end
end
