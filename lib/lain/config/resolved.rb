# frozen_string_literal: true

require "tomlrb"

module Lain
  class Config
    # One `.lain/config.toml`, parsed once.
    #
    # A `lain chat` startup asked the same file for six tables and
    # {Project::Resolver} asked it for a `root` before any of them, so seven
    # independent `Tomlrb.load_file` calls read the same bytes. This is the
    # shared read; every one of those callers comes through it now.
    #
    # == It shares the PARSE, never the interpretation
    #
    # Every table is built on the reader that asks for it, and none at
    # construction. That is what keeps the granting/restricting posture
    # {Config.load} argues for intact: asking for `[tests]` never touches
    # `[isolation]`, so a typo in a table nobody asked about cannot surface at a
    # caller reading a different one. Validating all six eagerly would push
    # every table's refusal through every reader's rescue, and
    # {CLI::Wiring::BoardBuild}'s three degrade paths would each start
    # swallowing the other two's failures.
    #
    # == What invalidates it: an edit to the file, and nothing else
    #
    # The key is the file's identity as the filesystem reports it -- inode,
    # size, mtime at nanosecond resolution -- restatted on every ask, so an
    # edit is picked up by the next reader. `lain chat` lives for hours rather
    # than one shot, and a memo that never invalidated would go on serving an
    # operator the `[sensitivity]` rules they had already widened, silently.
    # Seconds alone would be the wrong key: bootsnap's `(mtime-seconds, size)`
    # collides on a same-size rewrite inside one second, which is what an editor
    # macro does. Nothing is evicted -- the paths one process reads are bounded
    # by the roots it resolves.
    class Resolved
      # Class-level rather than constants, so neither the table nor the lock is
      # reachable from outside. The cop asks for thread safety and cannot see
      # that the mutex below is how this gets it; its correction, freezing the
      # table, would make the memo unwritable rather than safe.
      @cache = {} # rubocop:disable ThreadSafety/MutableClassInstanceVariable
      @lock = Mutex.new

      class << self
        # @param path [String] a `.lain/config.toml`, which need not exist
        # @return [Resolved] the parse of that file as it stands right now
        def for(path)
          stamp = stamp_of(path)
          @lock.synchronize do
            current = @cache[path]
            current&.fresh?(stamp) ? current : (@cache[path] = new(path, stamp))
          end
        end

        private

        # `nil` for a file that is not there, which is the ordinary case and
        # not an error -- and for one whose stat fails for any other reason,
        # which is what `File.exist?` answered at the call sites this replaces.
        #
        # Frozen through, so a `freeze` in {#initialize} is a true statement
        # about the instance rather than one about its outermost object.
        #
        # @return [Array, nil] the file's identity, or nil when there is no file
        def stamp_of(path)
          stat = File.stat(path)
          [stat.ino, stat.size, stat.mtime.freeze].freeze
        rescue SystemCallError
          nil
        end
      end

      # @return [String] the file this is the parse of, frozen and deduplicated
      #   (`-`) so the instance's own `freeze` below holds all the way down
      attr_reader :path

      def initialize(path, stamp)
        @path = -path
        @stamp = stamp
        @table, @unreadable = stamp.nil? ? [nil, nil] : parse
        freeze
      end

      # @param stamp [Array, nil] the file's identity as it stands now
      # @return [Boolean] whether this parse is still of that file
      def fresh?(stamp) = @stamp == stamp

      # @return [Boolean] whether there is no file to read
      def missing? = @stamp.nil?

      # @return [Hash, nil] the whole file, nil when there is none
      # @raise [Malformed] when the file is there and could not be read as TOML
      def raw
        raise Malformed.new(path, @unreadable) if @unreadable

        @table
      end

      # @return [String, nil] the `root =` this file declares, if it declares one
      # @raise [Malformed] when the file is there and could not be read as TOML
      def declared_root = raw&.[]("root")

      # @return [Config] every field at its default when there is no file
      # @raise [Malformed] as {#raw}
      # @raise [Refusal] when `[epics]`, `[epics.gates]`, `[approval]` or
      #   `[isolation]` says something this reader will not act on
      def config
        return Config.empty if missing?

        Config.new(epics: Epics.from(raw["epics"], path:), approval: Answers.from(raw["approval"], path:),
                   isolation: Isolation.from(raw["isolation"], path:))
      end

      # @return [Sensitivity::Rules] empty when the file or the table is absent
      def sensitivity = missing? ? Sensitivity::Rules.empty : Sensitivity::Rules.from(raw["sensitivity"], path:)

      # @return [Shell::Exclusions] empty when the file or the table is absent
      def shell_exclusions = missing? ? Shell::Exclusions.empty : Shell::Exclusions.from(raw["shell"], path:)

      # `path:` is passed even with no file, as the reader this replaces did:
      # {TestLayout.from} names it only in a refusal, and with no file the only
      # refusal available comes from the `framework:` preset.
      #
      # @param framework [String, nil] a detected test framework
      # @return [TestLayout]
      def test_layout(framework: nil) = TestLayout.from(missing? ? nil : raw["tests"], path:, framework:)

      private

      # The FAILURE is remembered as well as the success, so a broken file is
      # parsed once too -- while {#raw} still raises a fresh {Malformed} on
      # every read, so the three degrade paths in {CLI::Wiring::BoardBuild} each
      # get their own exception to report, as they did when each re-parsed.
      #
      # It is the one thing here that is not deeply frozen: an Exception carries
      # a mutable backtrace, so `Ractor.shareable?` is true of every instance
      # EXCEPT one holding a parse failure. Nothing crosses a Ractor boundary
      # with a config in hand today; this says what the `freeze` does and does
      # not claim, so the next reader does not have to measure it.
      #
      # @return [Array(Hash, nil), Array(nil, Exception)]
      def parse
        [deeply_frozen(Tomlrb.load_file(path)), nil]
      rescue Tomlrb::ParseError, ArgumentError, SystemCallError => e
        [nil, e]
      end

      # Frozen through, because the hash is SHARED. A reader that mutated a
      # table it was handed would change what every later reader sees, and the
      # damage would surface somewhere else entirely.
      def deeply_frozen(value)
        case value
        when Hash then value.each_value { |member| deeply_frozen(member) }.freeze
        when Array then value.each { |member| deeply_frozen(member) }.freeze
        else value.freeze
        end
      end
    end
  end
end
