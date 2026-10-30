# frozen_string_literal: true

require "fileutils"
require "socket"
require "time"

module Lain
  module Chores
    # The chore file read and rewritten in place. Every write holds the lock,
    # re-reads the file first, and lands by rename, so a human's concurrent
    # edit is never overwritten and a crash never leaves half a file.
    class Queue
      # The item is no longer there to take: another drain claimed it, or a human removed the line.
      class Taken < Error
        def initialize(item) = super("the chore #{item.text.inspect} is taken, or its line is gone")
      end

      # The file holds bytes that are not text.
      class Unreadable < Error
        def initialize(path) = super("#{path} is not valid UTF-8, so its chores cannot be read")
      end

      # @param root [String] the project root the chore file sits in
      # @param file [String] a bare file name
      # @param liveness [Liveness::Probe] judges whether a claim's process still runs
      # @param paths [Paths] where the default lock lives
      # @param lock [FileLock] one per project, so 2 drains of it never interleave a write
      # @return [Queue]
      def self.at(root, file: Config::Todos::DEFAULT, liveness: Liveness::Probe.new, paths: Paths.new,
                  lock: lock_for(root, paths))
        new(File.join(root, file), liveness:, lock:)
      end

      def self.lock_for(root, paths)
        dir = ProjectDir.new(root:, paths:).container("chores")
        begin
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          raise Paths::Unwritable.new(dir, e)
        end
        FileLock.new(File.join(dir, "queue.lock"), label: "the chore file")
      end
      private_class_method :lock_for

      def initialize(path, liveness:, lock:)
        @path = path
        @liveness = liveness
        @lock = lock
      end

      # @return [Array<Item>] unclaimed or abandoned items, in file order; an abandoned one reads :abandoned
      def open = items.select { |item| takeable?(item) }

      # @return [Array<Item>] every checkbox line in file order, whatever its state
      def items = read.filter_map { |_, item| judged(item) }

      # @return [Item] the item as claimed by this process
      # @raise [Taken] when the item is not open or abandoned in the file as it now stands
      def claim(item)
        rewrite(item, method(:takeable?)) do |found|
          found.with(state: :claimed, claim: mine).then do |claimed|
            [claimed, claimed.line]
          end
        end
      end

      # @param item [Item] the item this process claimed
      # @param outcome [Symbol] :done or :failed
      # @param note [String] the session path, landed sha or failure, kept in the line's comment
      # @raise [Taken] when the item is no longer claimed in the file
      def finish(item, outcome:, note:)
        rewrite(item, method(:live?)) do |found|
          finished = found.with(state: outcome, claim: nil)
          [finished, finished.line(note: comment_safe(note))]
        end
      end

      # @param text [String] the chore, already one line
      # @return [String] the open line added at the end of the file
      # @raise [Lain::Error] for text holding `<!--`, which would read back as the line's note
      def append(text)
        raise Error, "a chore cannot contain <!--, which the file reads as a note" if text.include?("<!--")

        line = Item.new(id: nil, text:, tag: nil, state: :open, claim: nil).line
        @lock.hold do
          existing = File.exist?(@path) ? File.binread(@path) : ""
          eol = existing[/\r?\n/] || "\n"
          lead = existing.empty? || existing.end_with?("\n") ? "" : eol
          land("#{existing}#{lead}#{line}#{eol}".b)
          line
        end
      end

      private

      def read
        return [] unless File.exist?(@path)

        seen = Hash.new(0)
        File.readlines(@path, encoding: "UTF-8").map do |line|
          raise Unreadable, @path unless line.valid_encoding?

          [line, numbered(line, seen)]
        end
      end

      def numbered(line, seen)
        Item.parse(line)&.then do |found|
          ordinal = (seen[found.text] += 1) - 1
          ordinal.zero? ? found : Item.parse(line, ordinal:)
        end
      end

      def judged(item)
        item && (item.state == :claimed && abandoned?(item) ? item.with(state: :abandoned) : item)
      end

      def abandoned?(item) = item.claim && item.claim.writer.verdict(@liveness) == :dead

      def live?(item) = item.state == :claimed

      def takeable?(item) = %i[open abandoned].include?(item.state)

      def mine
        Claim.new(pid: Process.pid, start: @liveness.start_of(Process.pid), host: Socket.gethostname,
                  since: Time.now.utc.iso8601)
      end

      def comment_safe(note) = note.to_s.gsub(/\s+/, " ").gsub("-->", "- >")

      def rewrite(item, takeable)
        @lock.hold do
          lines = read
          index = lines.index { |_, found| found && found.id == item.id && takeable.call(judged(found)) }
          raise Taken, item unless index

          result, text = yield judged(lines[index].last)
          land(lines.each_with_index.map { |(line, _), at| at == index ? text + line[/\r?\n\z/].to_s : line }.join)
          result
        end
      end

      # The link's target is replaced, so a symlinked chore file stays a link.
      def land(bytes)
        return AtomicFile.write(@path, bytes) unless File.exist?(@path)

        target = File.realpath(@path)
        AtomicFile.write(target, bytes, mode: File.stat(target).mode & 0o777)
      end
    end
  end
end
