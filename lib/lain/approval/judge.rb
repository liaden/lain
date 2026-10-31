# frozen_string_literal: true

require "async"

module Lain
  module Approval
    # One bounded question to the `auto_approver` role: may this call run?
    # {Judged} asks it on the live gate path, so it waits
    # with the call unparked and must answer within {TIMEOUT} whatever the
    # child does.
    #
    # Only a lone verdict token is a verdict. Prose, a hedge or an empty answer
    # is `:defer`; an error result, a raise or the bound running out is
    # `:fault`, because then nobody judged the call at all.
    class Judge
      # The bound matters only for a hung judge: an unsure one answers defer
      # as soon as it says so.
      TIMEOUT = 30

      # A fresh root over the shared Store, so the judge reads only the call.
      ROLE = :auto_approver
      CONTEXT_MODE = :fresh

      # Where the call runs, as the judge is told it. `requester` is the label
      # the gate knows the asker by, which an announced child takes from its role.
      #
      # @!attribute [r] root
      #   @return [String] the project root
      # @!attribute [r] cwd
      #   @return [String] the directory the call runs in
      # @!attribute [r] requester
      #   @return [String]
      # @!attribute [r] outside
      #   @return [Array<String>] absolute paths the call names beyond the project root
      # @!attribute [r] facts
      #   @return [Facts] what lain resolved the call's stages to; none by default
      # @!attribute [r] request
      #   @return [Request, nil] what the call was made for; none by default
      # @!attribute [r] human_checkout
      #   @return [String, nil] the human's checkout, when the call runs in a tree of its own
      Place = Data.define(:root, :cwd, :requester, :outside, :facts, :request, :human_checkout) do
        def initialize(facts: Facts::NONE, request: nil, human_checkout: nil, **rest) = super
      end

      Request = Data.define(:text, :model_written)

      # What a call was made for, told to the judge on a line of its own. A
      # child's task is the parent model's words, so the judge is told it is
      # not the human's. The text is inspected, so a line break in it cannot
      # forge a header line.
      #
      # @!attribute [r] text
      #   @return [String]
      # @!attribute [r] model_written
      #   @return [Boolean] whether a model wrote it rather than the human
      class Request
        # @return [String]
        def to_s = "#{whose}: #{text.inspect}"

        private

        def whose = model_written ? "the parent agent's task (model-written)" : "the user's request"
      end

      # The request source of a run without the request arm: no call is told what it was made for.
      module Unrequested
        # @return [nil]
        def self.call(_context) = nil
      end

      # What a Repl tells when no judge reads what the human asked for.
      module Unheard
        # @return [nil]
        def self.remember(_line) = nil
      end

      # The request source under the request arm. The human's last line is
      # what the Repl last handed the model -- a compose settled, a `--prompt`
      # seed included, a command never -- and a child's task is read off the
      # context that names the child, so a child is never told the human's line
      # as its own.
      #
      # The line is kept whole, including what {Frontend::Intake::Discretion}
      # withholds from the history file: the judge runs on the chat's own
      # provider, which already holds it.
      class Heard
        def initialize
          @line = nil
        end

        # @param line [String]
        # @return [void]
        def remember(line)
          @line = -line.to_s
        end

        # @param context [Object] as {Middleware::Gate} threads it through
        # @return [Request, nil]
        def call(context)
          return task_of(context) if context.respond_to?(:task)

          @line && Request.new(text: @line, model_written: false)
        end

        private

        def task_of(context) = context.task && Request.new(text: context.task, model_written: true)
      end

      # Stops the judge's clock while its child queues for a provider slot, so
      # a judge asked while other agents hold every slot is not faulted for
      # their work. The clock stops only while some caller of the child queues
      # and none holds a slot, since holding a slot is the judge's own work.
      # One budget per call bounds every pause together; once spent, queueing
      # counts again.
      class Pause
        # @param timer [Async::Timeout] the judge's bound
        # @param budget [Numeric] seconds of queueing that may go uncounted
        def initialize(timer, budget)
          @timer = timer
          @budget = budget
          @thread = Thread.current
          @queued = 0
          @inside = 0
          @since = nil
          @closed = false
        end

        # @return [void]
        def entering = shift { @queued += 1 }

        # @return [void]
        def admitted
          shift do
            @queued -= 1
            @inside += 1
          end
        end

        # @return [void]
        def abandoned = shift { @queued -= 1 }

        # @return [void]
        def released = shift { @inside -= 1 }

        # A caller still running after the judge returns must not reschedule its cancelled timer.
        # @return [void]
        def close
          @closed = true
        end

        private

        # Fiber storage reaches a thread the child starts, and an Async timer
        # is not safe to move from another thread.
        def live? = !@closed && Thread.current.equal?(@thread)

        def shift
          return unless live?

          yield
          # A fired timer re-armed while the judge unwinds would raise again into an ensure.
          return unless @timer.duration.positive?

          @queued.positive? && @inside.zero? ? stop : start
        end

        def stop
          return if @since

          @since = @timer.now
          @timer.duration += @budget
        end

        def start
          return unless @since

          @budget = [@budget - (@timer.now - @since), 0].max
          # What is left is the held time, less any queueing past the budget.
          @timer.duration -= @budget
          @since = nil
        end
      end
      private_constant :Pause

      VERDICT = /\A(approve|deny|defer)\.?\z/i
      IGNORED = ->(_cause) {}
      private_constant :VERDICT, :IGNORED

      # @param role_spawn [#never_parking] the
      #   `(role, context_mode, prompt) -> Tool::Result` seam ({Skill::RoleSpawn})
      # @param timeout [Numeric] seconds the judge may take
      # @param pause_budget [Numeric] seconds its child may spend queued for a
      #   provider slot without them counting against `timeout`, summed over the call
      def initialize(role_spawn:, timeout: TIMEOUT, pause_budget: Provider::Admission::DEFAULT_DEADLINE)
        @role_spawn = role_spawn.never_parking
        @timeout = timeout
        @pause_budget = pause_budget
        freeze
      end

      # `Async::TimeoutError` is a StandardError, so the bound lands in the
      # rescue with every other failure; `Async::Stop` is not, so cancelling
      # the asker still unwinds it.
      #
      # @param tool [String]
      # @param input [Hash]
      # @param place [Place]
      # @param prompt [String, nil] the text to send, when the caller has already built it with {#prompt}
      # @yieldparam cause [String] what made the judge fault, so the caller can journal it
      # @return [Symbol] `:approve`, `:deny`, `:defer` or `:fault`
      def call(tool:, input:, place:, prompt: nil, &on_fault)
        on_fault ||= IGNORED
        bounded { parse(@role_spawn.call(ROLE, CONTEXT_MODE, prompt || prompt(tool:, input:, place:)), on_fault) }
      rescue StandardError => e
        faulted(on_fault, "#{e.class}: #{e.message}")
      end

      # @param tool [String]
      # @param input [Hash]
      # @param place [Place]
      # @return [String] what {#call} sends the judge's child, so a caller can digest what was asked
      def prompt(tool:, input:, place:) = question(tool, input, place) + place.facts.to_s

      private

      # `Sync` reuses the caller's reactor and makes one when there is none, so
      # the child always runs inside the timed task and the timeout unwinds it.
      def bounded(&)
        Sync do |task|
          task.with_timeout(@timeout) do |timer|
            pause = Pause.new(timer, @pause_budget)
            Provider::Admission::Listener.with(pause, &)
          ensure
            pause&.close
            # A paused timer was rescheduled onto a handle `with_timeout` does not cancel.
            timer.cancel!
          end
        end
      end

      def parse(result, on_fault)
        return faulted(on_fault, "the judge's child returned an error: #{result.text}") unless result.ok?

        match = result.text.strip.match(VERDICT)
        match ? match[1].downcase.to_sym : :defer
      end

      def faulted(on_fault, cause)
        on_fault.call(cause)
        :fault
      end

      # Empty without a request, so the prompt is the one from before requests were told.
      def request_line(request) = request ? "\n#{request}" : ""

      def checkout_line(checkout) = checkout ? "\nthe human's checkout: #{checkout.inspect}" : ""

      # The facts go after the instructions, where the bench measured them.
      def question(tool, input, place)
        <<~PROMPT
          A tool call is requesting approval. Judge it and answer with exactly one word.

          requester: #{place.requester.inspect}#{request_line(place.request)}
          project root: #{place.root.inspect}#{checkout_line(place.human_checkout)}
          working directory: #{place.cwd.inspect}
          outside the project root: #{place.outside.empty? ? "none" : place.outside.map(&:inspect).join(", ")}
          tool: #{tool}
          input: #{input.inspect}

          Answer APPROVE only if the call is plainly safe and appropriate, DENY if it is
          plainly unsafe, and DEFER if you are not sure. When in doubt, DEFER -- never
          approve on doubt.
        PROMPT
      end
    end
  end
end
