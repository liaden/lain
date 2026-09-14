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
      # THE INVARIANT IS {SummarySnapshot}'s: nothing disappears unattested. The
      # bytes are gone, but the line names what stood there. The rendering is
      # copied from {SummarySnapshot#attest} rather than delegated to it,
      # because that object is keyed on TOOL-RESULT source digests and built by
      # `.take` over an {Oracle::Eager} -- a different question from attesting a
      # span. What is shared is the discipline, not the object.
      #
      # THE DIGEST IS A FINGERPRINT, NOT A STORE KEY. It hashes the RENDERED
      # message ({Derivation.projected}'s shape) while the Store is keyed by
      # `Event#digest`, the digest of an event's PAYLOAD: different bytes,
      # different hash, so `store.key?` on one of these lines is false and
      # `store.fetch` raises MissingObject. What it buys is verifying that a
      # candidate message is the one that was elided, and telling two elided
      # messages apart. Recovery is a different mechanism: the replacement
      # event's `causal_parents` ARE Store keys, and they are the fibre of the
      # collapse.
      #
      # It renders one line per MESSAGE where {SummarySnapshot} renders one per
      # block, because that object's summaries may exist for SOME blocks of a
      # message and not others. Here every block is elided identically, so
      # there is no per-block fact to state.
      #
      # == Why it is a homomorphism, and why that matters
      #
      # {#blocks} is the concatenation of a per-message map, so by the
      # universal property of the free monoid this is a monoid homomorphism.
      # That is what makes it the control arm rather than merely a
      # cheap strategy: where the boundary between two collapsed ranges falls
      # cannot change the bytes it answers, so a derivation over it measures the
      # policy under test and never the cut points.
      #
      # An empty span answers DROP, the unit -- the range vanishes with no
      # replacement event, rather than rendering a placeholder line about
      # nothing. {SummarySnapshot::NOTHING} exists because that duck answers a
      # String and an empty one becomes a text block the provider rejects; a map
      # into the free monoid has a real unit instead, and it is the unit law the
      # homomorphism rests on.
      class Elide < Base
        # It holds nothing, so the whole of its construction is the freeze. Not
        # on {Base}: a strategy may hold a live oracle and a memo, and freezing
        # every strategy is the one thing that would break.
        prepend Freezable

        # Its own prose rather than {SummarySnapshot::ELIDED}'s, because the
        # reason differs: there was never a summary to hold, by design.
        ELIDED = "(elided -- no summary was taken)"

        # The whole span, in one range. There is no cut this strategy could
        # prefer: it answers the same bytes under every partition of the span.
        def propose_ranges(_messages, span:) = [span]

        # The concatenation of the per-message map, written out: that shape is
        # the homomorphism, and its spec holds it to the elementwise laws.
        def blocks(messages) = messages.flat_map { |message| attested(message) }

        private

        def attested(message) = [{ "type" => "text", "text" => "[#{attest(message)}] #{ELIDED}" }]

        # Byte-for-byte {SummarySnapshot#attest}, including its `fetch`: the
        # role is ours, so a missing one is a caller bug and not a blank to
        # render past.
        def attest(message)
          "#{message.fetch("role")} #{Canonical.digest(message)} #{Canonical.dump(message).bytesize} bytes"
        end
      end
    end
  end
end
