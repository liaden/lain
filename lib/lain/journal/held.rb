# frozen_string_literal: true

require "monitor"

module Lain
  class Journal
    # Records written before the session header exists, kept until it does. A reader takes a
    # session file's first record as its header, so nothing may land ahead of it; once released,
    # a record goes straight through.
    class Held
      def initialize
        @monitor = Monitor.new
        @records = []
        @journal = nil
      end

      # @param record [Hash, #to_journal]
      # @return [self]
      def <<(record)
        @monitor.synchronize { @journal ? @journal << record : @records << record }
        self
      end

      # @param journal [#<<] where every kept record goes, and every later one
      # @return [self]
      def release(journal)
        @monitor.synchronize do
          @journal = journal
          @records.each { journal << _1 }
          @records = []
        end
        self
      end
    end
  end
end
