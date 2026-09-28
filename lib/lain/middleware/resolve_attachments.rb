# frozen_string_literal: true

module Lain
  module Middleware
    # Puts an attachment's bytes back into the Request, as late as they can
    # possibly go: the model phase's INNERMOST member, downstream of
    # {JournalRequests} and one hop from the provider.
    #
    # The position is the feature. An address on the Timeline costs about a
    # hundred bytes and is written once per distinct picture; the same picture
    # inline is re-serialized into EVERY later `request_sent`, which measured at
    # 86x the journal over ten exchanges and clears the compaction threshold on
    # its own. And it may not be resolved any EARLIER either: base64 is valid
    # UTF-8, so a resolved payload reaching {Canonical.normalize} would be
    # interned by `-@` silently and for the life of the process, and
    # {Context#render} is a pure function whose purity and the prompt cache's
    # hit rate are one constraint.
    #
    # Composed in {CLI::Wiring#model_phase} rather than in
    # {CLI::Chronicle.instrumentation}, which has no model stack at all under
    # `--no-journal` -- a picture is no less needed for going unrecorded. A
    # spawned child gets its own, over the run's same store
    # ({Tools::Subagent::ChildBuilder}), because a child that did not resolve
    # would send the address string as if it were an answer.
    class ResolveAttachments < Base
      # The store a stack assembled without one resolves against. It answers the
      # one message a store answers and answers it with the refusal: a picture
      # nobody can find is not a turn worth sending, and the digest string is
      # not a substitute for it.
      module Unwired
        def self.fetch(digest)
          raise Attachment::Store::Missing,
                "no attachment store is wired into this model stack, so #{digest} cannot be resolved"
        end

        def self.key?(_digest) = false

        def self.to_s = "Lain::Middleware::ResolveAttachments::Unwired"
        singleton_class.alias_method(:inspect, :to_s)
      end

      # A {Lain::Request} whose messages carry BYTES, wrapped around one whose
      # messages carry addresses.
      #
      # Deliberately NOT `Request#with`: `Data#with` re-runs
      # `Request#initialize`, which normalizes through {Canonical}, which interns
      # every String -- so the one construction that looks most natural here is
      # exactly the one that pays, in silence, the cost the address was
      # introduced to avoid.
      #
      # Delegation also keeps the identity of the turn intact. #digest,
      # #cache_payload and #prefix_digests answer for the ADDRESSED request, so
      # the retry frame, the stream-started signal and the journalled
      # `request_sent` all name one turn, and resolution is not mistaken for a
      # rewrite. Only #messages differs, and only the encoders read it.
      class Resolved
        # @return [Array<Hash>] the messages with every address resolved
        attr_reader :messages

        delegate :model, :system, :tools, :max_tokens, :stream, :reasoning, :extra,
                 :digest, :cache_payload, :cache_prefix, :prefix_digests, :to_s, to: :@request

        def initialize(request, messages)
          @request = request
          @messages = messages
          freeze
        end

        def inspect = "#<#{self.class} #{self}>"

        # REFUSED, for the reason {Env#to_json} states at length: an un-delegated
        # lens serializes as the `to_s` of its own object header -- VALID JSON
        # carrying a debug string -- which the NDJSON Journal accepts in silence
        # where a raise would be caught. Delegation is the usual close and does
        # not work here: a `Data` answers `to_json` the same way, so it would
        # inherit the trap one level down.
        #
        # Nothing should serialize this object at all. It lives for one hop and
        # carries image bytes; the record of a request is
        # {Telemetry::RequestSent}, over the ADDRESSED #cache_payload, which is
        # the whole saving the address exists for.
        def to_json(*)
          raise Error, "a resolved Request carries image bytes and is not a record: journal " \
                       "Telemetry::RequestSent.from(request), which holds the addresses instead"
        end
      end

      # @return [#fetch] the store this resolves against, readable so a spec can
      #   prove it is the run's ONE store rather than a second directory that
      #   merely computes the same path
      attr_reader :attachments

      # @param attachments [#fetch] the run's {Attachment::Store}
      def initialize(attachments: Unwired)
        @attachments = attachments
        super()
        freeze
      end

      def call(env, &app)
        request = env.fetch(:request)
        addressed = Attachment::Reference.each_in(request.messages).to_a
        return downstream(env, &app) if addressed.empty?

        downstream(env.merge(request: Resolved.new(request, resolved(request.messages))), &app)
      end

      private

      def resolved(messages)
        Attachment::Reference.resolve(messages) { |reference| @attachments.fetch(reference.digest) }
      end
    end
  end
end
