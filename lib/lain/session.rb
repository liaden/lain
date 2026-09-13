# frozen_string_literal: true

module Lain
  # Mutable state for ONE run, and deliberately not a value object.
  #
  # Everything else the model sees is either content-addressed and frozen (an
  # {Lain::Event}) or frozen and sent-not-stored (a {Lain::Workspace}). Session
  # is the exception on purpose: it is the run's scratch memory and must
  # accumulate as tools run. Keeping it OFF the Timeline is what keeps
  # `Ractor.shareable?(turn)` true, and it is why rewinding or forking the
  # Timeline can never resurrect or lose a todo list -- there was never a copy
  # of it there, only here.
  #
  # The pin-set (turn digests compaction may not elide) is modelled on the
  # READ-set rather than the write-set, because only the read-set is journaled
  # and replayed, and a pin that vanished on `--resume` would be worse than no
  # pin at all.
  #
  # Writing the run-state into the session record is Session's own job, not a
  # decorator's: `journal:` defaults to {Channel::Null}, so a Session built
  # without one behaves exactly as one built before journaling existed, and
  # {SessionRecord::Replay} folds a record back through a journal-less Session
  # rather than re-journaling every line it just read.
  class Session
    # Added HERE rather than inside {Memory::Manifest#to_reminder}, which stays
    # bare: naming memory_read as the way to open an id is the session's
    # presentation decision, as the todo block's own heading is.
    MANIFEST_HEADING = "Memory manifest, one \"id | description\" per item " \
                       "(call memory_read with an id to open its body):"

    # Both collaborators default to an empty holder answering the same duck as
    # the real one, so {#reminders} never guards on a missing source.
    #
    # SNAPSHOT-AT-CONSTRUCTION: a real Session captures `ENV` and `Dir.pwd`
    # ONCE, when it is built. Mutate an EXISTING `ENV["X"]` mid-run and the
    # child sees the snapshot's value, not the live one; an ADDED var still
    # reaches the child, because the parent's live ENV is inherited too.
    # {Session::Null} sidesteps this by recomputing {WorkerEnv.default} per call.
    #
    # @param memory [#index] the run's memory source, projected onto
    #   {#reminders} whenever its index holds items
    # @param worker_env [WorkerEnv] the host context tools resolve paths and
    #   shell out against
    # @param journal [#<<] where {Telemetry::SessionRead} /
    #   {Telemetry::SessionPin} / {Telemetry::TodoSnapshot} land; the Null
    #   channel records nothing and is what every non-chat Session uses
    def initialize(memory: Memory::Recorder.new, worker_env: WorkerEnv.default,
                   journal: Channel::Null.instance)
      @journal = journal
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

    # The read-set's path identity, public because the two middleware that ask
    # about a path ({Middleware::RedactSecretReads},
    # {Middleware::GuardTestLayout}) must name it exactly as {#read?} will.
    #
    # `cwd:` is required, never defaulted: falling back to `Dir.pwd` would let
    # a caller name a process-relative path while the read-set stored a
    # worker-relative one -- a divergence in the Journal, which is the
    # experiment record.
    #
    # The rule is {WorkerEnv#resolve}'s, so this delegates rather than
    # re-deriving it; only `cwd` is read, hence the empty `env`.
    #
    # @return [String]
    def self.normalize_path(path, cwd:)
      WorkerEnv.new(cwd:, env: {}).resolve(path.to_s)
    end

    # Normalized so a later `read?` cannot be defeated by a different spelling
    # of the same file.
    #
    # `complete: false` says the model saw only PART of the file. It must be
    # distinguishable from a whole read, because a model that saw
    # `<redacted:1>` and then writes the file clobbers every secret in it; and
    # from NO read, so a refusal can say why rather than claim it was unread.
    #
    # Completeness is recorded HERE rather than un-recorded from the middleware
    # that decides to mask: {Tools::ReadFile} records below the middleware, so
    # the read has already happened by then and the read-set has no retraction.
    # {ReadSet}'s three add-only sets are what keep it monotone.
    #
    # The transition check, the mutation and the journal write are one
    # fiber-safe sequence: no yield point sits between the check and the Set
    # mutation (both pure Ruby, no IO), and the journal write -- the only place
    # a fiber COULD yield -- runs AFTER the mutation, so two fibers reading the
    # same path cannot both see "first". The claim carries ToolRunner's
    # gathered dispatch (docs/concurrency.md, "parallel tools") and is pinned
    # by spec/lain/session_concurrency_spec.rb; if that spec can only pass by
    # adding a lock here, the claim has failed -- escalate, do not patch.
    # Moving the journal write above the mutation breaks it silently.
    #
    # A line is journaled on a read-set STATE TRANSITION, not on a call, and
    # completeness gives two: nothing-to-recorded and partial-to-complete. So a
    # partial read followed by a complete one journals TWICE -- the model
    # genuinely saw two different things -- while a re-read at the same
    # completeness journals nothing, and a complete read followed by a partial
    # one journals nothing further, mirroring the read-set's own refusal to
    # downgrade. No record stream can replay as a downgrade.
    #
    # ONE path escapes that dedupe, and it is {ReadSet#complete?}'s doing
    # rather than this method's: a MASKED path answers false to it forever, so
    # the complete-read transition never closes and every re-read journals
    # another line -- a per-iteration flood on exactly the redacted file the
    # dedupe most wants to protect. Inherited unchanged from the decorator this
    # replaced, and pinned by a spec of its own so it cannot drift in silence.
    # Pinned is not blessed: whether the masked set should suppress the record
    # too is a real question, and a separate one.
    #
    # @return [self]
    def record_read(path, complete: true)
      target = normalize(path)
      transition = complete ? !@reads.complete?(target) : !@reads.recorded?(target)
      @reads.record(target, complete:)
      @journal << Telemetry::SessionRead.new(path: target, complete:) if transition
      self
    end

    # @return [Boolean] whether `path` (in any spelling) was read IN FULL this
    #   session -- the question the edit-before-write contracts ask, so a
    #   partial read answers false
    def read?(path)
      @reads.complete?(normalize(path))
    end

    # Bytes were withheld from the model, so it must not be trusted to rewrite
    # the file. Separate from `record_read(complete: false)` because the two
    # facts arrive from different layers and only this one can arrive AFTER a
    # whole read was recorded. See {ReadSet} for why that forces a third set
    # rather than a retraction.
    #
    # Journals NO {Telemetry::SessionRead}: that record says only `complete:`,
    # and {SessionRecord::Replay} folds each one through {#record_read}, which
    # by construction cannot reach the masked set. A `complete: false` line
    # here would therefore replay to a wholly-read path -- a record that LOOKS
    # like the mask was persisted while a resumed session permits the very
    # write the mask exists to refuse. {Middleware::RedactSecretReads} writes a
    # {Telemetry::ReadRedacted} into this same journal at the same moment, and
    # {SessionRecord::Replay#redactions} folds it back.
    #
    # @return [self]
    def record_masked_read(path)
      @reads.mask(normalize(path))
      self
    end

    # @return [Boolean] whether `path` was read, but only in part -- the middle
    #   answer between {#read?} and never-read, so a refusal can name the real
    #   reason. Mutually exclusive with {#read?} by construction.
    def partially_read?(path)
      @reads.partial?(normalize(path))
    end

    # @return [Boolean] whether what the model saw of `path` had bytes masked
    #   out of it -- which of the two causes {#partially_read?} covers, so a
    #   refusal can tell "re-read this" from "ask for a release"
    def masked_read?(path)
      @reads.masked?(normalize(path))
    end

    # Sorted, so a consumer cannot vary with the order reads arrived.
    # Deliberately WIDER than {#read?}: a partially read path was still read.
    #
    # @return [Array<String>]
    def reads
      @reads.paths
    end

    # The read-set's mirror, deliberately NOT implying a read: the read-set
    # answers the edit-before-read contract, the write-set scopes the snapshot,
    # and a tool that did both says both.
    #
    # Journals nothing. The write's record is the :snapshot event
    # {Workspace::Snapshot} lands in the Store, which is IN-MEMORY, so a
    # replayed session rebuilds with an empty write-set. Deliberate: a journal
    # line here alone would be a half-copy naming blobs no replay can fetch.
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

    # Sorted, so the snapshot body built over it cannot vary with the order
    # tools happened to write.
    #
    # @return [Array<String>]
    def writes
      @writes.sort.freeze
    end

    # Pin a turn digest: "compaction may not elide this one". A digest is
    # already a content address, so unlike a path there is nothing to
    # normalize; interning keeps the set's members comparable as pointers.
    #
    # Journaled in BOTH directions, unconditionally: the record stream is an
    # ordered LOG, not a set of pin events, because a pin followed by an unpin
    # has to rebuild as NOT pinned. Hence one record type carrying `pinned:`
    # rather than two -- a reader folding in file order gets the retraction
    # free. No first-time dedupe, unlike {#record_read}: a pin arrives from an
    # operator command or a plan boundary, never from a read/edit loop, so
    # there is no per-iteration flood to suppress, and suppressing a repeat
    # would only make the log's order-sensitivity subtler.
    #
    # @return [self]
    def record_pin(digest)
      @pins << named!(digest)
      @journal << Telemetry::SessionPin.new(digest:, pinned: true)
      self
    end

    # Unpinning what was never pinned is a no-op, not an error: a caller who
    # cannot see the set -- a replay folding a log, an operator retyping --
    # should not have to check first.
    #
    # @return [self]
    def record_unpin(digest)
      @pins.delete(named!(digest))
      @journal << Telemetry::SessionPin.new(digest:, pinned: false)
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

    # Which turns must survive a compaction. The sort is per call, so a hot loop
    # testing MEMBERSHIP wants {#pinned?} -- O(1) on the Set -- rather than this.
    #
    # @return [Array<String>]
    def pins
      @pins.sort.freeze
    end

    # Replaces the ENTIRE list, with no merge logic, so a stale item can never
    # linger from a call the model did not intend to partially apply.
    #
    # The one-string render happens HERE, once per write, rather than inside
    # {#reminders}, which the Agent calls on every render: a run that writes its
    # list once and takes fifty more turns should not re-join the same strings
    # fifty times.
    #
    # Journaled on every call, unconditionally and as the WHOLE list, so a
    # replay folding in recorded order lands on the last list written.
    #
    # @return [self]
    def write_todos(todos)
      list = todos.to_a
      @plan_step_completed = completed_count(list) > completed_count(@todo_items)
      @todo_items = list
      @todo_reminder = list.empty? ? nil : render_todos(list).freeze
      @journal << Telemetry::TodoSnapshot.from(list)
      self
    end

    # Whether the MOST RECENT {#write_todos} raised the count of `"completed"`
    # items -- {Compaction::Need::PlanStepCompletion}'s signal.
    #
    # Count-based rather than content-keyed on purpose: content is not a stable
    # identity for a todo, so diffing "which content is now completed that was
    # not" masks a real transition whenever two items share wording. A rising
    # COUNT is immune to duplicates and to reordering, and it fires whether the
    # step flipped to completed or arrived already-done.
    #
    # @return [Boolean]
    def plan_step_completed?
      @plan_step_completed
    end

    # What the Agent renders into the Workspace tail each turn. Never a Timeline
    # entry, so rewinding or forking the Timeline has no bearing on either
    # block.
    #
    # @return [Array<String>]
    def reminders
      (todo_reminders + manifest_reminders).freeze
    end

    # Attach the run's journal to a Session that already exists. The RESUMED
    # case needs it: {SessionRecord::Replay} folds a record into a journal-less
    # Session -- a journaled one would re-journal every line it just read --
    # and only then does {CLI::Chronicle#wrap_session} hand it the new run's
    # journal.
    #
    # Refused a second time, rather than merely documented as wiring-time-only:
    # swapping a journal mid-run would split one run's record across two files,
    # and neither half would say so. A Session already holding the Null channel
    # has no record to split, which is why that is the one state this accepts.
    #
    # @return [self]
    def journals_into(journal)
      unless @journal.equal?(Channel::Null.instance)
        raise ArgumentError,
              "a session journals into one destination for the whole run, " \
              "and this one already journals into a #{@journal.class}"
      end

      @journal = journal
      self
    end

    private

    def todo_reminders
      @todo_reminder ? [@todo_reminder] : []
    end

    # {#write_todos}'s once-per-write rule, applied to a source this object does
    # not write through: the index's root is a content address, so it is a free
    # invalidation key -- equal roots mean an identical corpus by construction.
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

    # Against the WORKER's cwd, not the process's: under isolation those differ,
    # and the read-set must answer on the file the TOOLS resolved.
    def normalize(path)
      self.class.normalize_path(path, cwd: @worker_env.cwd)
    end

    # A blank digest is refused rather than coerced: `-nil.to_s` would put "" in
    # the set, after which `pinned?(nil)` answers TRUE and a turn that does not
    # exist reads as protected.
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

    # Which files were read, and which of those were read WHOLE.
    #
    # THREE add-only sets, never a flag per path, and that is the whole design:
    # membership, completeness and masking only ever move forward, so a sibling
    # fiber cannot race a complete read backwards into a partial one. The
    # structure carries the monotonicity rather than a rule a caller has to
    # remember; a Hash of path => complete would express the same states and
    # lose exactly that guarantee.
    #
    # Completeness and masking need SEPARATE sets because each fact is known at
    # a different layer, and collapsing them is the refactor to refuse.
    # {Tools::ReadFile} calls `record_read` inside `#perform`, BELOW the
    # middleware, having read the whole file -- so the complete set gains the
    # path before masking is even decided, and a later `record(complete: false)`
    # cannot take it back. Only {Middleware::RedactSecretReads}, one layer
    # above, knows bytes were withheld, so the masking arm adds to a THIRD set
    # and {#complete?} is the conjunction: read whole AND nothing withheld.
    #
    # Masking is add-only too, so the composite answer moves only toward
    # refusing an edit. A path masked on an earlier read therefore stays
    # un-editable for the rest of the run even if a later read releases
    # everything: over-strict on purpose, and NOT to be fixed with a delete.
    #
    # Members arrive ALREADY normalized -- path identity belongs to {Session},
    # which owns the worker cwd.
    class ReadSet
      def initialize
        @all = Set.new
        @complete = Set.new
        @masked = Set.new
      end

      # The strict-boolean check comes FIRST, ahead of both mutations. Read for
      # truthiness instead and `complete: "false"` silently records a COMPLETE
      # read -- the unsafe direction. The journal record's own guard is no
      # substitute: it fires one layer out and only AFTER this has mutated, so a
      # caller that rescues would hold live state more permissive than what
      # replays. It is pure Ruby with no IO, so it runs inside the same
      # yield-free window rather than widening it.
      #
      # DUPLICATES {Telemetry::Carriers::SessionRead} deliberately: this guards
      # the in-memory read-set, which a bare Session mutates with no journal in
      # sight, and that one guards the record on its way to disk. Deleting
      # either reopens exactly one of those two boundaries.
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

      # Deliberately NOT a parameter on {#record}: a caller able to pass
      # `masked: false` could spell "this read hid nothing" over a read that hid
      # something.
      #
      # It records membership too, because a masked read IS a read: without it a
      # path masked before it was ever recorded answers false to both
      # {#complete?} and {#partial?}, which reads as "never read".
      #
      # @param path [String] an already-normalized absolute path
      # @return [self]
      def mask(path)
        @all << path
        @masked << path
        self
      end

      # Both halves, because either alone answers a question the edit-before-
      # write contract is not asking.
      #
      # @return [Boolean]
      def complete?(path) = @complete.include?(path) && !@masked.include?(path)

      # Read, but not wholly seen. A caller asking this wants "is there more of
      # this file the model has not seen", for which the two causes are the same
      # fact; {#masked?} tells them apart.
      #
      # @return [Boolean]
      def partial?(path) = @all.include?(path) && !complete?(path)

      # Which of {#partial?}'s two causes applies, so a refusal can tell the
      # model whether to re-read or to ask for a release.
      #
      # @return [Boolean]
      def masked?(path) = @masked.include?(path)

      # "Recorded at all", which is the union {#paths} lists -- the predicate a
      # PARTIAL read's journal transition tests against, since for it the
      # transition is out of never-read, not out of not-yet-complete.
      #
      # @return [Boolean]
      def recorded?(path) = @all.include?(path)

      # @return [Array<String>] every path recorded, complete or partial, sorted
      def paths = @all.sort.freeze
    end

    # The no-op Session, mirroring {Channel::Null} and {Sink::Null}, so no tool
    # ever writes an `if session` guard. A single shared frozen instance: it has
    # no state to keep, and nothing to journal either.
    class Null
      # `complete:` is accepted and discarded, but it cannot be renamed to the
      # unused-argument underscore: it is a KEYWORD, so the name is the duck.
      #
      # @return [self]
      def record_read(_path, complete: true) # rubocop:disable Lint/UnusedMethodArgument
        self
      end

      # @return [self]
      def record_masked_read(_path) = self

      # @return [self]
      def record_write(_path) = self

      # @return [self]
      def record_pin(_digest) = self

      # @return [self]
      def record_unpin(_digest) = self

      # @return [self]
      def write_todos(_todos) = self

      # Accepted and discarded: {CLI::Chronicle#wrap_session} must be able to
      # hand a journal to whatever Session the run holds, without asking first.
      # No refusal on a second call either -- there is nothing here to split.
      #
      # @return [self]
      def journals_into(_journal) = self

      # @return [false]
      def read?(_path) = false

      # False here AND from {#read?} is the "no read at all" answer, so the pair
      # stays mutually exclusive as it is on a real Session.
      #
      # @return [false]
      def partially_read?(_path) = false

      # @return [false]
      def masked_read?(_path) = false

      # @return [false]
      def written?(_path) = false

      # @return [false]
      def pinned?(_digest) = false

      # @return [false]
      def plan_step_completed? = false

      # @return [Array]
      def reads = [].freeze

      # @return [Array]
      def writes = [].freeze

      # @return [Array]
      def pins = [].freeze

      # @return [Array]
      def reminders = [].freeze

      # Recomputed per call: the one shared frozen instance cannot capture a
      # working directory that may change under it, so a context-less tool still
      # resolves against the LIVE `Dir.pwd`.
      #
      # @return [WorkerEnv]
      def worker_env = WorkerEnv.default

      INSTANCE = new.freeze

      # @return [Null] the shared instance
      def self.instance = INSTANCE
    end
  end
end
