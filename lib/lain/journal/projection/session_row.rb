# frozen_string_literal: true

module Lain
  class Journal
    class Projection
      # What a sessions listing reads of one file: the header, the close, the first record's type, how
      # many records parsed, and the turns that moved the head. One fold answers all of them, so the
      # listing walks a file once.
      #
      # It steps the parsed lines as the Journal wrote them, not as {Telemetry.read} answers them,
      # because the header's `ts` is the stamp the typed reading strips.
      #
      # It declares no `combine`: a rewind and the turn that lands it can fall on either side of a cut.
      class SessionRow < Projection
        MOVES = [SessionRecord::TURN_TYPE, SessionRecord::REWOUND_TYPE].freeze
        NO_MOVES = [].freeze
        # The header carries the whole tool schema; a listing reads 3 fields of it, and freezing the
        # rest on every step is the cost.
        HEADER_KEYS = %w[ts format resumed_from].freeze
        KEPT = %w[type digest to then].freeze

        # @return [SessionRow]
        def self.unit = new({ header: nil, closed: nil, first_type: nil, size: 0, moves: NO_MOVES })

        # @param record [Hash{String=>Object}] one parsed line
        # @return [SessionRow]
        def step(record)
          type = record["type"]
          self.class.new(state.merge(size: size + 1,
                                     first_type: size.zero? ? type : first_type,
                                     header: header || (if type == SessionRecord::HEADER_TYPE
                                                          record.slice(*HEADER_KEYS)
                                                        end),
                                     closed: closed || (record.slice("head") if type == "session_closed"),
                                     moves: MOVES.include?(type) ? [record.slice(*KEPT), moves].freeze : moves))
        end

        # @return [Hash{String=>Object}, nil] the file's first header record, cut to the fields a listing reads
        def header = state.fetch(:header)

        # @return [Hash{String=>Object}, nil] the file's first close record, cut to its head
        def closed = state.fetch(:closed)

        # @return [String, nil] the type of the first record that parsed
        def first_type = state.fetch(:first_type)

        # @return [Integer] how many records parsed
        def size = state.fetch(:size)

        # The digests left on the chain. A rewind to a turn this file never recorded goes below the head
        # it was resumed from, so none of this file's turns remain.
        #
        # @return [Array<String>]
        def chain = applied.each_with_object([]) { |record, digests| fold(digests, record) }

        # The last turn or rewind is the most recent head this file knows, and a rewind to nothing
        # leaves none; a file with neither falls back to its recorded anchors.
        #
        # @return [String, nil]
        def head
          return anchor if applied.empty?

          last = applied.last
          last["type"] == SessionRecord::TURN_TYPE ? last["digest"] : last["to"]
        end

        private

        # Newest first as nested pairs, so a step shares the whole earlier list instead of copying it.
        def moves = state.fetch(:moves)

        def applied = SessionRecord.applied(in_order)

        def in_order
          pairs = Enumerator.produce(moves, &:last).take_while { |pair| !pair.empty? }
          pairs.map(&:first).reverse
        end

        def fold(digests, record)
          return digests << record["digest"] if record["type"] == SessionRecord::TURN_TYPE

          digests.slice!(((digests.index(record["to"]) || -1) + 1)..)
        end

        def anchor = closed&.fetch("head", nil) || header&.dig("resumed_from", "head")
      end
    end
  end
end
