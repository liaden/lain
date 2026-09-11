# frozen_string_literal: true

module Lain
  # The characters an identifier reserves for the markdown grammar that
  # renders it on one line: the backtick that delimits it and the line break
  # that would otherwise let it escape its heading. Epic::Issue, Plan::Step,
  # and Question each mint ids under that same shape and once disagreed about
  # it -- Plan::Step's own refusal named no offending character at all. One
  # rule, reused, is what keeps that from drifting back apart.
  #
  # Each caller still owns which of ITS OWN fields the rule applies to, and
  # which grammar names CR/LF (a heading is a different sentence in an issue,
  # a step, and a question). Only the reserved-character set and the backtick
  # grammar's own phrasing are shared outright: {Question}'s spec pins that a
  # backtick refuses identically wherever an id is minted, and {BACKTICK_GRAMMAR}
  # is what makes that true by construction rather than by three call sites
  # happening to agree. Question extends the reserved set with the zero-width
  # characters that make an id invisible once rendered -- its own hazard, not
  # a shared one.
  module MarkdownIdentifier
    RESERVED = /[`\r\n]/

    BACKTICK_GRAMMAR = "the `id` backtick delimiters"

    module_function

    # Raise `error` naming `field`, the value, the offending character, and
    # which grammar (from `grammars`) reserves it -- or hand `id` back
    # unchanged when it holds none of `reserved`.
    #
    # `grammars` is `fetch`ed on purpose, as the callers that used to do this
    # inline did: growing `reserved` without saying which grammar the new
    # character belongs to fails loudly here instead of mislabelling it.
    #
    # @param id [String]
    # @param field [String] names what is being checked, for the message
    # @param grammars [Hash{String => String}] offending character -> the grammar reserving it
    # @param error [Class] exception class to raise
    # @param reserved [Regexp] the character class to check against
    # @return [String] id, unchanged
    # @raise [StandardError] an instance of the given error class, when id holds a reserved character
    def check!(id, field, grammars:, error:, reserved: RESERVED)
      offender = id[reserved]
      return id if offender.nil?

      raise error, "#{field} #{id.inspect} contains #{offender.inspect}, a character reserved for " \
                   "#{grammars.fetch(offender)}"
    end
  end
end
