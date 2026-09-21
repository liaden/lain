# frozen_string_literal: true

module Lain
  class Mode
    # One composable, orthogonal toggle -- Emacs' minor mode. A layer is
    # DECLARATION only; scope and approval own the exclusive slots, and a layer is
    # everything that does not need one.
    #
    # `alters_outcome` is a declared field rather than a comment because a
    # silently-active policy is a bug: the obligation is checked where a layer
    # is BORN, so declaring one outcome-altering and silent raises, which binds
    # the fifth layer somebody adds long after this file was reviewed. The
    # converse is deliberately free -- a layer that cannot move an outcome may
    # render nothing.
    Layer = Data.define(:name, :lighter, :alters_outcome) do
      # `Layer::Declaration` is qualified because constants defined inside a
      # `Data.define do ... end` block are lexically scoped to the ENCLOSING
      # module, not to the Data class -- a bare `Declaration` would resolve
      # against `Lain::Mode` and fail.
      def initialize(name:, lighter:, alters_outcome:)
        Layer::Declaration.check!(name:, lighter:, alters_outcome:)
        # `-lighter.to_s` and not `lighter.to_s.freeze`: `Symbol#to_s` returns a
        # MUTABLE String, and one mutable member flips `Ractor.shareable?` to
        # false for the whole value.
        super(name: name.to_sym, lighter: -lighter.to_s, alters_outcome:)
      end

      def alters_outcome? = alters_outcome

      def to_s = lighter.empty? ? name.to_s : "#{name} (#{lighter})"
    end

    class Layer
      # Reopened for the reason the comment above gives: nested classes and
      # constants declared in a `Data.define` block do not land on the Data
      # class.

      # On a throwaway {Lain::Declarative::Carrier} because a frozen value must
      # never include ActiveModel itself -- `valid?` leaves mutable ivars behind
      # and `Ractor.shareable?` goes false.
      #
      # `check!` and not `settle!`: `name` is coerced with `#to_sym` and
      # `lighter` with `-#to_s`, and no declared type does either -- a settled
      # copy would hand back a String name and a merely-frozen lighter.
      class Declaration < Declarative::Carrier
        attribute :name
        attribute :lighter, :string
        attribute :alters_outcome

        validates :name, presence: true
        # Not `presence: true` on a Boolean: `false.present?` is false, so a
        # perfectly valid silent layer would be rejected. Inclusion is the check
        # that actually means "is a Boolean".
        validates :alters_outcome, inclusion: { in: [true, false] }
        validates :lighter, presence: true, if: -> { alters_outcome }
      end

      # @param name [Symbol, String] one of {NAMES}
      # @return [Layer]
      # @raise [ArgumentError] naming every declared layer -- an unknown layer
      #   is a typo in a `/mode +foo` invocation, and the human needs the list
      def self.for(name)
        DECLARED.fetch(name.to_sym) do
          raise ArgumentError, "unknown mode layer #{name.inspect}, expected one of #{NAMES.inspect}"
        end
      end

      # Every declared layer, in declaration order. That order is the precedence
      # order a {LayerSet} canonicalizes to and the one `/mode` reports in.
      def self.all = DECLARED.values

      # Declared after the methods that read it, which reach it at call time, so
      # nothing above needs a forward reference. `:auto_approve` is the only
      # member that answers `alters_outcome?` today: {Approval::AutoSurface}
      # watches every attended session's parked calls and decides one a human
      # would otherwise have been asked about only while this layer is on,
      # whether `--auto-approve` or `/mode +auto_approve` turned it on. The
      # other three change what the human sees or how input is read, never what
      # is permitted: `vi` reads the prompt in vi mode, and `notify` rings the
      # terminal's bell when something arrives for the human, with a tmux
      # message inside tmux and nothing anywhere else -- which is why its lighter
      # says BELL and not something a desktop notifier would answer to.
      DECLARED = {
        auto_approve: new(name: :auto_approve, lighter: "AA", alters_outcome: true),
        goal: new(name: :goal, lighter: "GOAL", alters_outcome: false),
        notify: new(name: :notify, lighter: "BELL", alters_outcome: false),
        vi: new(name: :vi, lighter: "VI", alters_outcome: false)
      }.freeze
      private_constant :DECLARED

      # DERIVED from the table so the roster and the error that lists it cannot
      # drift apart.
      NAMES = DECLARED.keys.freeze
    end
  end
end
