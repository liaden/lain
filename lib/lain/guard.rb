# frozen_string_literal: true

require "active_model"

module Lain
  # A throwaway ActiveModel carrier for validate-then-freeze construction.
  #
  # A frozen value object must never `include ActiveModel::Validations` itself:
  # the first `valid?`/`invalid?` call materializes both an `@errors` AND a
  # `@context_for_validation` ivar, both mutable, and either one surviving to
  # `freeze` flips `Ractor.shareable?` to false -- the mechanical spec for "no
  # reachable mutable state". So construction is validated on a SEPARATE carrier
  # that is checked and discarded: the value object never touches ActiveModel,
  # and its shareability is preserved by construction rather than by remembering
  # to scrub whichever set of ivars ActiveModel happens to leave behind.
  #
  # Subclass it, declare `attribute`/`validates` like any ActiveModel, and call
  # `.check!(**kwargs)` from a constructor before the value is frozen. On failure
  # it raises ArgumentError naming the attribute -- the same exception the
  # hand-rolled guard clauses raised, so callers and specs keep a single
  # exception surface and never see `ActiveModel::ValidationError` leak out (the
  # choice of ActiveModel is an implementation detail of HOW we validate, not
  # part of a constructor's contract).
  #
  # Like {Lain::Tool::Input}, these validations check SHAPE, not safety.
  class Guard
    include ActiveModel::Model
    include ActiveModel::Attributes

    # ActiveModel::Naming needs a name for `errors.full_messages`; an anonymous
    # carrier (built by a DSL) would raise before it could report the error.
    # Named subclasses fall back to their own constant name. Same reason as
    # {Lain::Tool::Input.model_name}.
    def self.model_name
      @model_name ||= ActiveModel::Name.new(self, nil, name || "Guard")
    end

    # Validate the kwargs and raise ArgumentError naming the first offending
    # attribute. The message is `"<attribute> <message>"` -- the lower-cased
    # attribute plus the validator's own message -- so it reads as diagnostically
    # as the guard clause it replaces and matches the same `/attribute/` regexes
    # the specs already pin. The carrier is never returned or stored.
    def self.check!(**attrs)
      carrier = new(**attrs)
      return if carrier.valid?

      raise ArgumentError, carrier.errors.map { |error| "#{error.attribute} #{error.message}" }.join(", ")
    end
  end
end
