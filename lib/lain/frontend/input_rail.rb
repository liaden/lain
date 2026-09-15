# frozen_string_literal: true

module Lain
  module Frontend
    # The one way human input reaches a chat. The chat PUBLISHES a prompt when
    # it wants a line and waits here; a producer -- the in-process
    # {StdinPump}, or anything else that can see what was published -- answers
    # with a line stamped with the generation it was typed at. Signals skip the
    # queue and reach the routed sink at once, as an OS signal would.
    #
    # ONE RULE replaces the typeahead guards that grew around a shared stdin: a
    # line whose generation predates the prompt it arrives at was begun before
    # that prompt was drawn, so it is HELD and is never the answer to a prompt a
    # run waits on. A held line becomes the next `you>` line once the prompts
    # ahead of it close. A prompt that answers nothing -- `you>`, `command>` --
    # takes such a line, because what the human typed ahead of it is what they
    # reached for.
    #
    # Readers are served one at a time, in the order they asked, so two prompts
    # are never drawn over each other. A producer is TOLD when a prompt is
    # published or withdrawn, and waits rather than asks. Shared across threads
    # and fibers alike: the state sits under a mutex that is never held across a
    # wait.
    class InputRail
      KINDS = %i[you human approval command].freeze

      # The kinds a run is parked on.
      ANSWERS = %i[human approval].freeze

      # {CLI::Shutdown}'s inputs a producer may send.
      SIGNALS = %i[sigint sigterm sigquit cancel extend wait_responses].freeze

      Prompt = Data.define(:kind, :text, :header, :generation)
      Line = Data.define(:text, :generation)
      Signal = Data.define(:name)
      Eof = Data.define

      # The rail with nothing published. Generation 0 is before every prompt.
      module Unpublished
        def self.generation = 0
        def self.kind = nil
      end

      # The rail nobody is watching: holds and closings are told to no one.
      module Unseen
        def self.render_held(_text) = nil
        def self.close_prompt(_text) = nil
      end

      # An answer, including the answer nobody gave -- a `nil` text -- which is
      # why "not yet" needs a value of its own, and why a line that ended the
      # drawing it came from is told apart from one that did not.
      Heard = Data.define(:text)
      REDRAWN = Object.new.freeze
      STILL_DRAWN = Object.new.freeze
      private_constant :Heard, :REDRAWN, :STILL_DRAWN

      # @param screen [#render_held, #close_prompt] where the human is told a
      #   line was held, and where a withdrawn prompt's line is ended
      def initialize(screen: Unseen)
        @screen = screen
        @inbound = Thread::Queue.new
        @lock = Thread::Mutex.new
        @turns = []
        @held = []
        @producers = {}
        @published = Unpublished
        @generation = 0
        @sink = CLI::Signals::NULL
      end

      # A producer's value. A signal is delivered on the producer's stack; a
      # line or an end of stream waits for the reader whose prompt it answers.
      def <<(value)
        value.is_a?(Signal) ? @sink.signal(value.name) : @inbound.push(value)
        self
      end

      # Where a signal from a producer lands -- {CLI::Signals}' sink duck, routed
      # alongside the OS traps.
      def route(sink)
        @sink = sink
        self
      end

      # The prompt a producer should be drawing now, or {Unpublished}.
      def published = @lock.synchronize { @published }

      def open?(prompt) = published.generation == prompt.generation

      # A producer, which is asked what was typed while nothing was drawn and
      # told whenever what is published changes.
      #
      # @return [Thread::SizedQueue] popped to wait for the next change; one
      #   waiting change stands for any number, so a slow producer never falls
      #   behind a burst of them
      def attach(producer)
        told = Thread::SizedQueue.new(1)
        @lock.synchronize { @producers[producer] = told }
        told
      end

      def detach(producer) = @lock.synchronize { @producers.delete(producer) }

      # Asks every producer for what was typed with no prompt drawn -- a standing
      # goal drives turns with none open -- so it is held before the next turn.
      def gather = @lock.synchronize { @producers.keys }.each(&:sweep)

      # Keep a line for `you>`, and say so: a line nobody was told about reads as
      # swallowed.
      def hold(text)
        @lock.synchronize { @held << text }
        @screen.render_held(text)
      end

      # The oldest held line, or nil.
      def take_held = @lock.synchronize { @held.shift }

      # Wait for this reader's turn, publish its prompt, and answer with the line
      # typed at it, or nil when the stream ended under it.
      #
      # @param kind [Symbol] one of {KINDS}
      # @param text [String] the prompt's words; an object that also answers
      #   `takes?(line)` refuses a line it is not an answer to, and one that
      #   answers `closed` ends its own line when it is withdrawn
      # @param header [String] what a producer draws above the prompt's line
      # @return [String, nil]
      def read(kind, text, header: "")
        gate = Thread::Queue.new
        enter(gate)
        (take_held if kind == :you) || answered(Prompt.new(kind:, text:, header:, generation: 0), text)
      ensure
        leave(gate)
      end

      private

      # The prompt's line is ended HERE, as the reader stops, and not by the
      # producer once it notices: a reader is stopped from inside another
      # fiber's unwind, and anything that yields there lets the chat write past
      # the prompt before its closing words.
      def answered(asked, text)
        prompt = publish(asked)
        heard = Enumerator.produce do
          judged = judge(prompt, text, @inbound.pop)
          prompt = publish(asked) if judged.equal?(REDRAWN)
          judged
        end
        heard.lazy.grep(Heard).first.text
      ensure
        withdraw(prompt)
        @screen.close_prompt(text)
      end

      # A line the prompt cannot take is held. One that ENDED this prompt's
      # drawing -- typed at it, or begun before an answer's prompt drew -- means
      # the prompt is published again under a fresh generation, so it opens
      # again empty. One typed at a prompt that has since gone ended nothing that
      # is drawn now, and the drawing carries on.
      def judge(prompt, text, value)
        return Heard.new(text: nil) if value.is_a?(Eof)
        return Heard.new(text: value.text) if answers?(prompt, text, value)

        hold(value.text)
        stale?(prompt, value) ? STILL_DRAWN : REDRAWN
      end

      def answers?(prompt, text, line)
        typed_at_it = line.generation == prompt.generation || (line.generation.zero? && !prompt.answer?)
        typed_at_it && (!text.respond_to?(:takes?) || text.takes?(line.text))
      end

      # Typed at an earlier prompt that did not take it, where an answer's
      # prompt would have held a line begun before it drew.
      def stale?(prompt, line) = !prompt.answer? && line.generation.positive? && line.generation < prompt.generation

      def publish(asked)
        published = @lock.synchronize { @published = asked.with(generation: @generation += 1) }
        tell
        published
      end

      def withdraw(prompt)
        @lock.synchronize { @published = Unpublished if @published == prompt }
        tell
      end

      def tell = @lock.synchronize { @producers.values }.each { |told| nudge(told) }

      # Never blocks: a change already waiting says everything a second would.
      def nudge(told)
        told.push(true, true)
      rescue ThreadError
        nil
      end

      # FIFO: the head reads, the rest wait on their own gate until it is theirs.
      def enter(gate)
        head = @lock.synchronize { @turns.push(gate).first.equal?(gate) }
        gate.pop unless head
      end

      def leave(gate)
        @lock.synchronize do
          head = @turns.first.equal?(gate)
          @turns.delete_if { |turn| turn.equal?(gate) }
          @turns.first&.push(true) if head
        end
      end
    end

    class InputRail
      # Reopened for the values' validation, since a constant defined inside a
      # `Data.define` block belongs to the enclosing class instead.
      class Prompt
        def initialize(kind:, text:, generation:, header: "")
          raise ArgumentError, "#{kind.inspect} is not a prompt kind (#{KINDS.join(", ")})" unless KINDS.include?(kind)

          super(kind:, text: String.new(text).freeze, header: String.new(header).freeze, generation:)
        end

        def answer? = ANSWERS.include?(kind)
      end

      # What was typed, and the generation of the prompt drawn when typing began.
      class Line
        def initialize(text:, generation:) = super(text: String.new(text).freeze, generation:)
      end

      # A {CLI::Shutdown} input, by name.
      class Signal
        def initialize(name:)
          raise ArgumentError, "#{name.inspect} is not a signal (#{SIGNALS.join(", ")})" unless SIGNALS.include?(name)

          super
        end
      end
    end
  end
end
