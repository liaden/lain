# frozen_string_literal: true

module Lain
  class StatusFeed
    # The mode, as the HUD publishes it: the posture NAME, and the lighter
    # already composed out of that posture and every active layer.
    #
    # It reads a journaled {Telemetry::ModeSwitch}, never a live {Mode}, and
    # that is the whole reason it is not a method on {Mode}: a Mode raises on a
    # name it does not declare, which is right for a value being CONSTRUCTED
    # and wrong for a record being READ. See {.lighter_of}.
    #
    # == Why the lighter is composed here AND the names published beside it
    #
    # Three renderers read the published state feed -- `lain up`'s jq filter,
    # `plugin/tmux/scripts/lain-status`, and nvim's lualine. Publishing only the
    # NAMES would give each its own copy of the lighter table AND its own
    # comparison against the default posture's name (`accept_edits` must render
    # nothing), and both rules already have exactly one home ({Mode::Posture}
    # and {Mode::Layer} declare a `lighter`). Publishing only the LIGHTER would
    # make a bench arm asking "was `auto_approve` on for this arm?"
    # substring-match `"AA"` inside a rendered string. So all three ship.
    ModeState = Data.define(:posture, :layers, :lighter) do
      # String-keyed, for merging straight into {StatusFeed#observed}.
      def published = { "posture" => posture, "layers" => layers, "mode_lighter" => lighter }
    end

    class ModeState
      # Reopened rather than written inside the `Data.define ... do` block: a
      # constant declared in that block scopes to the enclosing module, not to
      # the Data class (the trap {Request::SYSTEM_PREFIX} documents), so `NONE`
      # would land as `Lain::StatusFeed::NONE`.

      # `mode_lighter` is the first FREE-FORM string this feed publishes, and
      # {.lighter_of}'s degradation path can put a foreign journal's raw name in
      # it. Nothing downstream bounds the width -- a 400-character posture name
      # would be pasted straight into tmux's `status-right`. Characters, not
      # bytes: `String#[]` is character-based, so a multibyte name cannot be
      # sliced into invalid UTF-8 and break the NDJSON line. Every declared
      # combination fits, so this only ever trims the degradation path.
      LIGHTER_CAP = 32

      # @param record [Telemetry::ModeSwitch] the flip that just landed
      # @return [ModeState] the mode now in force -- the `to` side only. The
      #   record carries both ends so a transcript can be reconstructed; a HUD
      #   publishes what is in force NOW.
      def self.of(record)
        new(posture: record.to, layers: record.to_layers, lighter: compose(record.to, record.to_layers))
      end

      # The posture's lighter, then each layer's, dropping the empties -- so the
      # silent default composes to `""` and a renderer's rule stays one
      # comparison. The layer ORDER is read, never re-derived: {Mode::LayerSet}
      # canonicalized it into precedence order before it was journaled.
      def self.compose(posture, layers)
        [lighter_of(Mode::Posture, posture), *layers.map { |name| lighter_of(Mode::Layer, name) }]
          .reject(&:empty?).join(" ")[0, LIGHTER_CAP]
      end

      # A name this build does not declare falls back to the name ITSELF. Both
      # `.for` methods raise `ArgumentError` on an unknown name, and
      # {StatusFeed} rides the {CLI::JournalTee}, which re-raises a sink's
      # failure -- so a record written by a newer lain, or replayed from an
      # older one, would cost the agent its turn over a status line. Falling
      # back to the raw name rather than to `""` is the half that matters: a
      # posture nobody here can resolve is precisely the one a human must not be
      # left guessing about, so it renders as itself instead of vanishing into
      # the silence the DEFAULT posture earns.
      def self.lighter_of(family, name)
        family.for(name).lighter
      rescue ArgumentError
        name.to_s
      end

      private_class_method :compose, :lighter_of

      # Before the first switch. {Mode::Switch} journals nothing at construction
      # and {StatusFeed} is built before `Wiring` exists, so it cannot ask;
      # absence is the honest answer, spelled as a Null Object so nobody writes
      # `if @mode`. `layers` is nil rather than `[]` for the same reason
      # `occupancy` is nil rather than zero: an empty list is a perfectly
      # ordinary layer set and would claim "nothing is active" for a feed that
      # has not been told anything at all.
      NONE = new(posture: nil, layers: nil, lighter: nil)
    end
  end
end
