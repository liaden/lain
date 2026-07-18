# frozen_string_literal: true

module Lain
  # Mutable state for ONE run, and deliberately not a value object.
  #
  # Everything else in the harness that the model sees is either content-
  # addressed and frozen (an {Lain::Event} in the Timeline) or frozen and sent-
  # not-stored (a {Lain::Workspace}). Session is the exception on purpose: it is
  # the run's scratch memory -- which files have been read, and the todo list --
  # and it must accumulate as tools run. So it is never appended to the
  # Timeline, never enters a turn's content, and stays reachable only from the
  # Agent and from the {Tool::Invocation#context} threaded to each tool. Keeping
  # it off the Timeline is what keeps `Ractor.shareable?(turn)` true: the mutable
  # state lives here, where nothing frozen reaches it. It is also why rewinding
  # or forking the Timeline can never resurrect (or lose) a todo list: there was
  # never a copy of it there to begin with, only here.
  #
  # Four responsibilities today:
  #   * a read-set, so an edit-before-read contract can ask "was this file read
  #     this session?" (see {Tool::Contracts});
  #   * a write-set, the read-set's mirror for mutations: the paths structured
  #     mutating tools wrote this session, which is exactly the scope of a
  #     workspace snapshot ({Workspace::Snapshot} -- write-set only, the
  #     documented gap for free-form bash);
  #   * a reminders channel -- empty until {Tools::TodoWrite} lands the run's
  #     todo list, then one rendered string -- that the Agent composes into the
  #     Workspace tail every render;
  #   * the memory manifest, projected from an injected memory source (the
  #     session's {Memory::Recorder}) onto that same channel whenever its
  #     index holds items.
  class Session
    # The manifest block's first line, added HERE rather than inside
    # {Memory::Manifest#to_reminder} (which stays bare): naming memory_read as
    # the way to open an id is the session's presentation decision, the same
    # way the todo block carries its own heading.
    MANIFEST_HEADING = "Memory manifest, one \"id | description\" per item " \
                       "(call memory_read with an id to open its body):"

    # `memory:` defaults to a fresh, empty {Memory::Recorder} -- an empty
    # holder satisfying the same duck as the real one (Null Object over nil
    # checks), so {#reminders} never guards on a missing source.
    def initialize(memory: Memory::Recorder.new)
      @reads = Set.new
      @writes = Set.new
      @todo_reminder = nil
      @todo_items = []
      @plan_step_completed = false
      @memory = memory
      @manifest_root = nil
      @manifest_reminders = [].freeze
    end

    # The read-set's path identity, public so {Session::Journaled} can ask
    # "which path did that read just normalize to?" without reaching into a
    # private method -- the one seam a journaling decorator needs to know
    # WHICH path to record, since it must match exactly what {#read?} will
    # answer true for afterwards.
    #
    # @return [String]
    def self.normalize_path(path)
      File.expand_path(path.to_s)
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

    # Record that `path` was written this session -- the read-set's mirror,
    # same normalization, deliberately NOT implying a read: the read-set
    # answers the edit-before-read contract, the write-set scopes the snapshot,
    # and a tool that did both says both.
    #
    # @return [self]
    def record_write(path)
      @writes << normalize(path)
      self
    end

    # @return [Boolean] whether `path` (in any spelling) was written this session
    def written?(path)
      @writes.include?(normalize(path))
    end

    # The write-set as sorted, normalized paths -- sorted so the snapshot body
    # built over it cannot vary with the order tools happened to write.
    #
    # @return [Array<String>]
    def writes
      @writes.sort.freeze
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
      @plan_step_completed = completed_count(list) > completed_count(@todo_items)
      @todo_items = list
      @todo_reminder = list.empty? ? nil : render_todos(list).freeze
      self
    end

    # Whether the MOST RECENT {#write_todos} call raised the count of
    # `"completed"` items -- the plan-step-completion Need signal
    # ({Compaction::Need::PlanStepCompletion}). `write_todos` replaces the
    # whole list every call and keeps no history of its own (see that
    # method's header), so detecting a rise needs the PRIOR structured list
    # to compare against; {#write_todos} keeps that list (see `@todo_items`)
    # for exactly this comparison. It is retained the same way the
    # read-/write-sets are: in memory, for this run only, never appended to
    # the Timeline and never resurrected on rewind.
    #
    # Count-based rather than content-keyed on purpose: content is not a
    # stable identity for a todo (two items can share the same wording), so
    # diffing "which content is now completed that wasn't" can mask a real
    # transition when duplicate content is present. A rising COUNT is
    # immune to duplicates and to reordering, and it directly expresses the
    # thing this signal means: "a plan step got completed" -- true whether
    # that step just flipped to completed or arrived already-done (a brand
    # new item, or the very first write, landing pre-completed still raises
    # the count, and still fires).
    #
    # @return [Boolean]
    def plan_step_completed?
      @plan_step_completed
    end

    # State the Agent renders into the Workspace tail each turn: the todo
    # block (one string, see {#write_todos}), then the memory manifest block
    # whenever the index is non-empty -- never a Timeline entry, so the
    # Timeline being rewound or forked has no bearing on either; they live
    # here, not there.
    #
    # @return [Array<String>]
    def reminders
      (todo_reminders + manifest_reminders).freeze
    end

    private

    def todo_reminders
      @todo_reminder ? [@todo_reminder] : []
    end

    # The same once-per-write rule as {#write_todos} (T11 review, Patterson),
    # applied to a source THIS object does not write through: the manifest is
    # re-rendered only when the index's root moves. The root is a content
    # address, so it is the free invalidation key -- equal roots mean an
    # identical corpus by construction.
    def manifest_reminders
      index = @memory.index
      refresh_manifest(index) unless index.root == @manifest_root
      @manifest_reminders
    end

    def refresh_manifest(index)
      @manifest_root = index.root
      @manifest_reminders = index.empty? ? [].freeze : [labeled_manifest(index)].freeze
    end

    def labeled_manifest(index)
      -"#{MANIFEST_HEADING}\n#{Memory::Manifest.new(index).to_reminder}"
    end

    # Path identity is `File.expand_path`: "./app.rb" recorded and "app.rb"
    # queried (or the reverse) are the same file, so the read-set answers on the
    # file, not on the string the model happened to type.
    def normalize(path)
      self.class.normalize_path(path)
    end

    def render_todos(list)
      lines = list.map { |todo| "- [#{todo.status}] #{todo.content}" }
      "Current todo list:\n#{lines.join("\n")}"
    end

    def completed_count(list)
      list.count { |todo| todo.status == "completed" }
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
      def record_write(_path)
        self
      end

      # @return [false]
      def written?(_path)
        false
      end

      # @return [Array]
      def writes
        [].freeze
      end

      # @return [self]
      def write_todos(_todos)
        self
      end

      # @return [false]
      def plan_step_completed?
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

    # A Journal-duck decorator over a real Session -- {Memory::JournalMemoryRoot}'s
    # shape, applied here (T16): every call forwards to the wrapped Session
    # untouched, and two of them are ALSO journaled, so
    # {SessionRecord::Replay} can fold a fresh Session back to the same
    # run-state. This is the seam that keeps {Session} itself
    # journal-ignorant -- its own spec never mentions a journal -- because the
    # journaling lives here, one layer out, not inside the domain object.
    #
    # A read journals only the FIRST time {#read?} would flip false -> true
    # for a path: a big read/edit loop that revisits the same file every
    # iteration must not turn into one journal line per iteration (the
    # escalation this design closes without inventing batching). A todo write
    # journals every call, unconditionally, as the WHOLE list -- see
    # {Telemetry::TodoSnapshot}.
    class Journaled
      # @param session [Session] the real Session every call forwards to
      # @param journal [#<<] where {Telemetry::SessionRead} /
      #   {Telemetry::TodoSnapshot} land
      def initialize(session:, journal:)
        @session = session
        @journal = journal
      end

      # The check-before-forward pair is fiber-safe: there is no yield point
      # between the `read?` check and the Set mutation (both pure Ruby, no
      # IO), and the journal write -- the only place a fiber COULD yield --
      # runs after the mutation, so two fibers reading the same path cannot
      # both see "first".
      #
      # @return [self]
      def record_read(path)
        first_read = !@session.read?(path)
        @session.record_read(path)
        @journal << Telemetry::SessionRead.new(path: Session.normalize_path(path)) if first_read
        self
      end

      # @return [Boolean]
      def read?(path) = @session.read?(path)

      # The write-set forwards without journaling. The write's record is the
      # :snapshot event {Workspace::Snapshot} lands in the Store -- which is
      # IN-MEMORY, so that record lives only as long as the process, and a
      # replayed session rebuilds with an empty write-set. Deliberate for W1:
      # persistence (scribe wiring plus a journal shape for blob bytes) is
      # W4's ticket, and a journal line here alone would be a half-copy that
      # could name blobs no replay can fetch.
      #
      # @return [self]
      def record_write(path)
        @session.record_write(path)
        self
      end

      # @return [Boolean]
      def written?(path) = @session.written?(path)

      # @return [Array<String>]
      def writes = @session.writes

      # @return [self]
      def write_todos(todos)
        @session.write_todos(todos)
        @journal << Telemetry::TodoSnapshot.from(todos)
        self
      end

      # @return [Boolean]
      def plan_step_completed? = @session.plan_step_completed?

      # @return [Array<String>]
      def reminders = @session.reminders
    end
  end
end
