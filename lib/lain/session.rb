# frozen_string_literal: true

module Lain
  # Mutable state for ONE run, and deliberately not a value object.
  #
  # Everything else in the harness that the model sees is either content-
  # addressed and frozen (a {Lain::Turn} in the Timeline) or frozen and sent-
  # not-stored (a {Lain::Workspace}). Session is the exception on purpose: it is
  # the run's scratch memory -- which files have been read, and (later) the todo
  # list -- and it must accumulate as tools run. So it is never appended to the
  # Timeline, never enters a Turn's content, and stays reachable only from the
  # Agent and from the {Tool::Invocation#context} threaded to each tool. Keeping
  # it off the Timeline is what keeps `Ractor.shareable?(turn)` true: the mutable
  # state lives here, where nothing frozen reaches it.
  #
  # Two responsibilities today:
  #   * a read-set, so a future edit-before-read contract can ask "was this file
  #     read this session?" (see {Tool::Contracts});
  #   * a reminders channel, empty for now, that a later card fills with todos
  #     the Agent renders into the Workspace tail.
  class Session
    def initialize
      @reads = Set.new
    end

    # Record that `path` was read this session. Normalized so a later `read?`
    # cannot be defeated by a different spelling of the same file.
    #
    # @return [self]
    def record_read(path)
      @reads << normalize(path)
      self
    end

    # @return [Boolean] whether `path` (in any spelling) was read this session
    def read?(path)
      @reads.include?(normalize(path))
    end

    # State the Agent renders into the Workspace tail each turn. Empty until a
    # later card adds todos; the Agent composes it via `Workspace#with` so
    # Session never needs to know Workspace exists.
    #
    # @return [Array]
    def reminders
      [].freeze
    end

    private

    # Path identity is `File.expand_path`: "./app.rb" recorded and "app.rb"
    # queried (or the reverse) are the same file, so the read-set answers on the
    # file, not on the string the model happened to type.
    def normalize(path)
      File.expand_path(path.to_s)
    end

    # The no-op Session, mirroring {Channel::Null} and {Sink::Null}: it satisfies
    # the same duck so a tool handed a context can always `record_read`/`read?`
    # without an `if session` guard. Records nothing, reads back false, offers no
    # reminders. A single shared frozen instance -- it has no state to keep.
    class Null
      # @return [self]
      def record_read(_path)
        self
      end

      # @return [false]
      def read?(_path)
        false
      end

      # @return [Array]
      def reminders
        [].freeze
      end

      INSTANCE = new.freeze

      # @return [Null] the shared instance
      def self.instance
        INSTANCE
      end
    end
  end
end
