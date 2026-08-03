# frozen_string_literal: true

module Lain
  module Tools
    class AskHuman
      # Which asker owns the question set an answer NAMES.
      #
      # An {AskHuman} holds at most one set at a time ({Outstanding}), which is
      # enough while exactly one asker exists. Once a subagent can ask the human
      # beside its parent, several askers hold pending sets at once and an
      # answer arriving with a digest belongs to exactly one of them -- so
      # routing by name is the correct addressing, and "the asker that asked
      # most recently" is the bug it replaces (see {AskHuman#reply}'s
      # transitional default).
      #
      # This object answers ONLY who owns a name. {Event::Projection#pending}
      # remains the authority on what is pending -- it folds the log, this holds
      # process-local coordination -- and nothing here duplicates it: a digest
      # no registration has heard of is refused, not inferred, because inferring
      # is how an answer typed for one set resolves another.
      #
      # == Ownership, and what deregistration releases
      #
      # The direction is one way and strong: a Directory owns its
      # {Registration}s, a Registration owns the names it opened AND references
      # the asker, and NOTHING here is referenced by the asker. So a registered
      # asker (and transitively its agent's toolset) stays reachable for exactly
      # as long as it is registered, and {Registration#deregister} is the only
      # thing that releases it -- along with every name it held, tombstones
      # included, because the names live INSIDE the registration rather than in
      # a map that outlives it. Retention is therefore bounded by registration
      # lifetime, never by session length.
      #
      # Strong rather than a weak map, deliberately: a weakly-held asker would
      # make an outstanding question stop being routable at a GC's discretion,
      # which is precisely the "the answer went nowhere" failure the digest
      # exists to prevent. The cost is that a registration nobody deregisters
      # retains its asker, so the deregister message must ride the lease that
      # already reaps the actor -- this card provides the message; it does not
      # reach into {Supervisor} to send it.
      #
      # So "bounded by registration lifetime" is a bound on the MECHANISM, and
      # says nothing about how long any given registration lives. The run's own
      # asker is registered once by {CLI::Wiring#wire_askers} and deliberately
      # never deregistered -- it is answerable for exactly as long as the chat
      # -- so its names, tombstones included, are bounded by the SESSION. That
      # is one asker growing by one entry per question a human is asked, which
      # is human-paced; a fleet of children is where the difference between the
      # two bounds is worth having, and where `deregister` has a lease to ride.
      #
      # There is no timeout and no reaper (ruling 10): a pending question stays
      # pending, which is the honest state and is visible in the inbox.
      class Directory
        # A digest that can no longer be answered, in one sentence a human at a
        # `human>` prompt can act on. {Outstanding::WITHDRAWN} is REUSED
        # verbatim rather than reworded because the same event -- an inbox line
        # that outlived its set -- must not read two ways depending on which
        # object noticed it; the digest is named ahead of it for the reader
        # (and the model) that has one.
        #
        # A nil digest is an answer that names NOTHING -- the editor's
        # digest-less `:LainReply` arriving with nothing listed -- and it is
        # said as that rather than interpolated into a sentence with a hole
        # where the name goes ("the question set  cannot be answered").
        # {AskHuman::Outstanding#unnamed} draws the same distinction.
        UNNAMED = "no question set was named, so nothing here can be answered"

        def self.unanswerable(digest)
          return "#{UNNAMED}: #{Outstanding::WITHDRAWN}" if digest.nil?

          "the question set #{digest} cannot be answered: #{Outstanding::WITHDRAWN}"
        end

        # No registration at all, and no name held: never asked, never
        # registered, or deregistered since. A Null Object standing in three
        # places at once -- the registration a lookup does not find, the name a
        # registration does not hold, and what {Null} hands back from
        # `#register` -- because all three are the same fact said about
        # different objects, and each of them ends in the same refusal.
        module Unheld
          def self.asked(digest) = digest
          def self.holds?(_digest) = false
          def self.reply(_answer, digest) = raise(NoPendingQuestion, Directory.unanswerable(digest))
          def self.deregister = nil
          def self.size = 0
        end

        # The registration a name nobody holds routes to. `Enumerable#find`'s
        # ifnone, so the miss is answered by an object rather than by a `nil`
        # the caller would have to check.
        NOBODY = -> { Unheld }

        # One asker, and the names it opened. It holds the asker; nothing holds
        # it but the directory that registered it.
        class Registration
          # An open name: this asker still holds the set, and is who an answer
          # goes to.
          class Open
            def initialize(asker) = @asker = asker

            # A refusal from the asker means the set was WITHDRAWN under us --
            # the sync gate unwound and nobody was told, so this name is stale
            # in exactly the way a stale `/inbox` line is. Re-raised as the
            # directory's own refusal because the asker's digest-named one
            # ("this asker holds no question set at all") describes the asker's
            # state to someone debugging it, where the human who just typed an
            # answer needs to hear that the line was stale and nothing was lost.
            def reply(answer, digest)
              @asker.reply(answer, digest)
            rescue NoPendingQuestion
              raise NoPendingQuestion, Directory.unanswerable(digest)
            end
          end

          # A TOMBSTONE, not a null object: it remembers that this name WAS
          # answered, so a second answer is refused as already-answered -- in
          # the asker's own words, and without reaching the asker at all --
          # rather than as unknown. It lives in the registration, so
          # {Directory#forget} drops it with everything else the registration
          # held; a tombstone that outlives its registration is a map that
          # grows with the SESSION instead of with the fleet.
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

          # This asker asked the set `digest` names: the ONLY door a name
          # enters through, so the map cannot be written past the object that
          # owns it.
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
          # observer can turn into a yield point, so two fibers answering ONE
          # name could both pass it -- two A events citing one Q, and
          # `last_answer` holding the loser. Unreachable today rather than
          # impossible, and a lock HERE would not close it: {Outstanding}'s own
          # check and its resolve straddle the same write (see its comment), so
          # the window belongs to the object that resolves the promise.
          def reply(answer, digest)
            delivered = @names.fetch(digest, Unheld).reply(answer, digest)
            @names[digest] = Answered
            delivered
          end

          # Stop being routable: every name at once, answered ones included.
          # The asker itself is untouched and keeps holding whatever it holds
          # -- only the routing goes -- because a directory that answered on
          # behalf of a reaped agent would be worse than one that refuses.
          def deregister = @directory.forget(self)

          # How many names this registration can answer for, tombstones
          # included. What {Directory#size} sums.
          def size = @names.size

          private

          # The mistake this catches is handing over the {Pending} (or the Q
          # event) instead of the name it wears: both answer `#digest`, so both
          # would sit in the map as a key no answer can ever match, and the
          # reply would then refuse a set that IS outstanding. Named at the
          # door rather than surfacing as that.
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
        # @raise [NoPendingQuestion] naming the digest, when no registered asker
        #   holds that name -- unknown, deregistered, or withdrawn
        # @raise [Promise::AlreadyResolved] when this directory already routed
        #   an answer to that name
        # @return [Lain::Event] the A :message event the asker wrote
        def reply(answer, digest) = holder_of(digest).reply(answer, digest)

        # Drop a registration, and with it every name it held. Answers the
        # registration itself rather than whether it was there: forgetting one
        # already forgotten is the same fact, not a different one.
        #
        # @return [Registration]
        def forget(registration)
          @registrations.delete(registration)
          registration
        end

        # How many names this directory can answer for -- open sets plus the
        # tombstones of answered ones. What a bench (or a spec) watches to see
        # that growth is bounded by REGISTRATION lifetime.
        def size = @registrations.sum(&:size)

        # The wired-nothing default: one asker, no routing needed, and no caller
        # writes `if directory`. Answers the whole duck -- registration
        # included, via {Unheld}, so a tool built against a directory works
        # identically without one -- and refuses every answer in the same words
        # a withdrawn set earns, because with nothing registered every name is
        # one nobody holds. A silent success would be a lie about a promise
        # nothing resolved.
        module Null
          def self.register(_asker) = Unheld
          def self.reply(answer, digest) = Unheld.reply(answer, digest)
          def self.forget(registration) = registration
          def self.size = 0
          def self.unanswerable(digest) = Directory.unanswerable(digest)
        end

        private

        def holder_of(digest) = @registrations.find(NOBODY) { |registration| registration.holds?(digest) }
      end
    end
  end
end
