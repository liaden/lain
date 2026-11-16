# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # The steps `/review` and `/survey` share once each has resolved WHAT to open:
      # draw into the attached editor, bind the gesture rails, hold the round in the
      # outbox, and move the human's focus. Each command keeps what differs -- its
      # refusals, its target and the docent's root -- and states it in an {Opening}.
      #
      # Every `Lain::Review::*` name is spelled in full: a bare `Review` or `Survey`
      # inside `Lain::CLI::Command` resolves to the command class of that name.
      class ReviewRound
        # One round, as a command resolved it.
        #
        # `headline` is a `(session, scope) -> String` because both headlines read
        # the changeset only a session holds. `name_for` is the docent's path
        # naming, and `disclosure` the lines a survey owes about what its walk
        # withheld; neither is needed by a branch review.
        Opening = Data.define(:source, :source_name, :target, :label, :number, :bounds, :policy, :spawn,
                              :headline, :name_for, :disclosure) do
          def initialize(name_for: Lain::Review::Docent::AS_ANCHORED, disclosure: nil, **rest) = super
        end

        # @param outbox [Lain::Review::Submit::Outbox] the run's ONE open review
        def initialize(outbox:)
          @outbox = outbox
          freeze
        end

        # The BIND comes before the draw because a human fast enough to answer
        # between the two would send a gesture nothing could route. A draw that
        # refuses lets go of both again ({Lain::Review::Handover::Closing#drawing}).
        #
        # Focus is last and only if the draw returned, once, and never on the
        # render path: a redraw follows every gesture and would move the human each
        # time they marked a hunk.
        #
        # @param opening [Opening]
        # @param env [Env] read for the editor's rails, the chat's journal and its supervisor
        # @param scope [String] an already-validated grouping
        # @param hold_after_draw [Boolean] a survey holds only once it has drawn, so
        #   a draw that refuses never displaced a settled review the chat still holds
        # @return [String] the headline, and whatever the draw or the walk had to say
        # @raise [Lain::Error] a surface missing part of the port, a draw past a ceiling
        def open(opening, env, scope:, hold_after_draw: false)
          surface = env.replies.review_surface
          Lain::Review::Surface.check!(surface)
          banner = Review.not_carried_over(env, opening.target)
          session = session_for(opening, env, surface)
          closing = Lain::Review::Handover::Closing.new(outbox: @outbox, rails: env.replies, surface:)
          docent = docent_for(opening, session, env, surface)
          env.replies.bind_changeset_review(handover(session, env, scope, closing, docent))
          hold(opening, session) unless hold_after_draw
          closing.drawing(session) { draw_and_hold(opening, session, scope, banner, hold_after_draw) }
                 .tap { surface.focus }
        end

        private

        def session_for(opening, env, surface)
          Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source: opening.source),
                                     journal: env.chronicle.record_journal, source: opening.source_name, surface:,
                                     bounds: opening.bounds, policy: opening.policy, target: opening.target)
        end

        def hold(opening, session) = @outbox.hold(session:, number: opening.number, label: opening.label)

        def docent_for(opening, session, env, surface)
          Lain::Review::Docent.for(changeset: session.changeset, surface:, spawn: opening.spawn,
                                   journal: env.chronicle.record_journal, supervisor: env.supervisor,
                                   name_for: opening.name_for)
        end

        # The view comes off the SAME editor the surface did: a rendering stamp is
        # only resolvable by the view that issued it. The scope rides along because
        # a gesture that changed a row has to redraw, and a session forgets it.
        def handover(session, env, scope, closing, docent)
          view = env.replies.review_view
          view.reviewing(session.changeset)
          Lain::Review::Handover.new(session:, view:, docent:, closing:,
                                     redraw: Lain::Review::Handover::Redraw.new(scope:))
        end

        def draw_and_hold(opening, session, scope, banner, hold_after_draw)
          drawn(opening, session, scope, banner).tap { hold(opening, session) if hold_after_draw }
        end

        # A String answer is the surface's REFUSAL and anything else means the
        # editor took it; the round is open either way, so the headline still goes.
        def drawn(opening, session, scope, banner)
          refusal = session.present(scope:)
          headline = opening.headline.call(session, scope)
          [Lain::Review::OpenedBanner.call(headline, sides: session.changeset.sides), banner, opening.disclosure,
           refusal.is_a?(String) ? refusal : nil].compact.join("\n")
        end
      end
    end
  end
end
