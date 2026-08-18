# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # ONE ask, and what the human is owed when it does not finish. The
      # conversation owns reading lines and delivering answers; this owns the
      # narrower question of what an ask PRODUCED -- a response, or a refusal
      # that has to be journaled and said in one line.
      #
      # It exists because {Repl#respond} could not carry it. `Metrics/ClassLength`
      # tripped at 119/110 the moment the refusal grew a value path, and the
      # class doc on {Repl} records the same cop making the same point one level
      # up ("extract, do not loosen"). The two halves below are genuinely one
      # responsibility -- the refusal is carried out of the ask as a value by
      # {#attempt} precisely so that {#settle} can be the single place that
      # decides between a response and a refusal, whichever frame produced it.
      #
      # THE VALUE PATH IS THE WHOLE POINT, and it is not a style preference.
      # {Conductor#supervise} runs the ask inside an `Async::Task`, and
      # `Async::Task#run` rescues its block and logs `Task may have ended with
      # unhandled exception.` plus the full backtrace `unless
      # @promise.waiting?` (async-2.42.0, `lib/async/task.rb:224-228`). The
      # supervisor spawns with `task.async`, which resumes the fiber EAGERLY,
      # and only reaches `run.wait` after building the shutdown and spawning the
      # coordinator and the ticker -- so a refusal raised in that window is
      # reported as a crash. Measured on every budget ceiling (0, 2, 4, and the
      # token ceiling): ~2.6KB of stderr in front of the correct one-line
      # refusal, deterministically, 5 runs out of 5.
      #
      # ONLY {Lain::Error} COMES BACK AS A VALUE. Quietening Async instead would
      # also hide a genuine crash inside an ask, which is strictly worse than
      # over-reporting -- so anything outside the harness's own vocabulary still
      # raises inside the task, still gets its report, and still leaves the
      # conversation. `spec/lain/cli/repl_spec.rb` pins both directions through
      # the real Repl; `ask_spec.rb` pins them on this object.
      #
      # A TOOL CANNOT REACH THAT SECOND DIRECTION, which is worth knowing before
      # writing a spec for it: `Effect::Handler::Live#dispatch` contains every
      # tool raise as a `Tool::Result.error` (correctness gate 3). The nearest
      # real bug that reaches an ask is a PROVIDER that raises, which is what
      # those specs use.
      class Ask
        # @param agent [Lain::Agent] asked, and the Timeline an interrupt anchors from
        # @param tty [#render_error] the one boundary a refusal is said at
        # @param chronicle [#catch_up, #interrupted] the session record
        def initialize(agent:, tty:, chronicle:)
          @agent = agent
          @tty = tty
          @chronicle = chronicle
        end

        # @return [Lain::Response, Lain::Error] the model's answer, or the
        #   refusal as a value -- never a raise, so the task that ran this ENDS
        #   rather than dying.
        def attempt(text)
          @agent.ask(text)
        rescue Lain::Error => e
          e
        end

        # {Repl#settle_command}'s shape, and the same reason for asking `is_a?`
        # of a returned value rather than sending it a message: two genuinely
        # different kinds of answer arrive on one return, and which one this is
        # decides whether the human is owed a response or a refusal.
        #
        # @param outcome [Lain::Response, Lain::Error, nil]
        # @return [Lain::Response, nil] nil for a refusal, which is already said
        def settle(outcome) = outcome.is_a?(Lain::Error) ? refuse(outcome) : outcome

        private

        # A torn ask: journal the turns that did commit, anchor the stop, then
        # say what stopped it in one line and nothing else.
        def refuse(error)
          record_interruption
          @tty.render_error(error.message)
          nil
        end

        # B5 (panel amendment): catch_up FIRST -- a raise can land AFTER commits
        # (the ask tore mid-loop), so the committed turns are journaled before
        # the stop is recorded, and interrupted then names the true last commit.
        def record_interruption
          @chronicle.catch_up(@agent.timeline)
          @chronicle.interrupted(head: @agent.timeline.head_digest)
        end
      end
    end
  end
end
