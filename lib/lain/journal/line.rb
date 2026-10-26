# frozen_string_literal: true

module Lain
  class Journal
    # What a line {Journal.parse} refused is, for the readers that must not skip
    # silently: one rule, so a torn tail means the same thing in every one of
    # them. Each reader keeps its own response to the answer. It also owns the
    # link a chained Journal ends each line with, so the writer and whatever
    # checks the chain cannot disagree about what a link covers.
    module Line
      ORIGIN = "origin"
      TIP = /\A(?:#{ORIGIN}|#{Canonical::DIGEST_ALGORITHM}:\h{64})\z/

      # @param line [String] one line as written, with or without its newline
      # @return [String] "blake3:<hex>" of the line's bytes without a trailing newline
      def self.link(line) = "#{Canonical::DIGEST_ALGORITHM}:#{Ext.blake3_hex(line.delete_suffix("\n"))}"

      # A torn tail counts as the last line: a chained reopen seals it with a newline.
      #
      # @param path [String] a journal file that exists
      # @return [String] the tip a new writer continues from: {ORIGIN} for an empty file, else
      #   {link} of the last line
      def self.tip(path)
        last = nil
        File.foreach(path, mode: "rb") { |line| last = line }
        last ? link(last) : ORIGIN
      end

      # @param path [String] a journal file that exists
      # @return [Boolean] whether its last byte is something other than a newline
      def self.torn?(path)
        File.open(path, "rb") { |file| file.size.positive? && file.pread(1, file.size - 1) != "\n" }
      end

      # @param value [String]
      # @return [Boolean] whether a chain can continue from it
      def self.tip?(value) = value.is_a?(String) && TIP.match?(value)

      # Splices the link in place as the line's last key, so `ts` and `type` keep leading it and a
      # megabyte line is not copied again.
      #
      # @param line [String] one encoded JSON object, mutable, without a newline
      # @param prev [String] the link to the line written before it
      # @return [String] the same String, now ending in `"prev":<prev>}`
      def self.splice!(line, prev)
        raise ArgumentError, "cannot splice a link into #{(line[-20..] || line).inspect}" unless line.end_with?("}")

        line.chop! << %(,"#{LINK}":"#{prev}"})
      end

      # An unterminated last line is judged before blank and foreign because a
      # crash between the bytes and the newline can leave any of them, and the
      # reader's tolerance for that is the same.
      #
      # @param line [Hash, String] one entry of the {Journal.records} duck
      # @param last [Boolean] whether it is the final line of the file
      # @return [Symbol] `:record`, `:tail` (last and unterminated), `:blank`,
      #   `:foreign` (JSON, but not a Hash record), or `:damage`
      def self.classify(line, last:)
        return :record if Journal.parse(line)
        return :foreign unless line.is_a?(String)
        return :tail if last && !line.end_with?("\n")
        return :blank if line.strip.empty?

        JSON.parse(line)
        :foreign
      rescue JSON::ParserError
        :damage
      end
    end
  end
end
