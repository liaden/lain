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
      # bytes are gone, except the prose an assistant wrote beside a tool call,
      # which survives as text within a per-message byte budget; the line names
      # what stood there. The rendering is
      # {SummarySnapshot.attest}, the one place a message is attested; the
      # snapshot object itself is keyed on TOOL-RESULT source digests and built by
      # `.take` over an {Oracle::Eager} -- a different question from attesting a
      # span.
      #
      # THE DIGEST IS A FINGERPRINT, NOT A STORE KEY. It hashes the RENDERED
      # message ({EventLog::Messages.project}'s shape) while the Store is keyed by
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
      # message and not others. Here every tool block is elided identically, so
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

        TOOL_BLOCKS = %w[tool_use tool_result].freeze

        # One budget per message, so eliding many prose blocks still shrinks the request.
        KEPT_PROSE_BYTES = 1024

        ELLIPSIS = "..."

        # The whole span, in one range. There is no cut this strategy could
        # prefer: it answers the same bytes under every partition of the span.
        def propose_ranges(_messages, span:) = [span]

        # The concatenation of the per-message map, written out: that shape is
        # the homomorphism, and its spec holds it to the elementwise laws.
        def blocks(messages) = messages.flat_map { |message| attested(message) }

        private

        def attested(message)
          [{ "type" => "text", "text" => [attestation(message), *gists(message), ELIDED].join(" ") },
           *prose(message)]
        end

        # The tool_use and its tool_result are elided in the same range, so no half of a pair survives.
        def prose(message)
          return [] unless message["role"] == "assistant" && tool_blocks?(message)

          budget = KEPT_PROSE_BYTES
          texts(message).each_with_object([]) do |text, kept|
            fitted = fit(text, budget)
            next_budget = fitted.nil? ? 0 : budget - fitted.bytesize
            kept << { "type" => "text", "text" => fitted } if fitted
            budget = next_budget
          end
        end

        def texts(message)
          message.fetch("content").grep(Hash).filter_map do |block|
            text = block["text"].to_s.strip
            text if block["type"] == "text" && !text.empty?
          end
        end

        def tool_blocks?(message) = message.fetch("content").any? { |block| TOOL_BLOCKS.include?(block["type"]) }

        # Cut on a character boundary with the ellipsis inside the budget.
        def fit(text, budget)
          return text if text.bytesize <= budget

          room = budget - ELLIPSIS.bytesize
          used = 0
          head = text.each_char.take_while { |char| (used += char.bytesize) <= room }.join
          head.empty? ? nil : "#{head}#{ELLIPSIS}"
        end

        def attestation(message) = "[#{SummarySnapshot.attest(message)}]"

        # A tool round's bytes are gone, so the line is the only place that
        # still says which tool ran against which path.
        def gists(message)
          content = message.fetch("content", nil)
          return [] unless content.is_a?(Array)

          content.grep(Hash).filter_map do |block|
            Oracle::Handoff.gist(block) if TOOL_BLOCKS.include?(block["type"])
          end
        end
      end
    end
  end
end
