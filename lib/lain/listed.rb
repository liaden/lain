# frozen_string_literal: true

module Lain
  # A comma-separated flag or variable read as a list. One definition so a
  # stray comma drops the same way at every site rather than becoming an
  # empty name some callers refuse and others carry.
  module Listed
    module_function

    # @param raw [#to_s, nil] the list as typed
    # @return [Array<String>] stripped entries, empties dropped, frozen
    def comma(raw) = raw.to_s.split(",").map(&:strip).compact_blank.freeze
  end
end
