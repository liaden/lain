# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # The free strategy: a span collapses to a deterministic ATTESTATION of
      # what was there -- each message's role, content address and byte count --
      # with no model call, no I/O and no oracle. It is the honest floor under a
      # model-backed strategy, and the control arm any comparison of compaction
      # policies is measured against.
      #
      # THE INVARIANT IS {SummarySnapshot}'s (`summary_snapshot.rb:33-41`):
      # nothing disappears unattested. The bytes are gone, but the line names
      # what stood there. The rendering is copied from {SummarySnapshot#attest}
      # rather than delegated to it: that object is keyed on TOOL-RESULT source
      # digests and built by `.take` over an {Oracle::Eager}, which is a
      # different question from attesting a span. What is shared is the
      # discipline, not the object.
      #
      # THE DIGEST IS A FINGERPRINT, NOT A STORE KEY. It hashes the RENDERED
      # message -- `{"role" =>, "content" =>}`, {Derivation.projected}'s shape --
      # while the Store is keyed by `Event#digest`, the digest of an event's
      # PAYLOAD (`event.rb:85`). Different bytes, different hash: `store.key?`
      # on one of these lines is false and `store.fetch` raises MissingObject.
      # What it buys is what a fingerprint buys -- verifying that a candidate
      # message is the one that was elided, and telling two elided messages
      # apart. Recovery is a different mechanism entirely: the replacement
      # event's `causal_parents` ARE Store keys, and they are the fiber of the
      # collapse.
      #
      # It renders one line per MESSAGE where {SummarySnapshot} also renders one
      # per block, and the difference is not a shortcut. That object goes per
      # block because a summary may exist for SOME blocks of a message and not
      # others, so a single body would let the unsummarized ones vanish behind a
      # line reading as a complete summary. Here every block is elided
      # identically -- there is no per-block fact to state -- and the message's
      # own digest and byte count already say what was there and which message
      # it was. {SummarySnapshot#render} (`:184-186`) emits this very line for a
      # message it finds no blocks in, so this is that branch generalized.
      #
      # == Why the algebra is declared and not asserted
      #
      # It is the pure/elementwise cell of the 2x2, and it writes only its
      # per-message map: {Algebra::Elementwise} generates the whole-span
      # {Base#blocks} as the concatenation of that map, so by the universal
      # property of the free monoid this is a monoid homomorphism BY
      # CONSTRUCTION. That is what makes it the control arm rather than merely a
      # cheap strategy: where the boundary between two collapsed ranges falls
      # cannot change the bytes it answers, so a derivation over it measures the
      # policy under test and never the cut points.
      #
      # An empty span answers DROP, the unit -- the range vanishes with no
      # replacement event at all, rather than rendering a placeholder line about
      # nothing. {SummarySnapshot::NOTHING} exists because that duck answers a
      # String and an empty one becomes a text block the provider rejects; a map
      # into the free monoid has a real unit instead, and it is the unit law the
      # homomorphism rests on.
      class Elide < Base
        include Algebra::Elementwise
        include Algebra::Pure

        # The body of a line with no summary behind it, as
        # {SummarySnapshot::ELIDED} is: the attestation carries the facts, this
        # says only that the bytes are gone. Its own prose because the reason
        # differs -- there was never a summary to hold, by design.
        ELIDED = "(elided -- no summary was taken)"

        def initialize
          super
          freeze
        end

        # The whole span, in one range. There is no cut this strategy could
        # prefer: it answers the same bytes under every partition of the span,
        # which is the property immediately above.
        def propose_ranges(_messages, span:) = [span]

        private

        def attested(message) = [{ "type" => "text", "text" => "[#{attest(message)}] #{ELIDED}" }]

        # Byte-for-byte {SummarySnapshot#attest} (`summary_snapshot.rb:194`),
        # including its `fetch`: the role is ours -- every writer in `lib/`
        # commits one -- so a missing one is a caller bug and not a blank to
        # render past.
        def attest(message)
          "#{message.fetch("role")} #{Canonical.digest(message)} #{Canonical.dump(message).bytesize} bytes"
        end

        # BELOW the helpers they name, which is load-bearing rather than a style
        # note: both are checked when the declaration runs. The `private` above
        # does NOT reach the generated {Base#blocks}: `define_method` runs inside
        # the macro, where the class body's default visibility is not in scope,
        # so #blocks stays public -- which is what it must be, since #collapse
        # and the registry sweep both read it.
        elementwise on: :blocks, each: :attested
        pure on: :blocks
      end
    end
  end
end
