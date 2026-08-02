# frozen_string_literal: true

module Lain
  class StatusFeed
    # The mode, as the HUD publishes it: the posture NAME, and the lighter
    # already composed out of that posture and every active layer. Extracted
    # from {StatusFeed} for {Publication}'s reason -- deriving a field from an
    # event and rendering the mode ladder into a status-bar string change for
    # different reasons, and the cop naming the class's line budget was naming
    # that.
    #
    # It reads a journaled {Telemetry::ModeSwitch}, never a live {Mode}, and
    # that is the whole reason it is not a method on {Mode}: a Mode raises on a
    # name it does not declare, which is right for a value being CONSTRUCTED
    # and wrong for a record being READ. See {.lighter_of}.
    #
    # == Why the lighter is composed here AND the names published beside it
    #
    # Three renderers read `.lain/state.json` -- `lain up`'s jq filter,
    # `plugin/tmux/scripts/lain-status`, and nvim's lualine. Publishing only
    # the NAMES would give each of them its own copy of the lighter table AND
    # its own comparison against the default posture's name, since
    # `accept_edits` must render nothing; both rules already have exactly one
    # home ({Mode::Posture} and {Mode::Layer} declare a `lighter`, empty for
    # the silent default), so `mode_lighter` reduces a renderer's whole job to
    # "draw it if it is not empty".
    #
    # That argues against publishing names INSTEAD of the lighter, which is not
    # the choice: all three ship. A bench arm asking "was `auto_approve` on for
    # this arm?" must otherwise substring-match `"AA"` inside a rendered
    # string, which is exactly the comparison a study bench exists to make
    # cheap -- and the exclusive slot already ships as data, so publishing the
    # layer half only as a substring was an asymmetry with no argument behind
    # it. A renderer that does not know `layers` ignores it; `CLI::Command::Status`
    # is the shipped demonstration that a reader takes the keys it knows.
    ModeState = Data.define(:posture, :layers, :lighter) do
      # String-keyed, for merging straight into {StatusFeed#observed}. The
      # three keys answer different questions and each earns its place:
      # `posture` is the exclusive slot as DATA, `layers` the composable half
      # as data, `mode_lighter` what a status bar draws.
      def published = { "posture" => posture, "layers" => layers, "mode_lighter" => lighter }
    end

    # Reopened rather than written inside the `Data.define ... do` block: a
    # constant declared in that block scopes to the enclosing module, not to
    # the Data class (the trap {Request::SYSTEM_PREFIX} documents), so `NONE`
    # would land as `Lain::StatusFeed::NONE`.
    class ModeState
      # `mode_lighter` is the first FREE-FORM string this feed publishes, and
      # {.lighter_of}'s degradation path can put a foreign journal's raw name
      # in it. Everything else on the HUD is a glyph, a count or a percentage,
      # so nothing downstream bounds the width -- a 400-character posture name
      # would be pasted straight into tmux's `status-right` and push the whole
      # line off the bar. Characters, not bytes: `String#[]` is character-based,
      # so a multibyte name cannot be sliced into invalid UTF-8 and break the
      # NDJSON line. Every declared combination is 21 characters or fewer, so
      # this only ever trims the degradation path.
      LIGHTER_CAP = 32

      # @param record [Telemetry::ModeSwitch] the flip that just landed
      # @return [ModeState] the mode now in force -- the `to` side only. The
      #   record carries both ends so a transcript can be reconstructed; a HUD
      #   publishes what is in force NOW.
      def self.of(record)
        new(posture: record.to, layers: record.to_layers, lighter: compose(record.to, record.to_layers))
      end

      # The posture's lighter, then each layer's, dropping the empties -- so
      # the silent default composes to `""` and a renderer's rule stays one
      # comparison. The record's layer ORDER is read, never re-derived:
      # {Mode::LayerSet} canonicalized it into precedence order before it was
      # journaled, and a second canonicalization here would be a copy of a rule
      # with one home.
      def self.compose(posture, layers)
        [lighter_of(Mode::Posture, posture), *layers.map { |name| lighter_of(Mode::Layer, name) }]
          .reject(&:empty?).join(" ")[0, LIGHTER_CAP]
      end

      # A name this build does not declare falls back to the name ITSELF. Both
      # `.for` methods raise `ArgumentError` on an unknown name, and
      # {StatusFeed} rides the {CLI::JournalTee}, which re-raises a sink's
      # failure -- so a record written by a newer lain, or replayed from an
      # older one, would cost the agent its turn over a status line. That is
      # the failure {StatusFeed#occupancy_of} already rescues one field up.
      #
      # Falling back to the raw name rather than to `""` is the half that
      # matters: a posture nobody here can resolve is precisely the one a human
      # must not be left guessing about, so it renders as itself instead of
      # vanishing into the silence the DEFAULT posture earns.
      def self.lighter_of(family, name)
        family.for(name).lighter
      rescue ArgumentError
        name.to_s
      end

      private_class_method :compose, :lighter_of

      # Before the first switch. {Mode::Switch} journals nothing at
      # construction -- the initial mode is the wiring's choice, already
      # visible in the session's flags -- and {StatusFeed} is built before
      # `Wiring` exists, so it cannot ask. Absence is the honest answer, and a
      # Null Object is how it is spelled: nobody writes `if @mode`.
      #
      # `layers` is nil rather than `[]` for the same reason `occupancy` is nil
      # rather than zero: an empty list is a perfectly ordinary layer set and
      # would claim "nothing is active" for a feed that has not been told
      # anything at all.
      NONE = new(posture: nil, layers: nil, lighter: nil)
    end
  end
end
