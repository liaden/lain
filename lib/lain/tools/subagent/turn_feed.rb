# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # Promotes a CHILD chain's committed turns onto the spawn observer, so the
      # session record carries the turns a child's own events cite. Speaks
      # `#catch_up`, which is {Middleware::JournalTurns}' whole duck -- the child
      # Agent wraps its turn phase in that middleware exactly as a chat wraps
      # its own, and this stands where the chat's {SessionRecord::Scribe} does.
      #
      # It is a separate object from the Scribe because it answers a different
      # question. The Scribe owns ONE record's render chain and refuses a
      # timeline that does not extend it ({SessionRecord::Scribe::Diverged});
      # a child chain never extends the parent's -- that is the point of a
      # spawn -- so it can only ever arrive as events, on the observer funnel
      # the Scribe already listens to.
      #
      # `base` is the digest the child STARTED from: nil for a fresh root, and
      # the parent's head for an inherited prefix, where the turns at and below
      # it are the parent's and this record already holds them as `turn`
      # records. Walking past it would journal them a second time, under a
      # second record type.
      class TurnFeed
        # A timeline that no longer carries the digest last fed -- rewound,
        # checked out below it, or re-rooted. {Scribe::Diverged}'s reasoning,
        # for the same reason: the walk below has no way to distinguish that
        # from "nothing has been fed yet", so it would silently re-feed the
        # whole chain and put every turn in the record twice. A format whose
        # premise is that a record means something cannot answer that quietly.
        class Diverged < Error; end

        # @param observer [#call] the spawn seam's event observer -- the session
        #   scribe, in a live chat
        # @param base [String, nil] the child's starting digest; turns at or
        #   below it belong to whoever spawned it
        def initialize(observer:, base: nil)
          @observer = observer
          @stop = base
        end

        # Every turn above the last one fed, root-to-head. The stop digest
        # advances PER TURN rather than once at the end, so an observer that
        # raises mid-walk (a full disk, an EIO) leaves the next call resuming
        # from the last record that actually landed rather than re-feeding the
        # ones before it.
        #
        # @param timeline [Lain::Timeline]
        # @return [self]
        # @raise [Diverged] when the stop digest is not on this timeline
        def catch_up(timeline)
          fresh(timeline).each do |turn|
            @observer.call(turn)
            @stop = turn.digest
          end
          self
        end

        private

        # The walk STOPS at the stop digest; running out instead -- reaching a
        # root -- is the whole signal that the digest is not on this ancestry.
        # An empty walk is the head itself being the stop digest, which is the
        # ordinary caught-up case, and a nil stop legitimately walks to the root.
        def fresh(timeline)
          walked = timeline.ancestors.take_while { |turn| turn.digest != @stop }
          return walked.reverse unless !@stop.nil? && walked.last&.root?

          raise Diverged, "the last turn fed (#{@stop.inspect}) is not on timeline " \
                          "#{timeline.head_digest.inspect}; a feed that re-walked from the root here " \
                          "would record every turn above it a second time"
        end
      end
    end
  end
end
