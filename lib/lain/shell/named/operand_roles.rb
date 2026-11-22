# frozen_string_literal: true

module Lain
  module Shell
    class Named
      # What each operand of a program means, so a pattern, a script or a
      # filter is not named as a path. Every reader of {Named} decides which
      # files a call touches from what it names, so an operand left unnamed
      # here is one no secret check sees: a program is listed only where its
      # operands' roles are certain, and any option that could move its text
      # elsewhere puts every operand back to `:file`.
      module OperandRoles
        PATTERN = [:pattern].freeze
        SCRIPT = [:script].freeze

        # A role per leading operand, by index, or one Symbol for every operand.
        ROLES = {
          **%w[grep egrep fgrep zgrep rg].to_h { [_1, PATTERN] },
          **Programs::AWKS.to_h { [_1, SCRIPT] },
          "sed" => SCRIPT, "jq" => [:filter].freeze, "printf" => [:format].freeze, "echo" => :text
        }.freeze

        GREP = ["ef", %w[--regexp --file].freeze].freeze
        # The options that give the program its text, or, for jq, also take a
        # value Argv cannot separate, so the first operand may be a file. awk
        # needs none: any of its options that could is already opaque.
        DISPLACING = {
          **%w[grep egrep fgrep zgrep].to_h { [_1, GREP] },
          "rg" => ["ef", %w[--regexp --file --files].freeze].freeze,
          "ack" => ["f", %w[--files --match].freeze].freeze,
          "sed" => ["ef", %w[--expression --file].freeze].freeze,
          "jq" => ["fL", %w[
            --from-file --library-path --arg --argjson --slurpfile --rawfile --indent
          ].freeze].freeze
        }.freeze
        NONE = ["", [].freeze].freeze
        LONG_NAME = /\A--[^=]+/

        # @param program [String] the program's canonical name
        # @param count [Integer] how many operands it was given
        # @param displaced [Boolean] what {.displaced?} answers for its words
        # @return [Array<Symbol>] one role per operand; `:file` is named as a path
        def self.of(program, count, displaced: false)
          roles = displaced ? [] : ROLES.fetch(program, [])
          Array.new(count) { roles.is_a?(Symbol) ? roles : roles.fetch(_1, :file) }
        end

        # GNU getopt takes any unambiguous prefix of a long option, so a long
        # option counts when it starts one of the displacing names; an
        # ambiguous prefix the program's getopt would refuse then over-names,
        # the safe side.
        #
        # @param program [String] the program's canonical name
        # @param argv [Argv] the words after the program, as Program read them
        # @return [Boolean] an option carries the program's text, so every operand is a file
        def self.displaced?(program, argv)
          letters, longs = DISPLACING.fetch(program, NONE)
          argv.options.any? do |index|
            long = argv.words[index][LONG_NAME]
            long ? longs.any? { _1.start_with?(long) } : argv.cluster(index).count(letters).positive?
          end
        end
      end
    end
  end
end
