# frozen_string_literal: true

module Lain
  class Sensitivity
    # The live copy of a command's output, masked at the boundary that hands a
    # tool its sinks, so the tool itself holds no masking code.
    #
    # Bytes are attributed to their tool_use_id as produced, rather than
    # reconstructed afterwards from a buffer shared with whatever else is
    # running; {Lain::Channel} says why that would destroy provenance.
    #
    # It holds no channel of its own: the sinks are built over the
    # invocation's, so what is shown and where it goes cannot disagree. A Null
    # channel displays nothing, so it is answered with Null sinks and no
    # detection runs; a child's output can be a megabyte nobody sees.
    #
    # Each call numbers its live placeholders from 1, one count across both
    # streams. The model's copy is numbered by {Middleware::RedactSecretReads}
    # by position in the result text: 2 numberings of the same masked bytes.
    class Display
      # @param child_env [Exec::ChildEnv] the launch's child environment, the
      #   one the result masker is built from
      def initialize(child_env:)
        @child_env = child_env
      end

      # @param invocation [Tool::Invocation] the call whose output is shown
      # @return [Hash{Symbol => #<<}] `stdout_sink:` and `stderr_sink:`
      def sinks(invocation)
        return Null::SINKS if invocation.channel.is_a?(Channel::Null)

        mask = TextMask.new(secrets: Secrets.for(child_env: @child_env, context: invocation.context))
        ordinals = (1..).each
        %i[stdout stderr].to_h do |stream|
          adapter = Sink::IOAdapter.new(invocation.channel, tool_use_id: invocation.tool_use_id, stream:)
          [:"#{stream}_sink", MaskedSink.new(adapter, mask.stream(ordinals:))]
        end
      end

      # Shows nothing, whatever the channel: the default for an interpreter
      # nobody wired a display into.
      class Null
        SINKS = { stdout_sink: Sink::Null.new.freeze, stderr_sink: Sink::Null.new.freeze }.freeze

        # @param _invocation [Tool::Invocation]
        # @return [Hash{Symbol => Sink::Null}]
        def sinks(_invocation) = SINKS
      end

      NULL = Null.new.freeze

      # A live sink showing a {TextMask::Stream}'s masked text rather than the
      # bytes it is handed, up to {CAP}.
      #
      # Masking runs on the thread that drains the command's pipes, at a few
      # megabytes a second, so past the cap nothing is masked or shown: a flood
      # is not slowed, and nothing unmasked is drawn. The chunk that crosses the
      # cap is dropped whole.
      class MaskedSink
        CAP = 1024 * 1024
        NOTE = "[the live display stopped here; the result is bounded as before]\n"

        # @param sink [#<<] where the masked text goes
        # @param stream [TextMask::Stream]
        def initialize(sink, stream)
          @sink = sink
          @stream = stream
          @seen = 0
        end

        # @param chunk [String] bytes as the command printed them
        # @return [self]
        def <<(chunk)
          @seen += chunk.bytesize
          if @seen <= CAP
            @sink << (@stream << chunk)
          elsif @stream
            stop
          end
          self
        end

        # Terminal, not a mid-run flush: a sink serves one call, and Bash's
        # ensure closes it once the command stops, however it stopped, so the
        # held rest of a line is shown masked.
        #
        # @return [self]
        def flush
          @sink << @stream.finish if @stream
          @stream = nil
          self
        end

        private

        def stop
          rest = @stream.finish
          @stream = nil
          @sink << rest
          @sink << (rest.empty? || rest.end_with?("\n") ? NOTE : "\n#{NOTE}")
        end
      end
    end
  end
end
