# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      # Which tool_use block each record about a call belongs to. An id alone does not say: a
      # provider that mints its own ids (Ollama's `ollama-tool-<index>`) repeats them in every turn
      # and every child's turn. So a record is placed by what it carries -- the digest of the input
      # it ruled on, and whether a child asked -- and a record carrying neither goes with its nearest
      # placed neighbour under the same id. An id where any record fits no block, or more than one,
      # is ambiguous: kept whole and reported, never split by guesswork and never dropped.
      class Join
        # A tool_use block, and whether a child's turn carried it.
        Block = Data.define(:block, :child)

        # One call's share of the records: its block (nil when none was written), its records in
        # journal order, and whether the id could not be split.
        Share = Data.define(:id, :block, :records, :ambiguous)

        # @param records [Array<Hash>] one session file's, in journal order
        def initialize(records)
          @records = records
          @blocks = blocks
        end

        # @return [Array<Share>] one per gated call, in the order each was first ruled
        def shares
          @records.select { _1["tool_use_id"] }.group_by { _1["tool_use_id"] }
                  .select { |_, said| said.any? { Call::GATED.include?(_1["type"]) } }
                  .flat_map { |id, said| split(id, said) }
        end

        private

        def split(id, said)
          found = @blocks.fetch(id, [])
          return [Share.new(id:, block: found.first, records: said, ambiguous: false)] if found.size < 2

          owners = owners(said, found)
          return [Share.new(id:, block: nil, records: said, ambiguous: true)] unless owners.all?(Block)

          said.zip(owners).group_by(&:last).filter_map do |block, pairs|
            mine = pairs.map(&:first)
            Share.new(id:, block:, records: mine, ambiguous: false) if mine.any? { Call::GATED.include?(_1["type"]) }
          end
        end

        # Each record's block: by what it carries, else its nearest placed neighbour's.
        def owners(said, found)
          fitted = said.map { fit(_1, found) }
          fitted.each_index.map do |at|
            fitted[at] || fitted[...at].reverse.find { _1.is_a?(Block) } || fitted[(at + 1)..].find { _1.is_a?(Block) }
          end
        end

        # @return [Block, nil, Symbol] the one block it fits, nil when it carries nothing to fit by,
        #   or :unplaced when it fits none or several
        def fit(record, found)
          digest = record["input_digest"]
          requester = record["requester"]
          return nil if digest.nil? && requester.nil?

          fits = found.select do |candidate|
            (digest.nil? || Effect.input_digest(candidate.block["input"]) == digest) &&
              (requester.nil? || candidate.child == (requester != Call::MAIN))
          end
          fits.one? ? fits.first : :unplaced
        end

        def blocks
          @records.each_with_object(Hash.new { |all, id| all[id] = [] }) do |record, found|
            content, child = carried(record)
            Array(content).select { _1.is_a?(Hash) && _1["type"] == "tool_use" }
                          .each { found[_1["id"]] << Block.new(block: _1, child:) }
          end
        end

        def carried(record)
          case record["type"]
          when SessionRecord::TURN_TYPE then [record["content"], false]
          when SessionRecord::CHILD_TURN_TYPE then [record.dig("payload", "content"), true]
          end
        end
      end
    end
  end
end
