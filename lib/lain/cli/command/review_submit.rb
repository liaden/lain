# frozen_string_literal: true

require "json"
require "mixlib/shellout"

module Lain
  module CLI
    module Command
      # `/review-submit [summary]` at `you>` (T34): post the changeset review
      # this chat has open to its pull request, as ONE batched review.
      #
      # == The gap this closes, stated plainly
      #
      # Everything upstream -- the sidebar, the diff pair, the annotations, the
      # marks, the verdict -- terminated in lain's own journal. `Review::Submit`
      # was written, documented and specced, and grep found it constructed
      # NOWHERE in the tree. Reviewing somebody else's pull request and leaving
      # the review on your own disk is not a code review, so this is the command
      # that makes the last hop.
      #
      # == Why a repl verb, and not `lain review submit`
      #
      # A review that has anything to say was annotated in the EDITOR: the
      # gesture rails only exist inside a chat with a cockpit attached
      # ({Command::Review} refuses without one), so the human who has finished a
      # review is, by construction, sitting at this prompt. A one-shot process
      # holds no session and would have to rebuild the round from the journal
      # against a changeset the author has gone on pushing to -- see
      # {Review::Submit::Outbox}'s own doc for why that degrades a review into
      # prose without saying so.
      #
      # == The summary is what was typed after the verb
      #
      # `/review-submit the tests are the good part` posts that sentence as the
      # review body. It is the only place in this loop where a human is already
      # typing prose at a prompt this command owns -- anything richer means a
      # compose buffer, a new wire verb and a protocol bump, which is a card of
      # its own. An empty line is legitimate and common: with inline comments on
      # the diff, the annotations ARE the review, and {Review::Submit} refuses
      # the one case that would say nothing at all.
      #
      # == One attempt, and the refusal is the answer
      #
      # {Review::Submit::Outbox} owns the no-second-post rule; this class owns
      # only the words. GitHub refusing comes back as a not-ok
      # {Forge::Gh::Answer} and is RAISED here rather than returned, because a
      # review that did not land must not read like a line of success -- and
      # because there is no retry: {Forge::Gh#submit_review}'s doc records that
      # an accepted POST creates a review every time.
      class ReviewSubmit
        # GitHub took the request and answered no. Its own class rather than a
        # returned sentence: the repl renders a {Lain::Error} loudly, and this
        # is the outcome a human most needs not to skim past.
        class Rejected < Error; end

        USAGE = "/review-submit [summary] -- post the open changeset review to its pull request, once"

        # What a landed review says. GitHub's OWN document rather than a count
        # of what was sent: the remote is the only thing that knows what it
        # recorded, and restating the payload back at the human would be this
        # process agreeing with itself.
        SENT = "review posted to %<target>s -- GitHub answered %<answer>s"

        REJECTED = "GitHub refused the review for %<target>s and nothing here will try again " \
                   "(an accepted POST creates a review every time, so a retry is a second review): %<detail>s"

        # @param outbox [Review::Submit::Outbox] the run's ONE open review --
        #   the same instance {Command::Review} holds its round in, wired in
        #   {Command::Surface}. Required, never defaulted: an outbox of this
        #   command's own would answer "no changeset review is open" forever,
        #   with every collaborator present and nothing wrong to see.
        # @param root [String] the repository `gh` runs in, which is how it
        #   resolves WHICH pull request the number names -- threaded from
        #   {Command::Surface} exactly as {Meta}'s and {Review}'s are
        # @param shell_out_factory [#call] builds the subprocess runner,
        #   injected as {Forge::Gh} and both review sources do
        def initialize(outbox:, root: Dir.pwd, shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @outbox = outbox
          @root = root
          @shell_out_factory = shell_out_factory
          freeze
        end

        def name = "review-submit"

        def usage = USAGE

        # @param args [String] the human's summary, if they wrote one
        # @param _env [Env] unread: everything this needs was wired at
        #   construction, and the session is the outbox's
        # @return [String] what GitHub recorded
        # @raise [Lain::Error] nothing open, nowhere to post, already sent, a
        #   comment naming an unplaceable range, a review that says nothing --
        #   each already worded by whoever owns the refusal -- or {Rejected}
        def call(args, _env)
          answer = @outbox.submit(executor:, body: args.to_s.strip)
          reported(answer)
        end

        private

        # Built per call rather than held, so a `Gh` is never constructed for a
        # chat that submits nothing -- and so the one built is bound to the
        # repository as it stands when the review is actually sent.
        def executor = Forge::Gh.new(cwd: @root, shell_out_factory: @shell_out_factory)

        # The target comes off the outbox rather than out of this method's
        # arguments: it is the human's own words for what they opened, and the
        # outbox is still holding the round the answer is about.
        def reported(answer)
          raise Rejected, format(REJECTED, target: @outbox.target, detail: detail(answer)) unless answer.ok?

          format(SENT, target: @outbox.target, answer: JSON.generate(answer.value))
        end

        # gh's own words when it had any, and this executor's diagnosis when it
        # had none -- {Forge::Gh#refusal} and {Forge::Gh#failure}'s two shapes,
        # kept apart so nobody reads our sentence as the remote's.
        def detail(answer)
          said = answer.detail["stderr"].to_s.strip
          said.empty? ? answer.detail.fetch("message", answer.detail.fetch("reason", "no detail")) : said
        end
      end
    end
  end
end
