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
    # A compaction cut naming a parent this session never recorded: a delta
    # record read without the records it extends.
    class UnrecordedParent < Error; end

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
    # @param memory [#index, #follow] the run's memory source, projected onto
    #   {#reminders} whenever its index holds items, and told where the chain
    #   stands by {#rewound_to}
    # @param worker_env [WorkerEnv] the host context tools resolve paths and
    #   shell out against
    # @param journal [#<<] where {Telemetry::SessionRead} /
    #   {Telemetry::SessionPin} / {Telemetry::TodoSnapshot} land; the Null
    #   channel records nothing and is what every non-chat Session uses
    # @param scope [Unconfined, Confined] where the session's tools are
    #   confined to; a child spawned under plan scope is handed its parent's
    def initialize(memory: Memory::Recorder.new, worker_env: WorkerEnv.default,
                   journal: Channel::Null.instance, scope: Unconfined)
      @journal = journal
      @reads = ReadSet.new
      @writes = Set.new
      @pre_images = PreImages::Closed
      @pins = Set.new
      @todo_reminder = nil
      @todo_items = []
      @plan_step_completed = false
      @plan_step_completions = 0
      @compaction_cuts = [].freeze
      @cuts_by_address = {}
      watch_memory(memory)
      @worker_env = worker_env
      @scope = scope
    end

    # The host-side execution context a tool resolves paths and env against --
    # sent to tools via {Tool::Invocation#context}, never onto the Timeline.
    # The scope in force answers it, so a mode flip that confines the session
    # moves every tool at once, and lifting the scope returns the one the
    # session was built with.
    #
    # @return [WorkerEnv]
    def worker_env = @scope.env_over(@worker_env)

    # @return [Unconfined, Confined]
    attr_reader :scope

    # @param scope [Unconfined, Confined]
    # @return [self]
    def rescope(scope)
      @scope = scope
      self
    end

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

    # Every line of a file, as a read's span: `(first..last)` for a window that
    # stopped short, `(first..)` for one that reached the end of the file.
    WHOLE_FILE = (1..)

    # Normalized so a later `read?` cannot be defeated by a different spelling
    # of the same file.
    #
    # `lines:` says which lines the model saw, so windows over one version of
    # the file can add up to a whole read -- and so a read of part of it is
    # distinguishable from a whole read, because editing from a window clobbers
    # lines the model never saw, and from NO read, so a refusal can say why.
    # `identity:` is that version, and a reader names it from the file it has
    # OPEN, confirmed unchanged once the bytes are read -- a read whose file
    # changed under it is not recorded at all ({Tools::ReadFile} says so).
    # `tool_use_id:` names the call whose result carries the read, and `head:`
    # the chain head its round opened on; {#record_delivery} binds the pair to
    # the turn that delivered it, and only a read whose turn is on the chain
    # counts. A read with no call behind it is on every chain. A replay passes
    # the recorded head; everyone else takes the live one.
    #
    # The mutation runs before the journal write, so two fibers reading the
    # same path see one another's reads. The transition check can walk the
    # Store, whose Monitor is a yield point when contended, so two gathered
    # siblings may both journal a line; that costs a duplicate record and
    # never a downgrade, since nothing is ever removed. The claim carries
    # ToolRunner's gathered dispatch (docs/concurrency.md, "parallel tools")
    # and is pinned by spec/lain/session_concurrency_spec.rb.
    #
    # A line is journaled only when the read adds lines the counted reads of
    # that version did not already cover, so a read/edit loop does not journal
    # per iteration. A counted read is on the chain or waiting in this round,
    # and any chain the new read's turn lands on holds it too. The one line a
    # replay can miss is a sibling's in the same round whose result then turns
    # out to be an error: the resumed session is refused an edit this one
    # allowed, never the reverse.
    #
    # @return [self]
    def record_read(path, lines: WHOLE_FILE, identity: FileIdentity.of(normalize(path)), tool_use_id: nil,
                    head: @reads.head)
      target = normalize(path)
      read = ReadSet::Read.checked(lines:, identity:, tool_use_id:, head:)
      transition = !@reads.covered?(target, read)
      @reads.record(target, read)
      @journal << Telemetry::SessionRead.of(target, read) if transition
      self
    end

    # The chain the next tool round runs on, and so the chain a read has to be
    # on to count. A read still waiting for its delivery belongs to a round
    # that never delivered one, and is withheld -- and journaled as withheld,
    # because a replay cannot see this moment: when the same assistant turn
    # re-runs its tools, both rounds open on one head with the same call ids,
    # and only this record keeps the first from binding to the second's
    # delivery. A round that delivered leaves nothing open, so an ordinary run
    # journals nothing here.
    #
    # @param timeline [Timeline]
    # @return [self]
    def on_chain(timeline)
      withheld(@reads.withhold_undelivered)
      @reads.move_to(timeline)
      self
    end

    # The head moved BACKWARD, so every chain-scoped projection this session
    # holds re-derives from where it now stands: the read-set, and the memory
    # view. Called by {Agent#rewind} rather than by {#on_chain}, which runs once
    # per tool round and would pay a whole-chain memory fold on every one of
    # them to answer a question only a rewind can change.
    #
    # @param timeline [Timeline] the chain as the rewind left it
    # @return [self]
    def rewound_to(timeline)
      on_chain(timeline)
      @memory.follow(timeline)
      self
    end

    # A replay's fold of {Telemetry::SessionReadWithheld}: the rounds a live
    # {#on_chain} withheld, named as `[head, call id]`.
    #
    # @param rounds [Array<Array(String, String)>]
    # @return [self]
    def withhold_rounds(rounds) = withheld(@reads.withhold(rounds))

    # Binds each call a turn answers to that turn -- only the reads whose round
    # opened on the turn's parent, the assistant turn that made the calls. A
    # provider may reuse a call id round after round (Ollama numbers each
    # response's calls from zero), and a repair answering a torn round may be
    # written long after a later round's reads, so the id alone names no round.
    # A result the model got as an error carried no file contents, so a read
    # behind it never counts.
    #
    # @param digest [String] the delivering turn's digest
    # @param parent [String] its parent: the head its round opened on
    # @param content [Array<Hash>] its blocks
    # @return [self]
    def record_delivery(digest:, parent:, content:)
      content.select { |block| block["type"] == "tool_result" }.each do |block|
        delivery = block["is_error"] ? ReadSet::Withheld : ReadSet::Delivered.new(digest)
        @reads.deliver(parent, block["tool_use_id"], delivery)
      end
      self
    end

    # Every read whose result no turn delivered is withheld: a replay's end of
    # record, or the start of the next file in a resume chain, where a round
    # with no delivery was torn before its results landed.
    #
    # @return [self]
    def withhold_undelivered = withheld(@reads.withhold_undelivered)

    # @return [Boolean] whether `path` (in any spelling) was read IN FULL on
    #   this chain -- the question the edit-before-write contracts ask, so a
    #   partial read answers false
    def read?(path)
      @reads.complete?(normalize(path))
    end

    # Bytes were withheld from the model, so it must not be trusted to rewrite
    # the file. Separate from a windowed {#record_read} because the two facts
    # arrive from different layers and only this one can arrive AFTER a whole
    # read was recorded. See {ReadSet} for why that forces a set of its own
    # rather than a retraction, and why it ignores the chain.
    #
    # Journals NO {Telemetry::SessionRead}: {SessionRecord::Replay} folds each
    # one through {#record_read}, which by construction cannot reach the masked
    # set, so a line here would replay to a read -- a record that LOOKS like
    # the mask was persisted while a resumed session permits the very write
    # the mask exists to refuse. {Middleware::RedactSecretReads} writes a
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
    # Deliberately WIDER than {#read?}: a partially read path was still read,
    # and so was one read on a chain since rewound away.
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
    # A write the open turn holds no pre-image for is marked unrecorded, so an
    # undo refuses it by name rather than guessing nothing stood there.
    #
    # `wrote:` is the bytes the tool left at the path, so a pre-image carried
    # past a torn turn can tell whether someone else has changed the path
    # since. Without it, a carried pre-image is taken as changed: dropped or
    # recaptured, which is the direction that loses no one's bytes.
    #
    # @return [self]
    def record_write(path, wrote: nil)
      target = normalize(path)
      @writes << target
      @pre_images.written(target, wrote)
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

    # Opens a turn's pre-images. Only an open turn captures: a session whose
    # tools run with no delivery behind them never takes a snapshot, so
    # holding the bytes would be memory spent on nothing.
    #
    # A set no snapshot settled stays open and carries into the next turn: a
    # torn turn writes no snapshot, so the next one's map spans both turns,
    # and its undo has to put back what stood before the first of them.
    #
    # @return [self]
    def open_pre_images
      @pre_images = @pre_images.opened
      self
    end

    # A snapshot has taken the open turn's pre-images; the next turn starts
    # its own.
    #
    # @return [self]
    def settle_pre_images
      @pre_images = PreImages::Closed
      self
    end

    # What `path` held before the open turn first wrote it. The block reads it
    # -- its bytes, or nil where nothing stood -- and runs only on that first
    # write, so a second write in the turn neither re-reads the file nor takes
    # the first write's bytes for the pre-image.
    #
    # Called BEFORE the write, and not journaled, for {#record_write}'s reason:
    # the bytes belong to the in-memory snapshot record.
    #
    # @yieldreturn [String, nil]
    # @return [self]
    def record_pre_image(path, &read)
      @pre_images.capture(normalize(path), &read)
      self
    end

    # @return [Hash{String => PreImage, PreImage::Unrecorded}] every path the
    #   open turn wrote, by normalized path
    def pre_images = @pre_images.to_h

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
      @plan_step_completions += 1 if @plan_step_completed
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

    # How many {#write_todos} calls have raised the completed count, ever: the
    # count {#plan_step_completed?} is the level of. Monotone, so a consumer
    # can say how far it has consumed with one Integer -- a compaction records
    # this count on the cut it commits, and a step is pending while this
    # exceeds the latest such record.
    #
    # @return [Integer]
    attr_reader :plan_step_completions

    # Remember a committed compaction advance, and journal it. The Timeline is
    # never rewritten by a compaction; what a compaction commits is POLICY
    # state, and it lives here beside the pin-set for the pin-set's reason --
    # it is journaled and {SessionRecord::Replay} folds it back, so a resumed
    # session renders the replacement a recorded one did rather than asking a
    # model for it again.
    #
    # Every cut is kept, in commit order, and none is ever retracted: which cut
    # holds on a given chain is the compaction source's question, asked of
    # {#compaction_cuts}. A cut carries only what its advance newly collapsed
    # and names its parent by address, so a cut whose parent was never
    # recorded -- a truncated or hand-edited record -- is refused HERE, where
    # it is folded, rather than rendered as a seam with a hole in it.
    #
    # @param cut [Telemetry::CompactionCut]
    # @return [self]
    # @raise [UnrecordedParent] when `cut.parent` names no cut recorded here
    def record_compaction_cut(cut)
      unless cut.parent.nil? || @cuts_by_address.key?(cut.parent)
        raise UnrecordedParent,
              "compaction_cut at #{cut.digest} names parent #{cut.parent}, which is not a cut this session recorded"
      end

      @cuts_by_address[cut.address] = cut
      @compaction_cuts = [*@compaction_cuts, cut].freeze
      @journal << cut
      self
    end

    # @return [Array<Telemetry::CompactionCut>] every cut, oldest first
    attr_reader :compaction_cuts

    # @param address [String] a recorded cut's {Telemetry::CompactionCut#address}
    # @return [Telemetry::CompactionCut]
    # @raise [KeyError] when no cut was recorded at that address
    def compaction_cut(address) = @cuts_by_address.fetch(address)

    # What the Agent renders into the Workspace tail each turn. Never a Timeline
    # entry, so rewinding or forking the Timeline has no bearing on either
    # block.
    #
    # @return [Array<String>]
    def reminders
      (todo_reminders + manifest_reminders + @scope.reminders).freeze
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

    # Point the manifest at a memory source. The RESUMED case needs it for
    # {#journals_into}'s reason: {SessionRecord::Replay} builds this Session
    # over the view it folded out of the record, and the run that resumes it
    # re-opens that view on the project's store
    # ({Memory::ProjectStore#resumed}) -- so the manifest must follow, or it
    # renders a snapshot the memory tools no longer write into.
    #
    # Unguarded where {#journals_into} refuses a second call, because the two
    # are different risks: a second journal splits a record across two files
    # silently, where a second view is what a resume legitimately is.
    #
    # @param memory [#index, #follow] the run's memory view; {#rewound_to} sends
    #   it `#follow`, so a collaborator standing in for one owes both messages
    # @return [self]
    def watch_memory(memory)
      @memory = memory
      @manifest_root = nil
      @manifest_reminders = [].freeze
      self
    end

    # The scope of a session nothing confines: its tools resolve and run where
    # it was built, and a child it spawns leases as the run's isolation says.
    module Unconfined
      def self.env_over(home) = home

      def self.holds?(_path) = true

      def self.reminders = [].freeze

      def self.lend(leases) = leases
    end

    # The scope of a session confined to one directory -- a spike worktree or a
    # scratch directory -- which its environment names as its checkout.
    #
    # A path is held when it really lands under the root: the real path of its
    # longest existing prefix, with the part not on disk yet appended, since
    # the kernel follows every link the path crosses. A dangling link names a
    # target that can be made anywhere later, so it is not held.
    #
    # A child spawned under it is LENT the environment in place, since a lease
    # of its own would be a second checkout the spike never reads. One lend per
    # spawn rather than one shared: a nested spawn waits inside its parent's,
    # and a shared lend would have it wait on itself. A checkout its caller
    # already lent on purpose -- a critic reading a reviewed head -- is what
    # that child is for, so it keeps it.
    class Confined
      attr_reader :worker_env, :root, :reminders

      # @param worker_env [WorkerEnv] the scope's environment, naming its root
      #   as the checkout
      # @param reminder [String] what the model is told about where it is
      # @raise [SystemCallError] when the root is not on disk
      def initialize(worker_env:, reminder:)
        @worker_env = worker_env
        @root = File.realpath(worker_env.checkout)
        @reminders = [reminder.dup.freeze].freeze
        freeze
      end

      def env_over(_home) = worker_env

      # Resolved against the scope's own environment and cleaned first, as
      # {WorkerEnv#resolve} places a path before a tool opens it. A location
      # that cannot be resolved at all is not held.
      #
      # @param path [String, nil] as a call wrote it; nil is the scope's cwd
      def holds?(path)
        landed = Lain::Landing.of(worker_env.resolve(path), cwd: root).first
        landed == root || landed.start_with?(File.join(root, ""))
      rescue SystemCallError, ArgumentError, TypeError, Lain::Landing::Dangling
        false
      end

      # @param leases [Isolation::Leases, Isolation::Leases::InPlace] the
      #   run's, whose lane the child keeps, or a checkout already lent
      # @return [Isolation::Leases::InPlace]
      def lend(leases)
        return leases if leases.is_a?(Isolation::Leases::InPlace)

        Isolation::Leases::InPlace.new(worker_env:, lane: leases.lane)
      end
    end

    FileIdentity = Data.define(:device, :inode, :size, :mtime)

    # Which version of a file a read saw. A stat rather than a hash, because a
    # window exists so that the file is NOT read whole: hashing it per window
    # would cost exactly the read the window avoids. The price is named: a
    # same-size rewrite in place, landing inside one tick of the filesystem's
    # timestamp clock, keeps the same identity.
    #
    # A path that cannot be stat'd has the one {ABSENT} identity. Reopened,
    # rather than documented on the Data.define above, so that constant lands
    # on FileIdentity itself and YARD keeps this one docstring.
    class FileIdentity
      # @param stat [File::Stat]
      # @return [FileIdentity]
      def self.from_stat(stat)
        new(device: stat.dev, inode: stat.ino, size: stat.size,
            mtime: (stat.mtime.tv_sec * 1_000_000_000) + stat.mtime.tv_nsec)
      end

      # @param path [String] an absolute path
      # @return [FileIdentity]
      def self.of(path)
        from_stat(File.stat(path))
      rescue SystemCallError
        ABSENT
      end

      ABSENT = new(device: nil, inode: nil, size: nil, mtime: nil)
    end

    PreImage = Data.define(:bytes)

    # What a path held before a turn first wrote it: its bytes, or nil for a
    # path with nothing there, which an undo puts back by deleting.
    #
    # Reopened, rather than documented on the Data.define above, so the module
    # below lands on PreImage itself and YARD keeps this one docstring.
    class PreImage
      def initialize(bytes:) = super(bytes: bytes&.b&.freeze)

      def recorded? = true

      # Whether disk no longer holds these bytes at `path`.
      def replaced?(path) = bytes != (File.file?(path) ? File.binread(path) : nil)

      # A path the turn wrote with no pre-image captured first -- a tool that
      # records its write without reading what it replaced. Distinct from an
      # absent path: nothing says whether a human's file stood there.
      module Unrecorded
        def self.recorded? = false

        def self.replaced?(_path) = false

        def self.bytes = nil
      end
    end

    # One turn's pre-images, by normalized path. The first answer for a path
    # wins: a later write in the turn, or the write's own record after its
    # capture, never replaces what stood there before the turn reached it.
    #
    # A set reopened without a settle carries its pre-images into the next
    # turn. A carried path whose disk no longer holds what lain last wrote there
    # was changed by someone else -- a hand fix after an interrupt -- so its
    # pre-image no longer stands before the next change: a capture replaces
    # it, and a turn that does not write the path again leaves it out.
    class PreImages
      def initialize
        @images = {}
        @left = {}
        @carried = Set.new
      end

      def opened
        @carried.merge(@images.keys)
        self
      end

      # The read inside the block can suspend the fiber between the check and
      # the assignment. That is safe only while every capturing tool runs
      # alone, as write_file and edit_file do by not being parallel_safe?.
      def capture(path)
        forget(path) if stale?(path)
        @images[path] ||= PreImage.new(bytes: yield)
      end

      def written(path, bytes)
        @images[path] ||= PreImage::Unrecorded
        @left[path] = bytes && digest(bytes)
        @carried.delete(path)
      end

      def to_h = @images.reject { |path, _| stale?(path) }.freeze

      private

      def stale?(path) = @carried.include?(path) && @left[path] != on_disk(path)

      def forget(path)
        @images.delete(path)
        @carried.delete(path)
      end

      def on_disk(path) = File.file?(path) ? digest(File.binread(path)) : nil

      def digest(bytes) = Workspace::Snapshot::Blob.new(bytes:).digest

      # No turn open: nothing is captured, and nothing is held.
      module Closed
        def self.opened = PreImages.new

        def self.capture(_path) = nil

        def self.written(_path, _bytes) = nil

        def self.to_h = {}.freeze
      end
    end

    private

    def withheld(rounds)
      @journal << Telemetry::SessionReadWithheld.new(rounds:) unless rounds.empty?
      self
    end

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

    # Which files were read, on which chain, and which of those were read WHOLE.
    #
    # Add-only, and that is the whole design: a read, a delivery and a mask are
    # only ever recorded, never removed, so a sibling fiber cannot race a
    # complete read backwards into a partial one. What moves is the CHAIN a
    # read is counted against: a rewind leaves every read in place and stops
    # counting the ones whose delivering turn it left behind.
    #
    # Masking is kept apart and ignores the chain. {Tools::ReadFile} records a
    # whole read BELOW the middleware that decides to mask, so the read is
    # already here before masking is decided, and only
    # {Middleware::RedactSecretReads}, one layer above, knows bytes were
    # withheld. A masked path stays un-editable for the rest of the run, on
    # every chain and after any later read: over-strict on purpose, and NOT to
    # be fixed with a delete.
    #
    # Members arrive ALREADY normalized -- path identity belongs to {Session},
    # which owns the worker cwd.
    class ReadSet
      Read = Data.define(:lines, :identity, :tool_use_id, :head)

      # One read: the lines it covered, the version of the file it saw, and
      # the call whose result carried it, named by id and by the chain head its
      # round opened on. Built through {.checked}, whose
      # strict checks come ahead of any mutation, so a caller that rescues is
      # never left holding live state more permissive than what replays.
      class Read
        # @return [Read]
        # @raise [ArgumentError] for a span that names no lines, or a call id
        #   or head that is not a String
        def self.checked(lines:, identity:, tool_use_id:, head:)
          unless span?(lines)
            raise ArgumentError, "lines must be a Range of line numbers from 1, first..last or first.., " \
                                 "got #{lines.inspect}"
          end
          name, value = { tool_use_id:, head: }.find { |_, named| !(named.nil? || named.is_a?(String)) }
          raise ArgumentError, "#{name} must be a String or nil, got #{value.inspect}" if name

          new(lines:, identity:, tool_use_id:, head:)
        end

        def self.span?(lines)
          lines.is_a?(Range) && !lines.exclude_end? && lines.begin.is_a?(Integer) && lines.begin >= 1 &&
            (lines.end.nil? || (lines.end.is_a?(Integer) && lines.end >= lines.begin))
        end
        private_class_method :span?
      end

      # A read whose round has not delivered yet, or that no call carried: it
      # counts, since nothing has yet said the model did not see it.
      module Pending
        def self.counts_on?(_chain) = true
      end

      # A read whose result never reached the model.
      module Withheld
        def self.counts_on?(_chain) = false
      end

      # A read delivered by the turn at `digest`.
      Delivered = Data.define(:digest) do
        def counts_on?(chain) = chain.include?(digest)
      end

      # Which turns a head's chain holds, walked once per head rather than per
      # question. A head that descends from the last one walked is walked only
      # back to it; any other head -- a rewind, a checkout -- is walked whole.
      class Chain
        def initialize
          @timeline = Timeline.empty
          @walked_to = nil
          @digests = Set.new
        end

        def move_to(timeline) = @timeline = timeline

        def head = @timeline.head_digest

        def include?(digest)
          catch_up unless @timeline.head_digest == @walked_to
          @digests.include?(digest)
        end

        private

        def catch_up
          fresh = @timeline.ancestors.take_while { |turn| turn.digest != @walked_to }
          @digests = Set.new unless !fresh.empty? && fresh.last.parent == @walked_to
          @digests.merge(fresh.map(&:digest))
          @walked_to = @timeline.head_digest
        end
      end

      # Rounds are numbered, and an open one is found by the head it opened on
      # together with the call id: {Session#record_delivery} says why the id
      # alone is not enough.
      def initialize
        @reads = {}
        @masked = Set.new
        @rounds = [Pending]
        @open = {}
        @chain = Chain.new
      end

      # @param path [String] an already-normalized absolute path
      # @param read [Read]
      # @return [self]
      def record(path, read)
        (@reads[path] ||= []) << [read, round_of(read)]
        self
      end

      # A masked path answers as read in part on its own, with or without a
      # read beside it: a masked read IS a read, and must never answer as one
      # that did not happen.
      #
      # @param path [String] an already-normalized absolute path
      # @return [self]
      def mask(path)
        @masked << path
        self
      end

      # @return [self]
      def deliver(head, tool_use_id, delivery)
        round = @open.delete([head, tool_use_id])
        @rounds[round] = delivery unless round.nil?
        self
      end

      # @return [self]
      # @return [Array<Array(String, String)>] the `[head, call id]` of every
      #   round this withheld
      def withhold_undelivered = withhold(@open.keys)

      # @param keys [Array<Array(String, String)>] `[head, call id]` pairs
      # @return [Array<Array(String, String)>] those that were open, now withheld
      def withhold(keys)
        keys.select { |key| @open.key?(key) }.each { |key| @rounds[@open.delete(key)] = Withheld }
      end

      # @return [self]
      def move_to(timeline)
        @chain.move_to(timeline)
        self
      end

      # @return [String, nil] the head of the chain reads are counted against
      def head = @chain.head

      # Whole when the counted reads of one version cover every line, and
      # nothing was withheld.
      #
      # @return [Boolean]
      def complete?(path)
        !masked?(path) && counted(path).group_by(&:identity).any? { |_, same| covering?(same, WHOLE_FILE) }
      end

      # Read, but not wholly seen. A caller asking this wants "is there more of
      # this file the model has not seen", for which the two causes are the same
      # fact; {#masked?} tells them apart.
      #
      # @return [Boolean]
      def partial?(path) = masked?(path) || (counted(path).any? && !complete?(path))

      # @return [Boolean]
      def masked?(path) = @masked.include?(path)

      # Whether the counted reads of `read`'s version already cover its lines.
      #
      # @return [Boolean]
      def covered?(path, read)
        covering?(counted(path).select { |seen| seen.identity == read.identity }, read.lines)
      end

      # @return [Array<String>] every path recorded, on any chain, sorted
      def paths = (@reads.keys | @masked.to_a).sort.freeze

      private

      def round_of(read)
        return 0 if read.tool_use_id.nil?

        @open[[read.head, read.tool_use_id]] ||= (@rounds << Pending).size - 1
      end

      def counted(path)
        @reads.fetch(path, []).filter_map { |read, round| read if @rounds[round].counts_on?(@chain) }
      end

      # Sorted by first line, a span extends the covered run only when it
      # starts inside or just past it; `nil`'s end-of-file reach is infinite.
      def covering?(reads, lines)
        reach = reads.map(&:lines).sort_by(&:begin).inject(lines.begin - 1) do |reached, span|
          span.begin <= reached + 1 ? [reached, span.end || Float::INFINITY].max : reached
        end
        reach >= (lines.end || Float::INFINITY)
      end
    end

    # The no-op Session, mirroring {Channel::Null} and {Sink::Null}, so no tool
    # ever writes an `if session` guard. A single shared frozen instance: it has
    # no state to keep, and nothing to journal either.
    class Null
      # @return [self]
      def record_read(_path, **) = self

      # @return [self]
      def on_chain(_timeline) = self

      # @return [self]
      def rewound_to(_timeline) = self

      # @return [self]
      def record_delivery(**) = self

      # @return [self]
      def withhold_undelivered = self

      # @return [self]
      def withhold_rounds(_rounds) = self

      # @return [self]
      def record_masked_read(_path) = self

      # Takes the real one's `wrote:` and holds nothing of it.
      #
      # @return [self]
      def record_write(_path, **) = self

      # @return [self]
      def open_pre_images = self

      # @return [self]
      def settle_pre_images = self

      # The block is never run: nothing here would hold what it read.
      #
      # @return [self]
      def record_pre_image(_path) = self

      # @return [Hash]
      def pre_images = {}.freeze

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

      # @return [Integer]
      def plan_step_completions = 0

      # @return [self]
      def record_compaction_cut(_cut) = self

      # @return [Array]
      def compaction_cuts = [].freeze

      # Nothing is ever recorded here, so no address can name a cut.
      #
      # @raise [KeyError]
      def compaction_cut(address) = raise(KeyError, "no compaction cut at #{address}")

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

      # @return [Unconfined]
      def scope = Unconfined

      INSTANCE = new.freeze

      # @return [Null] the shared instance
      def self.instance = INSTANCE
    end
  end
end
