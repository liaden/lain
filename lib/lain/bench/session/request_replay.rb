# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Rebuilds the recorded baseline from `request_sent` records. The
      # payload's keys are exactly {Request.new}'s content keywords, and each
      # rebuild must land on the record's own digest -- {Telemetry::RequestSent}
      # carries it precisely so a forged PAYLOAD cannot load clean and book as
      # harness variance downstream. The transport fields ride alongside
      # unverified: the digest deliberately excludes them, so tampering there is
      # invisible to this check.
      class RequestReplay
        def initialize(records:)
          @records = records
        end

        # @return [Array<Request>] frozen, root to head
        # @raise [Corrupt] on a record whose payload no longer re-derives to
        #   its recorded digest
        def baseline
          @records.each_with_index.map { |record, index| verified(record, index) }.freeze
        end

        private

        def verified(record, index)
          request = Request.new(stream: record.fetch("stream"), extra: record.fetch("extra"),
                                **record.fetch("payload").transform_keys(&:to_sym))
          recorded = record.fetch("digest")
          return request if request.digest == recorded

          raise Corrupt, "request_sent record #{index} recorded as #{recorded} rebuilds to #{request.digest}; " \
                         "its payload no longer matches its content address"
        end
      end
    end
  end
end
