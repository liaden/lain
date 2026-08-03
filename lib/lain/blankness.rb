# frozen_string_literal: true

module Lain
  # What "nothing at all" means, in one place, for every value a human or a
  # model writes and something downstream reads as an answer.
  #
  # `String#strip` was the first attempt everywhere and it is ASCII-ONLY. A
  # spike answering a single U+00A0 satisfied `strip != ""`, was
  # content-addressed, and let a bare APPROVE close a gate on an empty evidence
  # section (reproduced end-to-end at `approved=true parked=0` for U+00A0,
  # U+3000, U+2007, U+200B and U+FEFF alike). ActiveSupport's `Object#blank?` is
  # the obvious reach and is also wrong: its `/\A[[:space:]]*\z/` misses the
  # zero-width set below.
  #
  # POSIX `[[:space:]]` is Unicode-aware in Ruby and covers the space
  # separators. The zero-width set is NOT space to any locale and has to be
  # named: U+200B..U+200D, U+2060, U+FEFF.
  #
  # It loads near the top of the manifest -- the bottom of the dependency
  # order -- rather than beside its first caller
  # because it now has callers in two units that must not depend on each other:
  # {Approval::Gate::Adjudicator::GateEvidence} delegates down to it, and
  # {Question::Answer} asks it whether a human wrote a comment. A second
  # definition of "nothing" is exactly what the U+00A0 hole cost.
  module Blankness
    NOTHING_AT_ALL = /\A[[:space:]\u{200B}-\u{200D}\u{2060}\u{FEFF}]*\z/

    module_function

    # Undecodable bytes are replaced rather than raised on: text that came back
    # as mojibake carries nothing usable either, so it belongs on the blank arm
    # rather than in an exception.
    def blank?(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").match?(NOTHING_AT_ALL)
    end
  end
end
