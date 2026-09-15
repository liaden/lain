# frozen_string_literal: true

require "active_model"
require "bigdecimal"

module Lain
  module Declarative
    # Strict coercion types, for attributes where a malformed value must not pass in silence.
    #
    # ActiveModel's stock types are lenient by design -- measured:
    # `ActiveModel::Type::Integer.new.cast("3x")` returns `3` where `Integer("3x")` raises
    # `ArgumentError`. That is the same failure mode CLAUDE.md's `StringInquirer` rejection names,
    # just moved from a typo'd predicate to a coerced attribute. These types wrap the strict
    # primitive instead of the lenient one, so a carrier attribute inherits loud failure rather
    # than losing it.
    #
    # Both types are LAZY, because `ActiveModel::Type::Value#cast` runs when the attribute is
    # READ, not when the carrier is constructed: `carrier_class.new(n: "3x")` succeeds; `.n`
    # raises. That laziness is neutralized ONLY IF the carrier's every declared attribute gets
    # read during construction of whatever holds it -- which is a REQUIREMENT this file places on
    # `Declarative#settle!`, not a description of behavior already landed (at the time this file
    # was written, `settle!` did not exist yet). `settle!` must read every declared attribute in
    # order to extract it, forcing any lazy cast -- and therefore any strict-type raise -- to
    # happen during that extraction rather than whenever some later caller happens to read the
    # attribute. A caller that builds a carrier and never reads an attribute (nor calls
    # `settle!`) will not see the raise. Do not "fix" that by casting eagerly here -- it would
    # just duplicate work `settle!` is required to already do.
    #
    # Also lazy, for the same reason: an attribute's `default:` value is not cast at declaration
    # or at construction, only the first time the attribute is read -- so a typo'd default sits
    # dormant through an entire boot until something reads it (pinned in the spec).
    module Types
      # Raised by every type in this file for every refused input -- both types wrap what they
      # would otherwise let escape, so `Declarative#settle!` (or any other caller) can rescue ONE
      # class rather than needing to know either Ruby's assorted native conversion failures or
      # `Lain::Canonical`'s own error taxonomy. `StrictInteger` wraps `Integer()`'s `ArgumentError`
      # and `#truncate`'s `FloatDomainError`; `Canonicalized` wraps `Lain::Canonical::UnsupportedType`,
      # `AmbiguousKey`, and `NonFiniteFloat`. The first version of this file only wrapped
      # `StrictInteger` and stated the "one rescuable class" guarantee anyway -- a review caught
      # that `Canonicalized` still let its own three error classes escape raw, which is the same
      # defect this class exists to close, just relocated to the other type.
      #
      # Subclasses `Lain::Error`, not `ArgumentError`: this is the project-wide boundary, decided
      # for both `Declarative` cards together (quoted from the ruling, because both cards need the
      # same policy) --
      #
      #   "A malformed VALUE is a user-facing failure. Somebody typed or configured a bad number.
      #   It should be a Lain::Error, so the exe turns it into a clean one-line message... A
      #   malformed DECLARATION is a programmer error. An undeclared attribute, or an attribute
      #   holding something unsettleable, is a bug in lib code and deserves a full backtrace with
      #   file and line -- so it must stay outside Lain::Error's reach."
      #
      # A bad value coerced by one of these types is squarely the first case: `exe/lain`'s command
      # bodies rescue `Lain::Error` (see `render`/`exit_status` in `lib/lain/cli/command.rb`) to
      # turn it into `Thor::Error` rather than a raw backtrace, exactly as `project.rb:18` already
      # does for its own user-facing failures. `ArgumentError`
      # is not in that rescue's reach, so a `CoercionError < ArgumentError` would have bypassed it.
      class CoercionError < Lain::Error; end

      # `Integer(value, 10)` for strings, matching the two existing call sites this file
      # generalizes (`lib/lain/core/transport/vsock.rb`'s `#decimal`,
      # `lib/lain/review/source/local_branch.rb`'s `#count`): a bare `Integer(value)` reads a
      # leading-zero string as OCTAL when no base is given -- measured, `Integer("010")` is `8`,
      # not `10`, and silently. A zero-padded port, exit code, or ID out of JSON, config, or argv
      # would be silently reinterpreted; explicit base 10 is what those two call sites already do
      # to avoid exactly that.
      #
      # Non-integral Numerics (`Float`, `BigDecimal`, `Rational`) are refused rather than
      # truncated, for the same reason: `Integer(3.7)` silently returning `3` is the same defect
      # class as `"3x"` silently returning `3`, just on a different input shape. An exact integral
      # value (`3.0`, `BigDecimal("3.0")`, `Rational(6, 2)`) still converts -- nothing is lost
      # there, only fractional information would be.
      #
      # Every other shape (`nil`, booleans, `Symbol`, `Array`, `Hash`, an arbitrary object, even
      # one that happens to respond to `#to_i`) is refused too: `Integer()`'s fallback to
      # `#to_i` on a duck-typed object is exactly the kind of implicit, uncontrolled coercion this
      # type exists to close off, not a convenience worth keeping.
      class StrictInteger < ActiveModel::Type::Value
        def type = :lain_strict_integer

        def cast(value)
          case value
          when ::Integer then value
          when ::String then parse_decimal(value)
          when ::Float, ::BigDecimal, ::Rational then integral(value)
          else raise CoercionError, "cannot coerce #{value.class} into an integer: #{value.inspect}"
          end
        end

        private

        # `rescue` is scoped to this one call, not the whole method (an earlier version wrapped
        # the entire `case`, which let its OWN `else` branch's `CoercionError` -- itself an
        # `ArgumentError` at the time -- get re-caught and re-raised by this same clause, a
        # self-inflicted extra frame that never changed what escaped but was pure backtrace
        # noise). Narrowing to the actual conversion call is what makes the flow read as written:
        # only a REAL `Integer()` failure reaches this rescue.
        def parse_decimal(value)
          Integer(value, 10)
        rescue ::ArgumentError => e
          raise CoercionError, e.message
        end

        # Same narrowing as `#parse_decimal`, and for the same reason: `#truncate` is the only
        # call here that can raise natively (`FloatDomainError`, for NaN/Infinity on both `Float`
        # and `BigDecimal`); the explicit `raise CoercionError` for a merely-fractional value is
        # this method's own, not something `#truncate` produced, so it stays outside the rescue.
        def integral(value)
          truncated = truncate(value)
          raise CoercionError, "not an integral value: #{value.inspect}" unless value == truncated

          truncated
        end

        def truncate(value)
          value.truncate
        rescue ::FloatDomainError => e
          raise CoercionError, e.message
        end
      end

      # `Lain::Canonical.normalize` appears in 14 constructor bodies as the codebase's central
      # determinism invariant (deterministic bytes serving turn hashing and prompt-cache
      # stability) -- declaring it once as a type beats re-asserting it at each call site.
      #
      # Named `Canonicalized`, not `Canonical`: a class named `Canonical` nested under `Lain`
      # would SHADOW the top-level `Lain::Canonical` it depends on for any bare reference written
      # lexically inside it (CLAUDE.md's known-traps list). Root-qualifying every reference is
      # the documented mitigation, but a name that never collides in the first place removes the
      # hazard rather than requiring a reader to notice and preserve the qualification.
      #
      # The `::Lain::Canonical` reference lives in `#cast`'s body, not this class's, because
      # `lib/lain.rb` loads `canonical.rb` at `:22`, after where this subtree sits (`declarative`
      # inherits `guard`'s required position ahead of `config`, per `lain.rb:14-16`). A class-body
      # reference would resolve at THIS file's load time, before `Lain::Canonical` exists -- a
      # load-time `NameError`. A method body defers the lookup to call time, by which point
      # `lib/lain.rb` has finished requiring everything (verified by loading this file in a bare
      # process with no `Lain::Canonical` defined: it loads cleanly, and only `#cast` -- not
      # load -- raises `NameError` until `Lain::Canonical` is defined).
      #
      # `Canonical.normalize` raises its own taxonomy for input it cannot canonicalize
      # (`UnsupportedType`, `AmbiguousKey`, `NonFiniteFloat` -- all already `Lain::Error`
      # subclasses, so no boundary violation, only a different rescuable class). Wrapped into
      # `CoercionError` here anyway, so a caller of THIS type gets the same one class
      # `StrictInteger` gives it, rather than needing to know Canonical's taxonomy too. The
      # specific subtype is not preserved past the message text; nothing downstream of a
      # `Declarative` attribute has needed to distinguish "unsupported type" from "ambiguous key"
      # from "non-finite float" -- only that the value was refused.
      class Canonicalized < ActiveModel::Type::Value
        def type = :lain_canonical

        def cast(value)
          ::Lain::Canonical.normalize(value)
        rescue ::Lain::Error => e
          raise CoercionError, e.message
        end
      end
    end
  end
end

# Prefixed (`lain_...`), not the bare `:canonical`/`:strict_integer` this file used before this
# fix round: `ActiveModel::Type`'s registry is process-wide and last-write-wins with no error, so
# a generic symbol can be silently taken over by another gem registering the same name.
ActiveModel::Type.register(:lain_strict_integer, Lain::Declarative::Types::StrictInteger)
ActiveModel::Type.register(:lain_canonical, Lain::Declarative::Types::Canonicalized)
