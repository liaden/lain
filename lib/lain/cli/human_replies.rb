# frozen_string_literal: true

module Lain
  module CLI
    # The human-reply surfaces (I6), lifted out of Repl the way Wiring lifted
    # chat assembly: answering ask_human is its own responsibility -- the
    # arrival note, the `/inbox` drain, and the editor's :LainReply leg -- and
    # the Metrics trip said so. The single pending question is the invariant the
    # drain keeps: one question at a time, one AskHuman, one reply resolves it.
    class HumanReplies
      # I6: one pending human question as the drain surface lists it -- who is
      # stuck (the asker's chain correlation), since when, and the question.
      InboxItem = Struct.new(:question, :from, :asked_at, keyword_init: true)

      def initialize(tty:, conductor:, ask_human:, questions:)
        @tty = tty
        @conductor = conductor
        @ask_human = ask_human
        @questions = questions
        @command_inbox = nil
        @inbox = []
      end

      # The editor's :LainReply queue (or nil, no editor), bound before converse
      # runs so #editor_reply_loop knows whether to spawn its consumer fiber.
      def bind_editor(command_inbox) = @command_inbox = command_inbox

      # The concurrent reply surfaces for one ask: the TTY drain loop, and --
      # only when an editor is attached -- the :LainReply consumer. The caller
      # (Repl#respond) stops them in its ensure.
      def surfaces(task) = [answer_loop(task), editor_reply_loop(task)]

      private

      # A question ARRIVES as a one-line note; the reply read stays fiber-parked
      # (the ask cannot complete without it -- the single-question invariant is
      # untouched), but the surface is the drain. `/inbox` at the reply prompt
      # lists the pending items before answering; any other line answers
      # directly (the inline path stays the no-inbox fallback). Parks on dequeue
      # (a real scheduler yield -- woken per question, never polling).
      def answer_loop(task)
        task.async do
          loop do
            question = @questions.dequeue
            @inbox << InboxItem.new(question:, from: @ask_human.last_question&.from, asked_at: Time.now)
            @tty.render_arrival(question)
            resolve_reply(read_drained_answer)
          end
        end
      end

      # The reply read routes through the conductor's #read_reply (not the tty
      # directly) so the conductor KNOWS Reline owns stdin for the span and
      # suppresses its countdown ticker's render + key-read. `.to_s` is
      # load-bearing on both reads: EOF returns nil, and an empty answer is
      # honest where Tool::Result.ok(nil) would raise.
      def read_drained_answer
        line = @conductor.read_reply(@tty, "human> ").to_s
        return line unless line.strip == "/inbox"

        answer = nil
        @tty.drain_inbox(@inbox, reader: ->(prompt) { @conductor.read_reply(@tty, prompt) }) { |a| answer = a }
        answer.to_s
      end

      # AlreadyResolved: the editor's :LainReply beat this prompt -- drop the
      # duplicate rather than killing the loop. The shift retires the item this
      # answer resolved regardless of which surface won.
      def resolve_reply(answer)
        @ask_human.reply(answer)
      rescue Lain::Promise::AlreadyResolved
        nil
      ensure
        @inbox.shift
      end

      # The editor reply leg (I6): the :LainReply command lands on the frontend's
      # command_inbox and this fiber resolves the pending ask from it.
      # Thread::Queue is popped NON-blocking (a blocking pop would freeze the
      # reactor thread); an empty pop parks the fiber a tick and retries.
      # `pending?` guards the TTY answer that already won -- the raced loser is
      # dropped. Non-"reply" verbs are ignored (they rode their own path here).
      def editor_reply_loop(task)
        @command_inbox && task.async do
          loop do
            verb, args = pop_command
            @ask_human.reply(args.first.to_s) if verb == "reply" && @ask_human.pending?
            sleep(0.1) if verb.nil?
          end
        end
      end

      def pop_command
        @command_inbox.pop(true)
      rescue ThreadError
        nil
      end
    end
  end
end
