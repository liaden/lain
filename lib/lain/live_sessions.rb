# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Lain
  # The chats running now, one small file each under the state home, so another
  # process can find a chat's input socket and journal. A reader trusts only a
  # record whose writer {Liveness::Probe} still calls live, and never deletes one:
  # a crashed chat's file is skipped, not reaped, because the daemon's session
  # registry replaces this class and a second cleanup path would outlive it.
  class LiveSessions
    include Enumerable

    DIRECTORY = "live"

    # What {#enter} returns: the one way to take the record back out.
    class Handle
      # @param path [String] the record file
      def initialize(path) = @path = path

      # @return [void]
      def leave = FileUtils.rm_f(@path)
    end

    # @param paths [Paths] names the state home
    # @param probe [Liveness::Probe] answers whether a record's writer still runs
    def initialize(paths:, probe: Liveness::Probe.new)
      @paths = paths
      @probe = probe
    end

    # @param record [Record]
    # @return [Handle]
    def enter(record)
      path = File.join(directory, "#{record.session_id}.json")
      FileUtils.mkdir_p(directory)
      scratch = "#{path}.#{SecureRandom.hex(4)}.tmp"
      File.write(scratch, JSON.generate(record.to_h), perm: 0o600)
      File.rename(scratch, path)
      Handle.new(path)
    end

    # @yieldparam record [Record] a record whose writer is live, newest started_at first
    def each(&block)
      return enum_for(:each) unless block_given?

      records.select { |record| record.writer.verdict(@probe) == :live }.sort_by(&:started_at).reverse.each(&block)
    end

    # @param root [String] a checkout root
    # @return [Array<Record>] the attended live records for it
    def in(root) = select { |record| record.attended && record.root == root }

    private

    def directory = File.join(@paths.state_home, DIRECTORY)

    def records
      Dir.glob(File.join(directory, "*.json")).filter_map { |file| parse(file) }
    end

    def parse(file)
      Record.from_h(JSON.parse(File.read(file)))
    rescue JSON::ParserError, KeyError, SystemCallError, TypeError
      nil
    end
  end
end
