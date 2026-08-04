# frozen_string_literal: true

require "securerandom"

module Lain
  module Review
    Anchor = Data.define(:path, :side, :line, :anchor_text, :revision, :id) do
      include Telemetry::Journalable
    end

    # One reviewable position: which file, which side of a diff, which line, and
    # what that line read when the anchor was placed. Two anchors that name the
    # same position are the SAME anchor for reconciliation's purposes -- that is
    # why `id` is excluded from equality below, even though it is real,
    # persisted identity: a note built fresh in this process and the same note
    # replayed from the journal (carrying the id the journal recorded) must
    # still collapse under `uniq` and match in a `Set`.
    #
    # Reopened rather than folded into the `Data.define` block above -- same
    # reason as `Request::SYSTEM_PREFIX` (CLAUDE.md, Known traps): a `class`
    # keyword written INSIDE that block scopes to `Lain::Review`, not to the
    # Data-defined class, however natural `Anchor::UnknownSide` looks from the
    # call site. The docstring lives HERE and not above the `Data.define`
    # because YARD keeps only one docstring per namespace and silently discards
    # the rest; two of them is a yard-lint failure, not a style preference.
    class Anchor
      include Inspectable

      # An anchor's own `side` domain stays Symbols (every other field here is
      # a plain Ruby value, not a wire type), but the MEMBERSHIP decision is
      # made in exactly one place: Review::SIDES, which T5 owns and which is
      # Strings because the journal is the durable artifact and every record
      # stores Strings. Two independently-declared literals (`%i[old new]`
      # here, `%w[old new]` there) is the trap this derivation closes --
      # `spec/lain/review/anchor_spec.rb`'s "SIDES" example pins the two
      # spellings equal so they cannot drift apart silently again.
      SIDES = Review::SIDES.map(&:to_sym).freeze

      # An unrecognised side would silently name a diff position that cannot
      # exist rather than one of the two real ones -- refused loudly, naming
      # what was given, rather than let it drift into a diff position that
      # means nothing.
      class UnknownSide < Error; end

      # Wire-tolerant coercion, {Epic::WireInteger}'s shape: accept the native
      # form (a Symbol) or the String a journal read-back hands back, and
      # refuse everything else. `to_journal` -> NDJSON -> `JSON.parse` turns
      # `:new` into `"new"`; without this an anchor could not survive its own
      # round trip, which defeats the reason `id` is accepted-when-supplied in
      # the first place (replay).
      def self.side!(value)
        candidate = value.is_a?(String) ? value.to_sym : value
        return candidate if SIDES.include?(candidate)

        raise UnknownSide, "side must be one of #{SIDES.inspect}, got #{value.inspect}"
      end

      # A position that cannot exist: 0, negative, or not an Integer at all.
      # T2's hunk arithmetic (`start + offset - 1`) is exactly where a 0
      # would arrive -- without this, `line: 0` read `lines[-1]`, the LAST
      # line, and answered `drifted? == false` for a position that was never
      # named.
      class InvalidLine < Error; end

      def self.line!(value)
        return value if value.is_a?(Integer) && value >= 1

        raise InvalidLine, "line must be a positive Integer, got #{value.inspect}"
      end

      # Shape refusal shared by the String-domain fields below: one class, not
      # one per field, matching {Guardable}'s own rule that a per-rule
      # exception class moves the translation into the wrong object -- the
      # field name is already in the message.
      class InvalidField < Error; end

      def self.string!(value, field:)
        return value if value.is_a?(String)

        raise InvalidField, "#{field} must be a String, got #{value.inspect}"
      end

      # `anchor_text` is validated with {.string!} alone, never this: an
      # anchored blank line is a real, anchorable position, so "" is a valid
      # anchor_text and only `path`/`revision` (identifiers, never blank)
      # need the non-empty half of the check.
      def self.nonblank_string!(value, field:)
        candidate = string!(value, field:)
        return candidate unless candidate.empty?

        raise InvalidField, "#{field} must be a non-empty String, got #{value.inspect}"
      end

      def initialize(path:, side:, line:, anchor_text:, revision:, id: nil)
        # `-str` interns rather than `.dup.freeze`'s unconditional allocation:
        # an already-frozen literal (as every String literal is, under a
        # caller's own `frozen_string_literal: true`) dedupes to itself
        # instead of being copied.
        #
        # id is generated when absent, but ACCEPTED when supplied: replay has
        # to restore the very id the journal recorded, never mint a new one.
        # `.to_s` guards it alone: `id` carries no domain check (nothing here
        # named one), so a bare `-id` on a non-String id would silently
        # NEGATE an Integer instead of refusing it -- `Integer#-@` is
        # arithmetic, not String's interning unary minus.
        super(path: -self.class.nonblank_string!(path, field: "path"),
              side: self.class.side!(side),
              line: self.class.line!(line),
              anchor_text: -self.class.string!(anchor_text, field: "anchor_text"),
              revision: -self.class.nonblank_string!(revision, field: "revision"),
              id: -(id || SecureRandom.uuid).to_s)
      end

      # Equal exactly when two anchors of the SAME concrete class name the
      # same position. `id` is excluded on purpose (see the class comment).
      # `instance_of?`, not `is_a?`: `is_a?` is direction-sensitive (a
      # subclass `is_a?` its parent but not the reverse), which made
      # `parent == sub` true while `sub == parent` stayed false for the same
      # pair -- exactly what breaks `Set`/`Hash`/`Array#uniq`, the
      # collections this card's ACs exist to protect.
      def ==(other)
        other.instance_of?(self.class) && to_h.except(:id) == other.to_h.except(:id)
      end
      alias eql? ==

      def hash
        to_h.except(:id).hash
      end

      # Drift is `anchor_text` against the line the number now names -- the
      # same rule Lain::Epic::Review::Annotations applies to an editor
      # extmark: the anchor is stale exactly when the document has moved on
      # without it.
      #
      # A line past the document's end, or an empty document, both index to
      # `nil` (no such line), which can never equal `anchor_text` -- so both
      # answer `true`, the same as a line whose text merely changed. That
      # deliberately collapses "moved" and "gone" into one boolean: telling
      # them apart is the drift-model spike this card's own third escalation
      # trigger fences off as research open question 1 (`anchor_text` alone
      # vs. surrounding context). This card answers only "does this position
      # still say what it said"; both cases answer no.
      def drifted?(document)
        document.lines(chomp: true)[line - 1] != anchor_text
      end

      # revision[0, 7] is unguarded, but revision is validated non-empty at
      # construction (see #initialize), so the empty-revision trailing-space
      # case a guard here would exist to catch cannot be reached -- adding one
      # would be redundant with the constructor.
      def to_s
        "#{path}:#{line}(#{side}) #{revision[0, 7]}"
      end
    end
  end
end
