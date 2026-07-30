# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # A per-turn token ceiling read off ONE flag, validated, and refused in that
      # flag's own name.
      #
      # Two flags ask this question -- `--max-tokens` for the chat and bench tier,
      # `--summarizer-max-tokens` for the summarizer's -- and they answered it two
      # different wrong ways before this object. The summarizer's was validated
      # inline; the chat's was not validated at all, so a nil went straight into
      # {Lain::Context}'s `Integer(max_tokens)` and came back as a **TypeError**.
      # A TypeError is not a {Lain::Error}, so the exe's `rescue Lain::Error`
      # cannot map it and an operator who merely omitted a flag gets a backtrace
      # naming Context, an internal collaborator. That is the exact wound
      # {Backend::MissingAPIKey} and {Backend::InvalidCeiling} were each written
      # for, and this is the one place either flag can now go wrong.
      #
      # THE FLAG IS A FIELD, not an assumption. `--max-tokens` and
      # `--summarizer-max-tokens` are two different mistakes to make, and a
      # refusal naming neither sends the operator to the wrong one.
      #
      # `#tokens`, not `#to_i`: a conversion named `to_i` that raises is a trap,
      # and this one refuses three ways.
      Ceiling = Data.define(:flag, :value) do
        # @return [Integer] the validated ceiling
        # @raise [InvalidCeiling] when the flag is unset, or resolves to zero or
        #   less -- `0` is TRUTHY, so nothing downstream falls back for it and the
        #   provider simply 400s
        # @raise [ArgumentError] on an unparseable value, as `Integer()` always
        #   has for this flag: a non-numeric ceiling is a programmer or parser
        #   bug, not an operator's flag mistake
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
