# frozen_string_literal: true

module Lain
  class Provider
    # The provider a `--dry-run` assembles: it satisfies the {Provider} duck and
    # refuses, loudly, the moment anything asks it for a round trip.
    #
    # It exists because the alternative was a `nil` that travels: a nil
    # `provider:` checked at USE made every collaborator optional, put the
    # failure a long way from the wiring that caused it, and made a genuine
    # mis-wire indistinguishable from a deliberate dry run.
    #
    # {Sink::Null} is the same pattern with the opposite ending -- it swallows,
    # because bytes going nowhere is a legitimate outcome. A dry pass touching
    # the network is a defect rather than an outcome, so this Null raises rather
    # than returning an empty {Response} that would read as a model with nothing
    # to say.
    class Unreachable < Provider
      # Something asked a dry run's provider for work. Always a defect at the
      # call site, never a condition to handle -- named so a backtrace says
      # which, and so `rescue Lain::Error` in the exe prints a message instead
      # of a backtrace.
      class Reached < Error; end

      # Why every refusal below refuses, in one sentence with one home.
      DRY_RUN = "this provider was assembled for --dry-run: nothing in a dry pass may reach a model"

      # Nothing, honestly. NOT raised, unlike {#complete}: a raise here would
      # make the object unprintable, and it exists to be REPORTED.
      def capabilities = [].freeze

      # No caching -- and never another provider's economics by accident (the
      # {CacheProfile::NO_CACHING} default {Provider::Mock} takes, for the same
      # reason).
      def cache_profile = CacheProfile::NO_CACHING

      # {Provider#to_s} projects the capability list, which HERE is empty, so
      # the inherited version prints nothing and `inspect` prints a class name
      # with a hole after it.
      def to_s = "unreachable provider (assembled for --dry-run; no model)"

      # Encoding a payload is preparing to send one, so it refuses too: a dry
      # surface that wanted bytes to show would be building a request, which is
      # {Provider::Mock}'s job.
      def encode(_request) = unreachable!("#encode")

      # Accepts every call shape {Provider#complete} has (`on_stream_started:`
      # included) so no signature slips past into a NoMethodError that hides the
      # real story.
      def complete(_request, **) = unreachable!("#complete")

      # {Capability::Policy::Strict} asks this BEFORE anything calls
      # {#complete}, and the inherited answer -- "does not support :streaming"
      # -- is true and useless, sending a reader looking for another tactic when
      # the answer is "you are in a dry pass". The TYPE stays
      # {Provider::Unsupported}, because Strict's contract is that a missing
      # capability raises that; only the sentence changes.
      def require!(capability)
        raise Unsupported, "Provider::Unreachable cannot support #{capability.inspect}: #{DRY_RUN}"
      end

      private

      def unreachable!(method) = raise(Reached, "Provider::Unreachable#{method} was called, but #{DRY_RUN}")
    end
  end
end
