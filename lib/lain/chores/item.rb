# frozen_string_literal: true

module Lain
  module Chores
    Item = Data.define(:id, :text, :tag, :state, :claim)

    # A claim is the holder's identity as {Liveness::Writer} records it, plus when it was taken.
    Claim = Data.define(:pid, :start, :host, :since) do
      def writer = Liveness::Writer.new(pid:, start:, host:)

      def comment = "lain pid=#{pid} start=#{start} host=#{host} since=#{since}"
    end

    # One checkbox line of the chore file. The id hashes the text and its ordinal
    # alone, so a claim, a finish or a tag change never moves it. The grammar: a
    # mark (open, claimed, done, failed), an optional tag, a trailing comment.
    class Item
      MARKS = { " " => :open, "~" => :claimed, "x" => :done, "X" => :done, "!" => :failed }.freeze
      MARK = { open: " ", claimed: "~", done: "x", failed: "!" }.freeze
      LINE = /\A[-*] \[(?<mark>[ ~xX!])\] (?:\[(?<tag>[\w-]+)\] )?(?<text>.*?)(?:\s*<!--\s*(?<note>.*?)\s*-->)?\s*\z/
      CLAIM_NOTE = /\Alain pid=\d+ start=\S+ host=\S+ since=\S+\z/
      CLAIM = /\Alain pid=(?<pid>\d+) start=(?<start>#{Liveness::START_TOKEN}) host=(?<host>\S+) since=(?<since>\S+)\z/

      # @param line [String] one line of the file
      # @param ordinal [Integer] how many identical texts precede this one, which keeps their ids apart
      # @return [Item, nil] nil for a line that is not a checkbox
      def self.parse(line, ordinal: 0)
        match = LINE.match(line.chomp)
        return unless match

        text = match[:text]
        claim = claim_in(match[:note])
        state = state_of(MARKS.fetch(match[:mark]), claim, match[:note])
        new(id: id_of(text, ordinal), text:, tag: match[:tag], state:, claim:)
      end

      # A lain note naming no readable claim is one nobody can still hold; a line with no lain note is a human's.
      def self.state_of(state, claim, note)
        state == :claimed && claim.nil? && CLAIM_NOTE.match?(note.to_s) ? :abandoned : state
      end

      def self.id_of(text, ordinal)
        Canonical.digest(ordinal.zero? ? text : [text, ordinal]).delete_prefix("#{Canonical::DIGEST_ALGORITHM}:")[0, 12]
      end

      def self.claim_in(note)
        found = CLAIM.match(note.to_s)
        found && Claim.new(pid: Integer(found[:pid]), start: found[:start], host: found[:host], since: found[:since])
      end
      private_class_method :id_of, :claim_in, :state_of

      # @param note [String, nil] the comment to carry; a claimed item's own claim when not given
      # @return [String] the line this item reads as in the file
      def line(note: claim&.comment)
        ["- [#{MARK.fetch(state)}]", ("[#{tag}]" if tag), text].compact.join(" ") + (note ? "  <!-- #{note} -->" : "")
      end
    end
  end
end
