# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # The chat's one `Frontend::Intake`, built over the command registry that
      # does not exist yet: the registry is assembled from objects built after
      # the Intake, so it is read at each line rather than taken.
      module IntakeBuild
        # The drain a pane's queued commands run on, which ends the attendance with it.
        class Draining
          def initialize(task, &done)
            @task = task
            @done = done
          end

          def stop
            @done.call
            @task.stop
          end
        end

        # What the Intake asks about a typed line, answered by the bound registry.
        class Probe
          # @param bound [#call] the bound {Command::Registry}, or nil before the surface is assembled
          # @param screen [#render_note] where a command's outcome and a failure are said
          def initialize(bound:, screen:)
            @bound = bound
            @screen = screen
            @queue = Thread::Queue.new
            @attending = false
          end

          # The chat's reactor starts this for a producer that has none of its own (a pane's reader threads):
          # such a thread must not run a command that reads the very rail it feeds, so it queues the line here.
          #
          # @param task [Async::Task] the conversation's, which the drain ends with
          # @return [#stop] ends the drain
          def attend(task)
            @attending = true
            drain = task.async(transient: true) { loop { dispatching(task, @queue.pop) } }
            Draining.new(drain) { @attending = false }
          end

          # A line the registry cannot parse is prose to this question, not a failure on the producer's stack.
          def disposition(text)
            current.disposition(text)
          rescue Lain::Error
            Frontend::Intake::Disposition.new(kind: :hold, said: text)
          end

          # On a reactor it runs as a task of its own; off one, it is queued to {#attend}'s drain, if any.
          #
          # @return [Async::Task, Thread::Queue, nil] nil when nothing can run it, leaving the line to be held
          def run_now(text)
            reactor = Async::Task.current?
            return reactor.async { run(text) } if reactor

            @queue.push(text) if @attending
          end

          private

          def dispatching(task, text) = task.async { run(text) }

          def current = @bound.call || Frontend::Intake::NoCommands

          def run(text)
            outcome = current.dispatch(text) { nil }
            @screen.render_note(outcome) if outcome.is_a?(String)
          rescue StandardError => e
            @screen.render_note(e.message)
          end
        end

        # The chat's screen, except that a note is said in an input pane when one is connected: the human is
        # looking at the pane that owns the prompt, not at the chat's transcript.
        class PaneNotes < SimpleDelegator
          # @param tty [#render_note] the chat's own screen, which says a note when no pane takes it
          def initialize(tty)
            super
            @lock = Thread::Mutex.new
            @panes = []
          end

          # @param producer [Object] a producer attached to the rail; only one that answers `note` is kept
          def attached(producer) = (@lock.synchronize { @panes << producer } if producer.respond_to?(:note))

          def detached(producer) = @lock.synchronize { @panes.delete(producer) }

          def render_note(text) = said(text, "note") { super }

          def render_held(text) = said(text, "held") { super }

          def render_human_note(text) = said(text, "human") { super }

          private

          def said(text, kind)
            panes = @lock.synchronize { @panes.dup }
            yield unless panes.sum { |pane| pane.note(text, kind:) }.positive?
          end
        end

        # The rail as a producer sees it, so the screen learns which producers are panes.
        class Rail < SimpleDelegator
          def initialize(rail, notes)
            super(rail)
            @notes = notes
          end

          def attach(producer)
            @notes.attached(producer)
            super
          end

          def detach(producer)
            @notes.detached(producer)
            super
          end
        end

        def self.rail(tty:, human:, notes:, on_cycle:, surface:)
          screen = PaneNotes.new(tty)
          Rail.new(Frontend::Intake.new(screen:, history: human.history_for(tty), notes:, on_cycle:,
                                        commands: Probe.new(bound: -> { surface.call&.commands }, screen:)), screen)
        end
      end
    end
  end
end
