# frozen_string_literal: true

module Lain
  module Frontend
    # The way a typed human line reaches a chat, and so the one place its record
    # is kept; an nvim C-g compose is the exception, settled by the compose
    # buffer and recorded as its marker. The chat PUBLISHES a prompt when it wants a line and waits here;
    # a producer -- the in-process {StdinPump}, the input pane's socket, or
    # anything else that can see what was published -- answers with a line
    # stamped with the generation it was typed at. Signals skip the queue and
    # reach the routed sink at once, as an OS signal would.
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
    # are never drawn over each other -- with one exception, for an answer a run
    # waits on: it goes ahead of any `you>` still waiting, and it takes the
    # terminal from a drawn `you>` its producers say nothing was typed at, which
    # is published again once the answers ahead of it close. Otherwise a chat at
    # rest would show a parked call only when the human next pressed Enter. A
    # reader that must wait is told to the screen, and so is one that leaves
    # without its prompt ever being published. A producer is TOLD when a prompt is
    # published or withdrawn, and waits rather than asks. Shared across threads
    # and fibers alike: the state sits under a mutex that is never held across a
    # wait.
    #
    # HISTORY IS KEPT HERE, as a line leaves for `you>`, because no producer
    # sees what this object does: which prompt a line finally answered, and the
    # whole of it. An answer a run waited on is never kept; a line read at
    # `command>` or a countdown is kept only if it is held and reaches `you>`,
    # so it is kept once. The writing is the injected `history:`'s, which is why
    # nothing here opens a file.
    class Intake
      # `countdown` is the shutdown window drawn as a prompt, for a producer
      # that is not at the chat's own terminal: it answers with one of the
      # prompt's `keys` as a {Signal}, never with a line.
      KINDS = %i[you human approval command countdown].freeze

      # The kinds a run is parked on.
      ANSWERS = %i[human approval].freeze

      # The one kind whose lines are history: what a recall at `you>` puts back.
      RECALLED = :you

      # {CLI::Shutdown}'s inputs a producer may send.
      SIGNALS = %i[sigint sigterm sigquit cancel extend wait_responses stop].freeze

      # The line that is not a line. While an ask is in flight the prompt in
      # front of the human belongs to whatever that ask parked on, so typing is
      # a producer's only way to reach the run -- and a line typed there is
      # either that prompt's answer or held for later, neither of which stops
      # anything. So this one leaves as a {Signal} instead, landing where an OS
      # signal lands.
      #
      # Two exceptions, and both are "there is no ask to stop": `you>`, which
      # is read only between asks, and a sink with nothing supervised behind
      # it -- a slash command driving its own work. In both it stays an
      # ordinary line, answering the prompt or held and said, and the command
      # of that name is what tells the human nothing was running.
      STOP = "/stop"

      Prompt = Data.define(:kind, :text, :header, :keys, :generation)
      Line = Data.define(:text, :generation)
      Signal = Data.define(:name)
      Eof = Data.define

      # The rail with nothing published. Generation 0 is before every prompt.
      module Unpublished
        def self.generation = 0
        def self.kind = nil
        def self.text = ""
        def self.header = ""
        def self.keys = {}
      end

      # The rail nobody is watching: holds and closings are told to no one.
      module Unseen
        def self.render_held(_text) = nil
        def self.close_prompt(_text) = nil
        def self.queue_prompt(_text) = nil
        def self.drop_prompt(_text) = nil
      end

      # The rail that keeps no history: a pane's local mirror, whose lines are
      # kept by the chat they are sent on to, and a chat nobody types into.
      module Unrecorded
        def self.remember(_line) = nil
      end

      # An answer, including the answer nobody gave -- a `nil` text -- which is
      # why "not yet" needs a value of its own, and why a line that ended the
      # drawing it came from is told apart from one that did not.
      Heard = Data.define(:text)
      REDRAWN = Object.new.freeze
      STILL_DRAWN = Object.new.freeze
      STEPPED_ASIDE = Object.new.freeze

      # What an answer's reader sends the `you>` it takes the terminal from,
      # naming the drawing it meant: one that reaches a later prompt is stale.
      Preempt = Data.define(:generation)

      # One reader's place in line: the prompt it asks, whether it had to wait,
      # and whether its prompt was ever published.
      Turn = Struct.new(:gate, :kind, :text, :waited, :published) do
        def answer? = ANSWERS.include?(kind)
      end
      private_constant :Heard, :REDRAWN, :STILL_DRAWN, :STEPPED_ASIDE, :Preempt, :Turn

      # @param screen [#render_held, #close_prompt, #queue_prompt, #drop_prompt]
      #   where the human is told a line was held, where a withdrawn prompt's
      #   line is ended, and where a prompt waiting its turn is announced and,
      #   leaving unpublished, said to have gone
      # @param history [#remember] takes each line that reaches `you>`, whole --
      #   {Discretion} in a chat someone types into
      def initialize(screen: Unseen, history: Unrecorded)
        @screen = screen
        @history = history
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
        sent = stops_a_run?(value) ? Signal.new(name: :stop) : value
        sent.is_a?(Signal) ? @sink.signal(sent.name) : @inbound.push(sent)
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

      # {#published}, read without the lock, for a signal trap: a Mutex raises
      # in trap context, and one reference read cannot be torn.
      def glimpse = @published

      def open?(prompt) = published.generation == prompt.generation

      # A producer, which is asked what was typed while nothing was drawn and
      # whether anything has been typed at a prompt it draws (`untouched?`), and
      # told whenever what is published changes. It says when it has opened a
      # read at a prompt ({#opened}).
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

      # The oldest held line, taken for `you>`, or nil.
      def take_held = recalled(held_line)

      # A producer's word that its read at `prompt` has opened. Until then it
      # cannot say nothing was typed there, so an answer that arrived as `you>`
      # came back -- the second of two calls parked together is asked the
      # instant the first is answered -- waited behind it; it takes the
      # terminal now.
      def opened(prompt)
        waiting = @lock.synchronize { @turns.first&.kind == :you && @turns.drop(1).any?(&:answer?) }
        preempt(prompt) if waiting && prompt.kind == :you && open?(prompt) && untouched?(prompt)
        nil
      end

      # Wait for this reader's turn, publish its prompt, and answer with the line
      # typed at it, or nil when the stream ended under it.
      #
      # @param kind [Symbol] one of {KINDS}
      # @param text [String] the prompt's words; an object that also answers
      #   `takes?(line)` refuses a line it is not an answer to, and one that
      #   answers `closed` ends its own line when it is withdrawn
      # @param header [String] what a producer draws above the prompt's line
      # @param keys [Hash] single keys a producer may answer a `countdown` with,
      #   each naming one of {SIGNALS}
      # @return [String, nil]
      def read(kind, text, header: "", keys: {})
        turn = Turn.new(Thread::Queue.new, kind, text, false, false)
        enter(turn)
        asked = Prompt.new(kind:, text:, header:, keys:, generation: 0)
        kind == RECALLED ? recalled(held_line || answered(turn, asked, text)) : answered(turn, asked, text)
      ensure
        leave(turn)
        @screen.drop_prompt(text) if turn.waited && !turn.published
      end

      private

      def held_line = @lock.synchronize { @held.shift }

      def recalled(line)
        @history.remember(line) unless line.nil?
        line
      end

      # Read off what is published rather than off the line's own generation:
      # the question is what the human is looking at, and a `/stop` typed
      # anywhere but `you>` was typed while an ask held the terminal ({STOP}).
      # The sink is asked too, because a line lifted with no ask behind it
      # lands in {CLI::Signals::Null} and is gone -- neither the answer, nor
      # held, nor said -- which is worse than any prompt's refusal of it.
      #
      # Every read here is lock-free ({#glimpse}, not {#published}), so a real
      # `Signal.trap` body calling `#<<` is safe whatever the conjuncts'
      # order.
      def stops_a_run?(value)
        value.is_a?(Line) && value.text.strip == STOP && glimpse.kind != :you && @sink.ask_in_flight?
      end

      # The prompt's line is ended HERE, as the reader stops, and not by the
      # producer once it notices: a reader is stopped from inside another
      # fiber's unwind, and anything that yields there lets the chat write past
      # the prompt before its closing words.
      def answered(turn, asked, text)
        turn.published = true
        prompt = publish(asked)
        heard = Enumerator.produce do
          judged = judge(prompt, text, @inbound.pop)
          judged = back_from_aside(turn, prompt) if judged.equal?(STEPPED_ASIDE)
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
        return value.generation == prompt.generation ? STEPPED_ASIDE : STILL_DRAWN if value.is_a?(Preempt)
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

      # The head reads, the rest wait on their own gate until it is theirs. A
      # prompt repeating one already in line -- `/approve` asking about the call
      # the watcher asks about -- is one arrival for the human, not two.
      def enter(turn)
        ahead = @lock.synchronize { line_up(turn) }
        return if ahead.empty?

        turn.waited = true
        announced = ahead.any? { |waiting| about(waiting.text) == about(turn.text) }
        @screen.queue_prompt(turn.text) unless (turn.answer? && preempted?(ahead)) || announced
        turn.gate.pop
      end

      # What a prompt is ABOUT -- the parked call, for a `[y/N]` -- so two
      # readers asking about one call announce it once, and two calls that read
      # identically still announce twice. A prompt that says nothing is its own
      # subject.
      def about(text) = text.respond_to?(:about) ? text.about : text

      # An answer goes ahead of every `you>` still waiting; anything else joins the end.
      def line_up(turn)
        at = (turn.answer? && @turns.each_index.find { |i| i.positive? && @turns[i].kind == :you }) || @turns.size
        @turns.insert(at, turn).take(at)
      end

      # Only the head is ahead, it is a drawn `you>`, and every producer drawing
      # it says nothing has been typed there. The head is told through the queue
      # it is reading, which is the one thing it is waiting on.
      def preempted?(ahead)
        prompt = published
        return false unless ahead.size == 1 && ahead.first.kind == :you && prompt.kind == :you && untouched?(prompt)

        preempt(prompt)
        true
      end

      # A key the human types between the producer saying nothing was typed and
      # the `you>` read being stopped may be dropped with that read, a window
      # well under a millisecond. It is never an answer: the prompt taking the
      # terminal sweeps what was typed before it drew.
      def preempt(prompt) = @inbound.push(Preempt.new(generation: prompt.generation))

      def untouched?(prompt)
        producers = @lock.synchronize { @producers.keys }
        !producers.empty? && producers.all? { |producer| producer.untouched?(prompt) }
      end

      # The preempted `you>` withdraws, gives the head to the answers now ahead
      # of it, and waits for them to close. A line held meanwhile -- a `/`-line
      # typed at the `[y/N]` -- was typed before anything typed at `you>` once it
      # is back, so it is the answer; otherwise `you>` is published again.
      def back_from_aside(turn, prompt)
        withdraw(prompt)
        @lock.synchronize do
          @turns.delete_if { |waiting| waiting.equal?(turn) }
          @turns.insert(@turns.index { |waiting| !waiting.answer? } || @turns.size, turn)
          @turns.first.gate.push(true)
        end
        turn.gate.pop
        held = held_line
        held ? Heard.new(text: held) : REDRAWN
      end

      def leave(turn)
        @lock.synchronize do
          head = @turns.first.equal?(turn)
          @turns.delete_if { |waiting| waiting.equal?(turn) }
          @turns.first&.gate&.push(true) if head
        end
      end
    end

    class Intake
      # Reopened for the values' validation, since a constant defined inside a
      # `Data.define` block belongs to the enclosing class instead.
      class Prompt
        def initialize(kind:, text:, generation:, header: "", keys: {})
          raise ArgumentError, "#{kind.inspect} is not a prompt kind (#{KINDS.join(", ")})" unless KINDS.include?(kind)

          super(kind:, text: String.new(text).freeze, header: String.new(header).freeze,
                keys: keys.to_h { |key, name| [String.new(key.to_s).freeze, name.to_sym] }.freeze, generation:)
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
