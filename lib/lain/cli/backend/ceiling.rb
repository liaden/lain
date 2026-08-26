# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # A per-turn token ceiling read off ONE flag, validated, and refused in
      # that flag's own name.
      #
      # `--max-tokens` and `--summarizer-max-tokens` both ask this, and the
      # chat's went unvalidated: a nil reached {Lain::Context}'s
      # `Integer(max_tokens)` as a **TypeError**, which is not a {Lain::Error},
      # so the exe's `rescue Lain::Error` could not map it and an operator who
      # merely omitted a flag got a backtrace naming an internal collaborator.
      #
      # The flag is a FIELD because the two are different mistakes to make and a
      # refusal naming neither sends the operator to the wrong one. `#tokens`
      # rather than `#to_i`, because a conversion named `to_i` that raises is a
      # trap.
      Ceiling = Data.define(:flag, :value) do
        # @return [Integer] the validated ceiling
        # @raise [InvalidCeiling] when the flag is unset, or resolves to zero or
        #   less -- `0` is TRUTHY, so nothing downstream falls back and the
        #   provider simply 400s
        # @raise [ArgumentError] on an unparseable value: a non-numeric ceiling
        #   is a programmer or parser bug, not an operator's flag mistake
        def tokens
          raise InvalidCeiling, "#{flag} is not set; every model turn needs a token ceiling" if value.nil?

          Integer(value).tap do |ceiling|
            raise InvalidCeiling, "#{flag} must be positive, got #{ceiling}" unless ceiling.positive?
          end
        end
      end
    end
  end
end
