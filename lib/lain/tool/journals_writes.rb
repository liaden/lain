# frozen_string_literal: true

module Lain
  class Tool
    # What a tool that writes a named file shares: the `journal:` keyword, a
    # write that hands back the identity of the file it wrote, and the
    # {Telemetry::FileWritten} line itself.
    module JournalsWrites
      # @param journal [#<<] where each write's {Telemetry::FileWritten} lands.
      #   Null by default, so a tool built with no session around it writes
      #   nowhere and no caller guards on nil.
      def initialize(journal: Channel::Null.instance)
        super()
        @journal = journal
      end

      private

      # Writes `content` to `path`, yields for the caller's bookkeeping, then
      # journals. The stat is taken through the descriptor that wrote, so the
      # identity is the file these bytes went into even if the path is swapped
      # before a re-stat.
      #
      # @param path [String] the absolute path to write
      # @param content [String]
      # @param invocation [Tool::Invocation, nil] the call, for its tool_use_id
      # @yieldreturn [Tool::Result] what the tool reports
      # @return [Tool::Result] the block's result
      def journalled_write(path, content, invocation)
        resolved, stat = File.open(path, "w") do |file|
          file.write(content)
          file.flush
          [File.realpath(path), file.stat]
        end
        yield.tap { journal_write(resolved, stat, invocation) }
      end

      # The bytes have landed by now, so a journal that cannot take the record
      # must not turn the write into a reported failure.
      def journal_write(resolved, stat, invocation)
        @journal << Telemetry::FileWritten.from_stat(stat, path: resolved, tool_use_id: invocation&.tool_use_id)
      rescue SystemCallError, IOError, Journal::Closed
        nil
      end
    end
  end
end
