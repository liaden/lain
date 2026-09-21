# frozen_string_literal: true

module Lain
  module Telemetry
    # Attribution for the session-fixed prompt slots, written ONCE at session
    # start. `digests` content-addresses each slot's RENDERED bytes -- the join
    # key onto a {RequestSent}'s system blocks -- and `fills` carries the raw
    # override SOURCE, the bytes a reader diffs to see WHY two runs' prompts
    # differ. Pure attribution, not replay: the rendered system text is
    # recoverable from {RequestSent}, so this adds identity and diffability
    # rather than a second copy of the prompt.
    SlotFills = Data.define(:digests, :fills) do
      include Journalable
      include Declarative

      # Anonymous (`declare`), because the record carries no validation a
      # reader would ever go looking for by name.
      declare do
        attribute :digests, :lain_canonical
        attribute :fills, :lain_canonical
      end

      # The session's one record, attributing what ACTUALLY rendered. An
      # `override:` renders INSTEAD of the slots, so a record still built from
      # them would carry digests that fail the join onto {RequestSent}'s system
      # blocks -- a coherent-looking lie.
      def self.from(slots, override: nil)
        return new(digests: slots.digests, fills: slots.fills) if override.nil?

        new(digests: { "system" => Canonical.digest(override) }, fills: { "system" => override })
      end

      # Explicit keywords: `Canonical.normalize(nil)` is nil, so a nameless
      # construction would build a perfectly valid record attributing nothing.
      def initialize(digests:, fills:) = super(**self.class.settle!(digests:, fills:))
    end
  end
end
