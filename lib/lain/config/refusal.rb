# frozen_string_literal: true

module Lain
  class Config
    # Every refusal of a `.lain/config.rb` table, for all seven of them:
    # `[epics]`, `[epics.gates]`, `[approval]`, `[isolation]`, `[sensitivity]`,
    # `[shell]` and `[tests]`. One class because there is one concept -- this
    # file says something the reader will not act on -- where the seven readers
    # had each invented a family of it, four of them carrying a prose comment
    # saying they were copying a sibling's posture.
    #
    # That posture, stated once: the file, then the table, then what is wrong.
    # Each of the first two is omitted when there is nothing to say. **No path
    # means no file to open** -- a value built in memory came from a caller, not
    # from a config, and naming a file would send its reader somewhere the
    # mistake is not. **No table** is the rarer case, for the one detail naming
    # a Ruby reader (`epics_home`) rather than a table. And `path` carries the
    # line where {Builder} knows it, because the message exists to send a human
    # to a line of the file.
    #
    # A file Ruby cannot run is one of these too, at the line Ruby names: the
    # user wrote the file, so a backtrace into lain would point nowhere they
    # can edit.
    class Refusal < Error
      # @return [String, nil] the config file, or file:line; absent for a value built by hand
      attr_reader :path
      # @return [String, nil] the verb that declares the table, e.g. "`shell`"
      attr_reader :table
      # @return [String, Array<String>, nil] the key, or every key, the refusal
      #   names -- a list wherever one pass can report several
      attr_reader :key
      # @return [Object, nil] what was refused, as the parser handed it over
      attr_reader :value

      # `shell = "off"` -- a scalar where the table belongs. All SEVEN readers
      # needed this, for one reason: `.keys` on a String is an unnamed
      # NoMethodError three frames from the file that caused it.
      #
      # @param value [Object] whatever the parser handed back in the table's place
      # @param path [String, nil] the config file to name
      # @param table [String] the table to name
      # @return [Refusal]
      def self.not_a_table(value, path:, table:)
        new("must be a table, got #{value.class}: #{value.inspect}", path:, table:, value:)
      end

      # A typo inside a table. Loud rather than dropped, for all SIX readers
      # that raise it: a silently ignored key reads as a setting that is in
      # force and is not. Plural, so two typos cost one run rather than two.
      #
      # @param keys [Array<String>] every key the table has that it should not
      # @param known [Array<String>] the correction offered back
      # @param path [String, nil] the config file to name
      # @param table [String] the table to name
      # @return [Refusal]
      def self.unknown_keys(keys, known:, path:, table:)
        new("has no keys #{keys.map(&:inspect).join(", ")}; known keys: #{known.join(", ")}",
            path:, table:, key: keys)
      end

      # @param detail [String] what is wrong, reading on from the table
      # @param path [String, nil] the config file to name
      # @param table [String, nil] the table to name
      # @param key [String, Array<String>, nil] the key(s) refused
      # @param value [Object, nil] the value refused
      def initialize(detail, path: nil, table: nil, key: nil, value: nil)
        @path = path
        @table = table
        @key = key
        @value = value
        super([path && "#{path}:", table, detail].compact.join(" "))
      end
    end
  end
end
