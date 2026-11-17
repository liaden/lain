# frozen_string_literal: true

module Lain
  module Review
    class Queue
      Mark = Data.define(:id, :head_sha)

      # The row a queued review marks seen once the human presses Enter at its
      # offer, named beside the request on the socket and in a held file. Any
      # same-uid process can write either, so it is checked as a request is,
      # naming the field that failed and never its value.
      class Mark
        FIELDS = %w[id head_sha].freeze
        SHA = /\A[0-9a-f]{40}\z/
        ID_LIMIT = 8192
        SEEN_FAILED = "lain queue: the review could not be marked seen: %<reason>s"
        private_constant :FIELDS, :SHA, :ID_LIMIT, :SEEN_FAILED

        # @param row [#id, #head_sha]
        # @return [Mark]
        def self.of(row) = new(id: row.id, head_sha: row.head_sha)

        # @param hash [Object] whatever arrived as the row
        # @return [Mark]
        # @raise [Request::Refused] naming the first field that is not of its shape
        def self.load(hash)
          refuse!("row", "is missing") if hash.nil?
          refuse!("row", "is not a map") unless hash.is_a?(Hash)
          refuse!("row", "has a field other than #{FIELDS.join(" and ")}") unless (hash.keys - FIELDS).empty?
          FIELDS.each { |field| refuse!("row.#{field}", "is missing") unless hash.key?(field) }
          new(id: checked_id(hash["id"]), head_sha: checked_sha(hash["head_sha"]))
        end

        def self.checked_id(value)
          id = text(value)
          refuse!("row.id", "is not of its shape") unless id&.bytesize&.between?(1, ID_LIMIT) && !id.include?("\0")
          id
        end

        def self.checked_sha(value)
          sha = text(value)
          refuse!("row.head_sha", "is not of its shape") unless sha && SHA.match?(sha)
          sha
        end

        def self.text(value)
          return unless value.is_a?(String)

          utf8 = String.new(value).force_encoding(Encoding::UTF_8)
          utf8.freeze if utf8.valid_encoding?
        end

        def self.refuse!(field, why) = raise(Request::Refused.new(field, why))
        private_class_method :checked_id, :checked_sha, :text, :refuse!

        # @return [Hash{String => String}] the wire and file form
        def to_h = { "id" => id, "head_sha" => head_sha }

        # @param log [Log]
        # @param notice [#call] told why, when the log cannot be written
        # @return [void]
        def seen(log, notice:)
          log.append(Log::Event.new(kind: :opened, at: nil, row_id: id, head_sha:))
        rescue IOError, SystemCallError => e
          notice.call(format(SEEN_FAILED, reason: Utf8.escaped(e.message)))
        end
      end
    end
  end
end
