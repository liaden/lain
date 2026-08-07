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
  # Five responsibilities today:
  #   * a read-set, so an edit-before-read contract can ask "was this file read
  #     this session?" (see {Tool::Contracts});
  #   * a write-set, the read-set's mirror for mutations: the paths structured
  #     mutating tools wrote this session, which is exactly the scope of a
  #     workspace snapshot ({Workspace::Snapshot} -- write-set only, the
  #     documented gap for free-form bash);
  #   * a pin-set, the turn digests compaction may not elide (B1) -- modelled
  #     on the READ-set, not the write-set: only the read-set is journaled and
  #     replayed, and a pin that vanished on `--resume` would be worse than no
  #     pin at all;
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
    # `worker_env:` defaults to {WorkerEnv.default} -- the live `Dir.pwd` and a
    # snapshot of `ENV` -- so a run that injects no isolation resolves paths and
    # shells out exactly as it did before WorkerEnv existed. An overriding
    # strategy passes a WorkerEnv here, and the tools read it off the context
    # they already receive.
    #
    # SNAPSHOT-AT-CONSTRUCTION: a real Session captures `ENV` (and `Dir.pwd`)
    # ONCE, when it is built. The byte-identical-default claim therefore holds
    # only absent a mid-run ENV mutation of an EXISTING var: mutate `ENV["X"]`
    # after this Session exists and the child sees the snapshot's value, not the
    # live one. (An ADDED var still reaches the child regardless -- the parent's
    # live ENV is inherited too; see {WorkerEnv}'s additive-override note.)
    # {Session::Null} sidesteps this by recomputing {WorkerEnv.default} per call.
    def initialize(memory: Memory::Recorder.new, worker_env: WorkerEnv.default)
      @reads = ReadSet.new
      @writes = Set.new
      @pins = Set.new
      @todo_reminder = nil
      @todo_items = []
      @plan_step_completed = false
      @memory = memory
      @manifest_root = nil
      @manifest_reminders = [].freeze
      @worker_env = worker_env
    end

    # The host-side execution context a tool resolves paths and env against --
    # sent to tools via {Tool::Invocation#context}, never onto the Timeline.
    #
    # @return [WorkerEnv]
    attr_reader :worker_env

    # The read-set's path identity, public so {Session::Journaled} can ask
    # "which path did that read just normalize to?" without reaching into a
    # private method -- the one seam a journaling decorator needs to know
    # WHICH path to record, since it must match exactly what {#read?} will
    # answer true for afterwards.
    #
    # `cwd:` is required, never defaulted: a class method has no `worker_env`,
    # and falling back to `Dir.pwd` would let the decorator journal a
    # process-relative path while the read-set stored a worker-relative one --
    # a divergence in the Journal, which is the experiment record.
    #
    # The rule itself is {WorkerEnv#resolve}'s -- the one both exec arms
    # already share -- so this DELEGATES rather than re-deriving it, and a
    # throwaway WorkerEnv is how a bare `cwd` reaches an instance method. Only
    # `cwd` is read, hence the empty `env`. `to_s` covers the Symbol and nil
    # spellings a Set query may arrive in; `resolve` itself wants a String.
    #
    # @return [String]
    def self.normalize_path(path, cwd:)
      WorkerEnv.new(cwd:, env: {}).resolve(path.to_s)
    end

    # Record that `path` was read this session. Normalized so a later `read?`
    # cannot be defeated by a different spelling of the same file.
    #
    # `complete: false` says the model saw only PART of the file -- today, a
    # rendering with secrets masked. It has to be distinguishable from a whole
    # read, because a model that saw `<redacted:1>` and then writes the file
    # clobbers every secret in it; and it has to be distinguishable from NO
    # read, so a refusal can say why rather than claim the file was unread.
    #
    # Completeness is recorded HERE rather than un-recorded from the middleware
    # that decides to mask: {Tools::ReadFile} records its read below the
    # middleware, so by the time masking is decided the read already happened,
    # and the read-set has no retraction. Two ADD-ONLY sets is what keeps it
    # monotone -- a complete read can never be undone by a later partial one,
    # so two sibling fibers reading the same file cannot race it backwards.
    # A single mutable flag per path would lose exactly that.
    #
    # @return [self]
    def record_read(path, complete: true)
      @reads.record(normalize(path), complete:)
      self
    end

    # @return [Boolean] whether `path` (in any spelling) was read IN FULL this
    #   session -- the question the edit-before-write contracts ask, so a
    #   partial read answers false
    def read?(path)
      @reads.complete?(normalize(path))
    end

    # @return [Boolean] whether `path` was read, but only in part -- the middle
    #   answer between {#read?} and never-read, so a refusal can name the real
    #   reason. Mutually exclusive with {#read?} by construction.
    def partially_read?(path)
      @reads.partial?(normalize(path))
    end

    # Every path read this session, complete or partial, as sorted normalized
    # paths -- the read-set's own window, mirroring {#writes}. Sorted for the
    # same reason: a consumer must not vary with the order reads arrived.
    #
    # Deliberately WIDER than {#read?}, which answers only for a complete read:
    # a partially read path was still read, and is still listed here.
    #
    # @return [Array<String>]
    def reads
      @reads.paths
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

    # Pin a turn digest: "compaction may not elide this one". Digests are
    # already content addresses, so unlike a path there is no normalization to
    # do -- the digest a caller resolved off the Timeline IS the identity, and
    # interning it keeps the set's members comparable as pointers.
    #
    # @return [self]
    def record_pin(digest)
      @pins << named!(digest)
      self
    end

    # Retract a pin. Unpinning what was never pinned is a no-op, not an error:
    # the pin-set is a SET, and a caller who cannot see it (a replay folding a
    # log, an operator retyping) should not have to check first.
    #
    # @return [self]
    def record_unpin(digest)
      @pins.delete(named!(digest))
      self
    end

    # Raise-free by construction: nothing blank can enter the set (see
    # {#named!}), so the query needs no guard of its own and a caller may ask
    # about anything without a rescue.
    #
    # @return [Boolean] whether `digest` is pinned this session
    def pinned?(digest)
      @pins.include?(-digest.to_s)
    end

    # The pin-set as sorted digests -- the query a compaction source asks
    # ("which turns must survive?"), sorted for the same reason {#writes} is:
    # a consumer must not vary with the order the pins happened to arrive.
    # The sort is per call, so a hot loop testing MEMBERSHIP wants {#pinned?}
    # (O(1) on the Set) rather than this.
    #
    # @return [Array<String>]
    def pins
      @pins.sort.freeze
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

    # Path identity is `File.expand_path` against the WORKER's cwd: "./app.rb"
    # recorded and "app.rb" queried (or the reverse) are the same file, so the
    # read-set answers on the file, not on the string the model happened to
    # type -- and on the file the TOOLS resolved, which under isolation is not
    # the one `Dir.pwd` names.
    def normalize(path)
      self.class.normalize_path(path, cwd: @worker_env.cwd)
    end

    # A digest has no empty spelling the way a path has "" -> the worker's cwd
    # (see {.normalize_path}), so a blank one is refused rather than coerced:
    # `-nil.to_s` would otherwise put "" in the set, after which `pinned?(nil)`
    # answers TRUE and a turn that does not exist reads as protected.
    def named!(digest)
      name = -digest.to_s
      raise ArgumentError, "a pin must name a turn digest, got #{digest.inspect}" if name.strip.empty?

      name
    end

    def render_todos(list)
      lines = list.map { |todo| "- [#{todo.status}] #{todo.content}" }
      "Current todo list:\n#{lines.join("\n")}"
    end

    def completed_count(list)
      list.count { |todo| todo.status == "completed" }
    end

    # Which files were read, and which of those were read WHOLE -- the one
    # concept {Session}'s read-set became once a partial read had to be
    # distinguishable from both a complete one and from no read at all.
    #
    # TWO add-only sets, never a flag per path, and that is the whole design:
    # membership and completeness both only ever move forward, so a complete
    # read cannot be raced backwards into a partial one by a sibling fiber, and
    # the structure itself carries the monotonicity rather than a rule some
    # caller has to remember. A Hash of path => complete would express the same
    # states and lose exactly that guarantee.
    #
    # Members arrive ALREADY normalized: path identity belongs to {Session},
    # which owns the worker cwd, so this object never has to know about one.
    class ReadSet
      def initialize
        @all = Set.new
        @complete = Set.new
      end

      # The strict-boolean check comes FIRST, ahead of both mutations, and that
      # ordering is the point: read for truthiness instead and `complete:
      # "false"` records a COMPLETE read -- the unsafe direction, silently. The
      # journal record's own guard is not a substitute, because it fires one
      # layer out and only AFTER this has already mutated, which would leave a
      # caller that rescues holding live state more permissive than what
      # replays. That inverts the one-way property the design rests on.
      #
      # It costs nothing against the fiber-safety claim: pure Ruby with no IO,
      # so it runs inside the same yield-free window rather than widening it.
      #
      # This DUPLICATES the identical check in {Telemetry::Guards::SessionRead},
      # deliberately. Neither is redundant: this one guards the in-memory
      # read-set, which a bare Session mutates with no journal anywhere in
      # sight, and that one guards the record on its way to disk. Deleting
      # either because the other exists reopens exactly one of those two
      # boundaries.
      #
      # @param path [String] an already-normalized absolute path
      # @param complete [Boolean] whether the whole file was seen
      # @return [self]
      def record(path, complete:)
        unless [true, false].include?(complete)
          raise ArgumentError, "complete must be true or false, got #{complete.inspect}"
        end

        @all << path
        @complete << path if complete
        self
      end

      # @return [Boolean]
      def complete?(path) = @complete.include?(path)

      # @return [Boolean]
      def partial?(path) = @all.include?(path) && !@complete.include?(path)

      # @return [Array<String>] every path recorded, complete or partial, sorted
      def paths = @all.sort.freeze
    end

    # The no-op Session, mirroring {Channel::Null} and {Sink::Null}: it satisfies
    # the same duck so a tool handed a context can always `record_read`/`read?`/
    # `write_todos` without an `if session` guard. Records nothing, reads back
    # false, offers no reminders. A single shared frozen instance -- it has no
    # state to keep.
    class Null
      # `complete:` is accepted and discarded, but it cannot be renamed to the
      # unused-argument underscore: it is a KEYWORD, so the name is the duck.
      #
      # @return [self]
      def record_read(_path, complete: true) # rubocop:disable Lint/UnusedMethodArgument
        self
      end

      # @return [false]
      def read?(_path)
        false
      end

      # Records nothing, so every path reads back as never-read rather than as
      # partially read -- {#read?} and this both false is the "no read at all"
      # answer, and the pair stays mutually exclusive as on a real Session.
      #
      # @return [false]
      def partially_read?(_path)
        false
      end

      # @return [Array]
      def reads
        [].freeze
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
      def record_pin(_digest)
        self
      end

      # @return [self]
      def record_unpin(_digest)
        self
      end

      # @return [false]
      def pinned?(_digest)
        false
      end

      # @return [Array]
      def pins
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

      # The default host context, recomputed each call so a bare (context-less)
      # tool still resolves against the LIVE `Dir.pwd` -- the one shared frozen
      # Null instance cannot capture a working directory that may change under
      # it, so it defers to {WorkerEnv.default} every time.
      #
      # @return [WorkerEnv]
      def worker_env = WorkerEnv.default

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
      # both see "first". This claim carries ToolRunner's gathered dispatch
      # (docs/concurrency.md, "parallel tools") and is pinned by
      # spec/lain/session_concurrency_spec.rb; if that spec can only pass by
      # adding a lock here, the claim has failed -- escalate, don't patch.
      # The completeness check below preserves this exactly: it adds reads to
      # the pure-Ruby half and nothing to the journal half, so the yield-free
      # window between check and mutate is the same size it was. Anything that
      # moves the journal write above the mutation breaks it silently.
      #
      # A line is journaled on a read-set STATE TRANSITION, not on a call. With
      # completeness that is two transitions, not one: nothing-to-recorded, and
      # partial-to-complete. So a partial read followed by a complete one
      # journals TWICE -- correct, because the model genuinely saw two
      # different things -- while a re-read at the same completeness journals
      # nothing, which is what keeps a read/edit loop over a redacted file from
      # emitting one line per iteration. A complete read followed by a partial
      # one journals nothing further, mirroring the read-set's own refusal to
      # downgrade: no record stream can ever replay as a downgrade.
      #
      # @return [self]
      def record_read(path, complete: true)
        transition = complete ? !@session.read?(path) : !recorded?(path)
        @session.record_read(path, complete:)
        @journal << Telemetry::SessionRead.new(path: normalized(path), complete:) if transition
        self
      end

      # @return [Boolean]
      def read?(path) = @session.read?(path)

      # @return [Boolean]
      def partially_read?(path) = @session.partially_read?(path)

      # @return [Array<String>]
      def reads = @session.reads

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

      # The pin-set journals BOTH directions, unconditionally: the record
      # stream is an ordered LOG, not a set of pin events, because a pin
      # followed by an unpin has to rebuild as NOT pinned. Hence one record
      # type carrying `pinned:` rather than two types -- a reader folding in
      # file order gets the retraction for free.
      #
      # No first-time dedupe here (unlike {#record_read}): a pin arrives from
      # an operator command or an auto-pin at a plan boundary, never from a
      # read/edit loop, so there is no per-iteration flood to suppress -- and
      # suppressing a repeat would make the log's order-sensitivity subtler
      # for no gain.
      #
      # @return [self]
      def record_pin(digest)
        @session.record_pin(digest)
        @journal << Telemetry::SessionPin.new(digest:, pinned: true)
        self
      end

      # @return [self]
      def record_unpin(digest)
        @session.record_unpin(digest)
        @journal << Telemetry::SessionPin.new(digest:, pinned: false)
        self
      end

      # @return [Boolean]
      def pinned?(digest) = @session.pinned?(digest)

      # @return [Array<String>]
      def pins = @session.pins

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

      # @return [WorkerEnv] the wrapped session's host context, forwarded
      #   untouched -- WorkerEnv is sent-not-stored, so there is nothing to
      #   journal.
      def worker_env = @session.worker_env

      private

      # The wrapped session's cwd, never the process's: the journaled path has
      # to be the exact string the read-set now holds, or the Journal names a
      # different file than {#read?} answers true for.
      def normalized(path) = Session.normalize_path(path, cwd: @session.worker_env.cwd)

      # "Recorded at all", the union {Session#reads} lists -- the predicate a
      # PARTIAL read tests against, since for it the transition is out of
      # never-read, not out of not-yet-complete.
      def recorded?(path) = @session.read?(path) || @session.partially_read?(path)
    end
  end
end
