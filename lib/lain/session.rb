# frozen_string_literal: true

module Lain
  # Mutable state for ONE run, and deliberately not a value object.
  #
  # Everything else in the harness that the model sees is either content-
  # addressed and frozen (a {Lain::Turn} in the Timeline) or frozen and sent-
  # not-stored (a {Lain::Workspace}). Session is the exception on purpose: it is
  # the run's scratch memory -- which files have been read, and the todo list --
  # and it must accumulate as tools run. So it is never appended to the
  # Timeline, never enters a Turn's content, and stays reachable only from the
  # Agent and from the {Tool::Invocation#context} threaded to each tool. Keeping
  # it off the Timeline is what keeps `Ractor.shareable?(turn)` true: the mutable
  # state lives here, where nothing frozen reaches it. It is also why rewinding
  # or forking the Timeline can never resurrect (or lose) a todo list: there was
  # never a copy of it there to begin with, only here.
  #
  # Two responsibilities today:
  #   * a read-set, so an edit-before-read contract can ask "was this file read
  #     this session?" (see {Tool::Contracts});
  #   * a reminders channel -- empty until {Tools::TodoWrite} lands the run's
  #     todo list, then one rendered string -- that the Agent composes into the
  #     Workspace tail every render.
  class Session
    def initialize
      @reads = Set.new
      @todo_reminder = nil
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

    # Replaces the ENTIRE todo list -- deterministic, no merge logic, so a
    # stale item can never linger from a call the model didn't intend to
    # partially apply. `todos` is any Enumerable of objects answering
    # `#content`/`#status` ({Tools::TodoWrite} is the only caller today).
    #
    # The one-string render happens HERE, once per write, rather than inside
    # {#reminders} -- which the Agent calls every single render via
    # `@workspace.with(*@session.reminders)` (T11 review, Patterson). A run
    # that writes its list once and takes fifty more turns should not re-join
    # the same strings fifty times.
    #
    # @return [self]
    def write_todos(todos)
      list = todos.to_a
      @todo_reminder = list.empty? ? nil : render_todos(list).freeze
      self
    end

    # State the Agent renders into the Workspace tail each turn: empty until a
    # todo_write lands, then ONE string -- the whole list, the same
    # render-to-one-string shape as {Memory::Manifest#to_reminder} -- never a
    # Timeline entry, so the Timeline being rewound or forked has no bearing on
    # it; it lives here, not there.
    #
    # @return [Array<String>]
    def reminders
      @todo_reminder ? [@todo_reminder].freeze : [].freeze
    end

    private

    # Path identity is `File.expand_path`: "./app.rb" recorded and "app.rb"
    # queried (or the reverse) are the same file, so the read-set answers on the
    # file, not on the string the model happened to type.
    def normalize(path)
      File.expand_path(path.to_s)
    end

    def render_todos(list)
      lines = list.map { |todo| "- [#{todo.status}] #{todo.content}" }
      "Current todo list:\n#{lines.join("\n")}"
    end

    # The no-op Session, mirroring {Channel::Null} and {Sink::Null}: it satisfies
    # the same duck so a tool handed a context can always `record_read`/`read?`/
    # `write_todos` without an `if session` guard. Records nothing, reads back
    # false, offers no reminders. A single shared frozen instance -- it has no
    # state to keep.
    class Null
      # @return [self]
      def record_read(_path)
        self
      end

      # @return [false]
      def read?(_path)
        false
      end

      # @return [self]
      def write_todos(_todos)
        self
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
