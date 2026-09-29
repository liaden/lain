# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # ONE ask, and what the human is owed when it does not finish. The
      # conversation owns reading lines and delivering answers; this owns the
      # narrower question of what an ask PRODUCED -- a response, or a refusal
      # that has to be journaled and said in one line. The refusal is carried
      # out of the ask as a value by {#attempt} precisely so {#settle} can be
      # the single place deciding between the two, whichever frame produced it.
      #
      # THE VALUE PATH IS THE WHOLE POINT, and it is not a style preference.
      # {Conductor#supervise} runs the ask inside an `Async::Task`, and
      # `Async::Task#run` rescues its block and logs `Task may have ended with
      # unhandled exception.` plus the full backtrace `unless @promise.waiting?`
      # (async-2.42.0, `lib/async/task.rb:224-228`). The supervisor spawns with
      # `task.async`, which resumes the fiber EAGERLY and only reaches
      # `run.wait` after building the shutdown and spawning the coordinator and
      # the ticker -- so a refusal raised in that window is reported as a crash.
      # Measured on every budget ceiling (0, 2, 4, and the token ceiling):
      # ~2.6KB of stderr in front of the correct one-line refusal,
      # deterministically, 5 runs out of 5.
      #
      # ONLY {Lain::Error} COMES BACK AS A VALUE. Quietening Async instead would
      # also hide a genuine crash inside an ask, which is strictly worse than
      # over-reporting, so anything outside the harness's own vocabulary still
      # raises inside the task and still leaves the conversation.
      #
      # A TOOL CANNOT REACH THAT SECOND DIRECTION, which is worth knowing before
      # writing a spec for it: `Effect::Handler::Live` contains every
      # tool raise as a `Tool::Result.error`. The nearest real bug that reaches
      # an ask is a PROVIDER that raises, which is what those specs use.
      class Ask
        # @param agent [Lain::Agent] asked, and the Timeline an interrupt anchors from
        # @param tty [#render_error] the one boundary a refusal is said at
        # @param chronicle [#catch_up, #interrupted] the session record
        def initialize(agent:, tty:, chronicle:)
          @agent = agent
          @tty = tty
          @chronicle = chronicle
          @unfold = NOTHING_FOLDED
        end

        # @return [Lain::Response, Lain::Error] the model's answer, or the
        #   refusal as a value -- never a raise, so the task that ran this ENDS
        #   rather than dying.
        def attempt(text)
          @unfold = NOTHING_FOLDED
          @agent.ask(text, on_fold: method(:resending))
        rescue Lain::Error => e
          e
        end

        # {Repl#settle_command}'s shape, and the same reason for asking `is_a?`
        # of a returned value rather than sending it a message: two genuinely
        # different kinds of answer arrive on one return.
        #
        # @param outcome [Lain::Response, Lain::Error, nil]
        # @return [Lain::Response, nil] nil for a refusal or a failed stop, both
        #   already said
        def settle(outcome)
          return refuse(outcome) if outcome.is_a?(Lain::Error)

          outcome&.failure ? say_failure(outcome) : outcome
        end

        RESENDING = "the prompt at the head has no answer on this chain, so this ask carries it too -- " \
                    "/rewind 1 before asking to leave it out"

        NOTHING_FOLDED = -> {}
        private_constant :NOTHING_FOLDED

        private

        # A failed stop is said as an error, after whatever text the model got
        # out that is worth keeping.
        def say_failure(response)
          failure = response.failure
          @tty.render_response(response) unless failure.withholds_text? || response.text.empty?
          @tty.render_error(failure.message)
          nil
        end

        # A torn ask: journal the turns that did commit, anchor the stop, then
        # say what stopped it in one line and nothing else. Why it stopped is
        # read off the error's type ({Agent::StopReason}), so the record can be
        # triaged from the file.
        def refuse(error)
          record_interruption(error)
          @tty.render_error(error.message)
          nil
        end

        # catch_up FIRST: a raise can land AFTER commits (the ask tore
        # mid-loop), so the committed turns are journaled before the stop is
        # recorded and `interrupted` then names the true last commit. A folded
        # ask the Agent withdrew is the exception: the record holds the folded
        # turn the Agent stepped back from, so it follows the Agent back first.
        def record_interruption(error)
          @unfold.call if error.is_a?(Lain::Withdrawal) && error.withdrawn?
          @chronicle.catch_up(@agent.timeline)
          @chronicle.interrupted(head: @agent.timeline.head_digest, reason: Agent::StopReason.for(error))
        end

        # The Agent is about to send a turn cut from the stranded turn's parent.
        # The record catches up on the stranded chain -- the retreat's target has
        # to be written -- then trades the stranded turn for the folded one in
        # ONE write, before the request can reach the wire: a crash at any point
        # resumes onto a turn carrying the earlier text.
        def resending(stranded, folded)
          parent = stranded.head.parent
          @chronicle.catch_up(stranded)
          @chronicle.replaced(to: parent, with: folded)
          @unfold = -> { @chronicle.replaced(to: parent, with: stranded) }
          @tty.render_warning(RESENDING)
        end
      end
    end
  end
end
