# frozen_string_literal: true

module Lain
  module Review
    Placement = Data.define(:kind)

    # Where a review's surface opens.
    #
    # One legal member today -- `:tabpage`, the review's own tabpage inside the
    # nvim the session already has -- so this looks like a value object with
    # nothing to decide. It is here for the REFUSAL, which is the part that
    # carries information: `:tmux_window` is a placement that was designed,
    # costed and deliberately left out, and the difference between "not a
    # placement" and "that placement, blocked on something named" is exactly
    # what a reader needs in order not to "fix" it by widening the set.
    #
    # The set is held here and not in {Review::VOCABULARY}'s file, which is the
    # one apparent exception to "every closed set in one place". That file is
    # about the sets a JOURNALED record is judged against -- what NDJSON carries
    # and what a reader joins on a year later, canonically as Strings. No record
    # stores a placement: it routes one render and is gone, so it lives with the
    # object that routes it and is spelled in Symbols, like
    # {CLI::TmuxSurface::Placement#kind} beside it. That is one set, declared
    # once and compared nowhere -- not the two-copies-never-reconciled shape the
    # vocabulary file exists to prevent.
    #
    # The comparison it is NOT making is worth writing down before somebody
    # assumes it: the tmux tier spells that same surface `:window`, where this
    # spells it `:tmux_window` because here the word has to say which EDITOR it
    # belongs to. When the second placement lands, that is a mapping somebody
    # writes out, never a correspondence two Symbols are taken to have.
    class Placement
      # A placement that was asked for and cannot be given.
      class Unsupported < Error; end

      # Symbols, not Strings: this value never reaches a journal, and the tmux
      # tier it will one day grow into already spells its own `kind` this way.
      SUPPORTED = %i[tabpage].freeze

      # Placements that EXIST as designs and are refused anyway, each with the
      # thing it is actually blocked on. Kept apart from an unknown name because
      # the two call for opposite responses: an unknown name is a typo, and one
      # of these is an architecture change nobody has taken.
      DEFERRED = {
        tmux_window: "a second editor attachment is not yet supported -- it needs a second " \
                     "Frontend::Neovim attached to a second socket, and Cockpit computes the socket " \
                     "once from the cwd hash, which is an architecture change rather than a flag"
      }.freeze

      # @param kind [Symbol, String] the placement asked for
      # @return [Symbol] the same placement, as the Symbol this object holds
      # @raise [Unsupported] naming the placement, and either what it is blocked
      #   on or which placements do exist
      def self.supported!(kind)
        wanted = kind.respond_to?(:to_sym) ? kind.to_sym : kind
        return wanted if SUPPORTED.include?(wanted)

        raise Unsupported, refusal(wanted)
      end

      # @param wanted [Object] the placement that was refused
      # @return [String]
      def self.refusal(wanted)
        blocked = DEFERRED[wanted]
        return "placement #{wanted.inspect}: #{blocked}" if blocked

        "placement #{wanted.inspect} is not one this review surface knows; " \
          "supported: #{SUPPORTED.map(&:inspect).join(", ")}"
      end

      def initialize(kind:)
        super(kind: Placement.supported!(kind))
      end

      # The placement a review takes when nobody says otherwise, and the only
      # one this chunk can give.
      DEFAULT = new(kind: :tabpage)
    end
  end
end
