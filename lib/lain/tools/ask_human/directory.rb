# frozen_string_literal: true

module Lain
  module Tools
    class AskHuman
      # Which asker owns the question set an answer NAMES.
      #
      # An {AskHuman} holds at most one set at a time, which is enough while
      # exactly one asker exists. Once a subagent can ask the human beside its
      # parent, several askers hold pending sets at once, so routing BY NAME is
      # the correct addressing and "the asker that asked most recently" is the
      # bug it replaces.
      #
      # This object answers ONLY who owns a name. {Event::Projection#pending}
      # remains the authority on what is pending, and nothing here duplicates
      # it: a digest no registration has heard of is REFUSED, not inferred,
      # because inferring is how an answer typed for one set resolves another.
      #
      # == Ownership, and what deregistration releases
      #
      # One way and strong: a Directory owns its {Registration}s, a Registration
      # owns the names it opened AND references the asker, and nothing here is
      # referenced BY the asker. So a registered asker stays reachable for
      # exactly as long as it is registered, and {Registration#deregister} is
      # the only thing that releases it -- along with every name it held,
      # tombstones included, because the names live INSIDE the registration.
      #
      # Strong rather than a weak map, deliberately: a weakly-held asker would
      # make an outstanding question stop being routable at a GC's discretion,
      # precisely the "the answer went nowhere" failure the digest exists to
      # prevent. The cost is that a registration nobody deregisters retains its
      # asker, so the deregister message must ride the lease that already reaps
      # the actor.
      #
      # "Bounded by registration lifetime" therefore bounds the MECHANISM and
      # says nothing about how long any registration lives. The run's OWN asker
      # is registered once and deliberately never deregistered -- it is
      # answerable for as long as the chat -- so its names are bounded by the
      # SESSION. That is one entry per question a human is asked, which is
      # human-paced; a fleet of children is where the difference between the two
      # bounds is worth having.
      #
      # There is no timeout and no reaper: a pending question stays pending,
      # which is the honest state and is visible in the inbox.
      class Directory
        # {Outstanding::WITHDRAWN} is REUSED verbatim rather than reworded,
        # because the same event -- an inbox line that outlived its set -- must
        # not read two ways depending on which object noticed it.
        #
        # A nil digest is an answer that names NOTHING, and is said as that
        # rather than interpolated into a sentence with a hole where the name
        # goes ("the question set  cannot be answered").
        UNNAMED = "no question set was named, so nothing here can be answered"

        def self.unanswerable(digest)
          return "#{UNNAMED}: #{Outstanding::WITHDRAWN}" if digest.nil?

          "the question set #{digest} cannot be answered: #{Outstanding::WITHDRAWN}"
        end

        # A Null Object standing in three places at once -- the registration a
        # lookup does not find, the name a registration does not hold, and what
        # {Null} hands back from `#register` -- because all three are the same
        # fact about different objects, ending in the same refusal.
        module Unheld
          def self.asked(digest) = digest
          def self.holds?(_digest) = false
          def self.reply(_answer, digest) = raise(NoPendingQuestion, Directory.unanswerable(digest))
          def self.deregister = nil
          def self.size = 0
        end

        # `Enumerable#find`'s ifnone, so a miss is answered by an OBJECT rather
        # than a `nil` the caller would have to check.
        NOBODY = -> { Unheld }

        # One asker, and the names it opened. It holds the asker; nothing holds
        # it but the directory that registered it.
        class Registration
          # An open name: this asker still holds the set, and is who an answer
          # goes to.
          class Open
            def initialize(asker) = @asker = asker

            # A refusal from the asker means the set was WITHDRAWN under us --
            # the sync gate unwound and nobody was told -- so this name is
            # stale exactly as a stale `/inbox` line is. Re-raised as the
            # directory's own refusal because the asker's version describes the
            # ASKER's state to a debugger, where the human who just typed an
            # answer needs to hear that the line was stale and nothing was lost.
            def reply(answer, digest)
              @asker.reply(answer, digest)
            rescue NoPendingQuestion
              raise NoPendingQuestion, Directory.unanswerable(digest)
            end
          end

          # A TOMBSTONE, not a null object: it remembers that this name WAS
          # answered, so a second answer is refused as already-answered rather
          # than as unknown, without reaching the asker at all. It lives in the
          # registration, so {Directory#forget} drops it -- a tombstone that
          # outlived its registration would be a map growing with the SESSION
          # instead of with the fleet.
          module Answered
            def self.reply(_answer, digest)
              raise Promise::AlreadyResolved, "the question set #{digest} was already answered"
            end
          end

          def initialize(asker, directory)
            @asker = asker
            @directory = directory
            @names = {}
          end

          # The ONLY door a name enters through, so the map cannot be written
          # past the object that owns it.
          #
          # @param digest [String] the Q event's digest -- `pending.digest`
          # @return [String] the digest, so an ask composes
          def asked(digest)
            @names[a_name!(digest)] = Open.new(@asker)
            digest
          end

          def holds?(digest) = @names.key?(digest)

          # A guard, not a lock: the state read here and the tombstone claimed
          # after it straddle the asker's Store write, which the ChainWriter's
          # observer can turn into a yield point -- so two fibers answering ONE
          # name could both pass it, leaving two A events citing one Q.
          # Unreachable today rather than impossible, and a lock HERE would not
          # close it: {Outstanding}'s own check and resolve straddle the same
          # write, so the window belongs to whatever resolves the promise.
          def reply(answer, digest)
            delivered = @names.fetch(digest, Unheld).reply(answer, digest)
            @names[digest] = Answered
            delivered
          end

          # Every name at once, answered ones included. The asker is untouched
          # and keeps holding whatever it holds -- only the ROUTING goes --
          # because a directory answering on behalf of a reaped agent would be
          # worse than one that refuses.
          def deregister = @directory.forget(self)

          # Tombstones included. What {Directory#size} sums.
          def size = @names.size

          private

          # The mistake it catches is handing over the {Pending}, or the Q
          # event, instead of the NAME it wears: both answer `#digest`, so both
          # would sit in the map as a key no answer can match, and the reply
          # would then refuse a set that IS outstanding.
          def a_name!(digest)
            return digest if digest.is_a?(String)

            raise ArgumentError, "a question set is named by its Q event's digest (got #{digest.class}) -- " \
                                 "hand over `pending.digest`, not the pending itself"
          end
        end

        def initialize = @registrations = []

        # @param asker [AskHuman] routable from now until its registration is
        #   dropped; held strongly (see the class comment)
        # @return [Registration]
        def register(asker) = Registration.new(asker, self).tap { |registration| @registrations << registration }

        # Deliver an answer to the asker that owns the set `digest` names.
        #
        # @param answer [String] what the human typed
        # @param digest [String] the Q event of the set this answers
        # @return [Lain::Event] the A :message event the asker wrote
        # @raise [NoPendingQuestion] naming the digest, when no registered asker
        #   holds that name -- unknown, deregistered, or withdrawn
        # @raise [Promise::AlreadyResolved] when this directory already routed
        #   an answer to that name
        def reply(answer, digest) = holder_of(digest).reply(answer, digest)

        # Answers the registration itself rather than whether it was there:
        # forgetting one already forgotten is the same fact, not a different
        # one.
        #
        # @return [Registration]
        def forget(registration)
          @registrations.delete(registration)
          registration
        end

        # Open sets plus the tombstones of answered ones -- what a bench or a
        # spec watches to see that growth is bounded by REGISTRATION lifetime.
        def size = @registrations.sum(&:size)

        private

        def holder_of(digest) = @registrations.find(NOBODY) { |registration| registration.holds?(digest) }
      end
    end
  end
end
