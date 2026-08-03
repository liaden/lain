# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The editor's command rail as a consumer sees it: BOTH directions of the
      # one conversation. A consumer pops the commands the editor sent and
      # answers a gesture it had to refuse -- ":LainReviewDone names no open
      # review" -- and the answer belongs in the editor the gesture came from,
      # which means the render rail. Two objects to hold that (a queue, and the
      # RPC thread) would put the burden of knowing they are one conversation
      # on every consumer; {CLI::HumanReplies::NoEditor} is the same duck for
      # the session that has no editor at all.
      #
      # It lives in its own file because {Neovim} had reached its length limit
      # and this was the first thing in it that was already a class other code
      # talks to -- a public duck ({#pop}, {#attached?}, {#review_refused},
      # {#answered}) with a Null twin outside this object entirely. A
      # `Metrics/ClassLength` that only ever gets paid in formatting is the cop
      # being satisfied rather than heeded.
      #
      # `pop` forwards its arguments rather than declaring `non_block = false`:
      # the duck it satisfies is Thread::Queue's, and restating that default
      # here would be a second place for it to be wrong.
      class CommandInbox
        def initialize(inbox:, rpc:)
          @inbox = inbox
          @rpc = rpc
        end

        def pop(...) = @inbox.pop(...)
        def review_refused(message) = @rpc.review_refused(message)

        # A gesture lain answered LOCALLY joining the same rail (T12): the
        # editor's question write is parsed on the RPC thread, and the answer
        # set it produced is popped by the consumer that serves every other
        # verb. `[verb, args]` with args ONE array, the shape since T16 --
        # flat positionals is how a payload got silently dropped once already.
        #
        # It is called on the RPC thread, inside the editor's write, under
        # {QuestionView}'s lock, so it must stay what it is: a push onto an
        # unbounded, never-closed queue, which cannot park and cannot raise.
        def answered(digest, answers) = @inbox.push(["question_answered", [digest, answers]])

        # There is an editor. The Null answers false, and that is the whole of
        # the question a consumer ever has to ask.
        def attached? = true
      end
    end
  end
end
