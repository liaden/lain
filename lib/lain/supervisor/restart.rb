# frozen_string_literal: true

module Lain
  class Supervisor
    # Replay-restart: a killed actor resumed from its own session record,
    # through {Bench::Session::Loader}'s verified re-commit -- never a second
    # replay implementation. Zero provider calls occur here: replay is
    # re-commit, restore is blob fetch, and the revival block only SEEDS an
    # agent at the replayed head, so {CLI::Resume}'s no-respend property holds
    # on the supervision axis too.
    #
    # == The workspace-blob sidecar
    #
    # The Store is in-memory, so a snapshot's BLOB bytes die with the killed
    # process: the :snapshot event journals, but its payload only NAMES each
    # file's bytes by content address. {JournalBlobs} closes that on the
    # JOURNAL side rather than in an on-disk blob directory, so the session
    # file IS the whole checkpoint -- one artifact to copy, nothing to desync
    # from it. A pre-sidecar journal still replays; only its files are
    # unrestorable, and that is a loud notice ({CLI::Resume}'s idiom).
    #
    # == Identity
    #
    # A restart never looks an actor up by address, and the reason is in this
    # class: {Revived} is built with `address: head` -- the replayed HEAD
    # digest, because a revived actor has no :spawn event of its own -- so two
    # restarts of one recording carry the same address by construction, with no
    # spawn writer in it at all. (Registry addresses that ARE :spawn digests now
    # carry a per-adoption ordinal, but its scope is one writer, so those can
    # still collide across a second writer or a resume.) A restart's identity is
    # the RECORD handed in, and what it creates is a NEW adoption;
    # the dead registration stays in the registry as the honest history of the
    # first life.
    class Restart
      # A revival that does not stand at the replayed head would register an
      # actor whose registry row lies about its checkpoint -- refused INSIDE
      # the adopted task, before the registration append lands.
      class Diverged < Error; end

      # What one restart did. `snapshot` is nil when the record holds none: a
      # read-only life snapshots nothing, so nil is a value here.
      Result = Data.define(:actor, :timeline, :snapshot, :restored, :notices) do
        def initialize(actor:, timeline:, snapshot:, restored:, notices:)
          super(actor:, timeline:, snapshot:, restored:, notices: notices.freeze)
        end
      end

      # The no-restore value ({Workspace::Restore::Result}'s own shape, empty):
      # a real answer for "what landed on disk", never a nil a caller must guard.
      NOTHING_RESTORED = Workspace::Restore::Result.new(written: [].freeze, deleted: [].freeze)

      # @param entries [Enumerable<Hash, String>] the killed actor's session
      #   record ({Journal.parse}'s duck), materialized ONCE: both the Loader
      #   and the blob re-put walk it, and a one-shot enumerator (an IO's
      #   each_line) would silently replay empty the second time
      # @param supervisor [Supervisor] the running reactor the revived actor is
      #   adopted under; {Supervisor#adopt} refuses loudly when it is not
      # @param journal [#<<] where the "restarted" record lands
      # @param root [String] where the snapshot's root-relative keys restore --
      #   the recorded root is provenance, never authority
      # @param force [Boolean] waive {Workspace::Restore}'s dirty check, so
      #   post-crash out-of-band bytes are clobbered instead of refused
      def initialize(entries:, supervisor:, journal:, root: Dir.pwd, force: false)
        @records = Journal.records(entries).to_a
        @supervisor = supervisor
        @journal = journal
        @root = root
        @force = force
      end

      # Replay, restore, adopt, record. The block is the revival seam: provider,
      # toolset and context are the CALLER's wiring because none of the three
      # survive a journal. It must return an agent standing at the replayed head
      # ({Diverged}) -- seed it with `recording.timeline`.
      #
      # A fresh isolation lease is RE-ACQUIRED here, so a restarted worker gets
      # an equivalent isolated environment rather than inheriting the dead
      # worker's abandoned one; the block takes that lease's {WorkerEnv} as its
      # second yield arg. A failed re-acquire raises out of {Supervisor#adopt},
      # failing the restart before any worker is revived -- never a worker on a
      # leaked environment.
      #
      # @param role [String] the registry label the new adoption records
      # @yieldparam recording [Bench::Session::Recording]
      # @yieldparam worker_env [WorkerEnv] the re-acquired lease's cwd/env
      # @yieldreturn [Agent] an agent seeded with the replayed timeline
      # @return [Result]
      # @raise [Bench::Session::Corrupt, Diverged, Workspace::Restore::Dirty]
      def call(role:, &revive)
        raise ArgumentError, "a revival block is required: it rebuilds the Agent over the replayed timeline" if
          revive.nil?

        recording = replay(role)
        notices = open_notices(recording)
        restore_blobs(recording.timeline.store)
        snapshot = latest_snapshot(recording)
        restored = restore(recording, snapshot, notices)
        actor = adopt(role, recording, revive)
        record(role, recording, snapshot)
        Result.new(actor:, timeline: recording.timeline, snapshot: snapshot&.digest, restored:, notices:)
      end

      private

      def record(role, recording, snapshot)
        @journal << Restarted.new(role:, head: recording.timeline.head_digest, snapshot: snapshot&.digest)
      end

      # THE session-resume code path: {Bench::Session::Loader}'s verified replay
      # -- re-commit plus digest check, no provider anywhere.
      #
      # The refusal is ATTRIBUTED here rather than left as whatever the fold
      # happened to raise: a supervisor bringing several roles back otherwise
      # gets n identical complaints with nothing to tell them apart, and one
      # damage shape reached this path as the Store's own private message, with
      # no role and no record on it. The MissingObject arm is defensive now that
      # both folds shape-check the causal edge, and kept for the reason
      # {CLI::Resume#fork} records.
      #
      # It stays a RAISE, deliberately. Whether a failed restart is retried or
      # abandoned is the SUPERVISOR's policy: a refused restart registers
      # nothing, leaves the reactor running, and lets the next attempt proceed.
      # Folding it into a Result would decide that above this seam.
      def replay(role)
        Bench::Session::Loader.new(@records).recording
      rescue Bench::Session::Corrupt, Store::MissingObject => e
        raise Bench::Session::Corrupt, "cannot restart #{role.inspect} from its session record: #{e.message}"
      end

      # A killed actor's record is OPEN by construction (no session_closed, no
      # farewell) -- said out loud, {CLI::Resume#open_notice}'s idiom.
      def open_notices(recording)
        return [] unless recording.open?

        ["the session record was not gracefully closed (the kill); restarting from its last verified turn"]
      end

      # The sidecar re-put: every recorded blob back into the replayed Store,
      # verified by re-derivation exactly as the Loader verifies a turn, so a
      # tampered record cannot load quietly wrong. {Store#put} dedups.
      def restore_blobs(store)
        of_type("workspace_blob").each do |record|
          blob = Workspace::Snapshot::Blob.new(bytes: record.fetch("bytes_b64").unpack1("m0"))
          verify_blob!(blob, record.fetch("digest"))
          store.put(blob)
        end
      end

      def verify_blob!(blob, recorded)
        return if blob.digest == recorded

        raise Bench::Session::Corrupt, "workspace_blob recorded as #{recorded} re-derives to #{blob.digest}; " \
                                       "its bytes no longer match their content address"
      end

      def of_type(type) = @records.select { |record| record["type"].to_s == type }

      # The last :snapshot among the Loader's own re-put (already
      # digest-verified) message events, or nil for a read-only life.
      def latest_snapshot(recording)
        recording.messages.reverse.find { |event| event.kind == :snapshot }
      end

      # Driven at the log's last snapshot; EscapesRoot/Dirty/PartialApply
      # semantics stay {Workspace::Restore}'s. Skipped -- loudly -- when the
      # record cannot back the snapshot with bytes (a pre-sidecar journal).
      def restore(recording, snapshot, notices)
        return NOTHING_RESTORED if snapshot.nil?

        store = recording.timeline.store
        missing = snapshot.body.fetch("files").values.reject { |digest| store.key?(digest) }
        return blob_gap(snapshot, missing, notices) unless missing.empty?

        Workspace::Restore.new(projection: Event::Projection.new(recording.messages), store:, root: @root)
                          .restore(turn: Workspace::Restore::ANY_TURN, force: @force)
      end

      # A pre-sidecar journal, or a torn one: the snapshot names bytes the record
      # does not carry. Replay proceeds -- the conversation is whole -- but the
      # files are honestly not restorable.
      def blob_gap(snapshot, missing, notices)
        notices << "snapshot #{snapshot.digest} names #{missing.size} file blob(s) the record does not " \
                   "carry (a journal from before workspace_blob records?); files were NOT restored"
        NOTHING_RESTORED
      end

      # The head guard runs INSIDE the adopted task, before {Supervisor#adopt}'s
      # registration append -- so a diverged revival registers nothing.
      # RETENTION: a restart is a NEW adoption under a NEW worker_id, so the
      # same-id reap never fires across restarts; what keeps N crash-restarts
      # from leaving N stale worktrees standing is {Supervisor#reap_crashed},
      # which SURRENDERS the dead worker's lease -- its commits anchored under
      # refs/lain/worker/ first -- from inside the adoption below. The dead
      # registration stays as honest history of the first life; it is its
      # abandoned checkout that goes, never its work.
      def adopt(role, recording, revive)
        head = recording.timeline.head_digest
        @supervisor.adopt(role:) do |worker_env|
          Revived.new(agent: at_head!(revive.call(recording, worker_env), head), address: head)
        end
      end

      def at_head!(agent, head)
        return agent if agent.timeline.head_digest == head

        raise Diverged, "revived agent stands at #{agent.timeline.head_digest.inspect}, not the replayed head " \
                        "#{head.inspect}; seed it with recording.timeline"
      end
    end
  end

  class Supervisor
    # Reopened rather than nested mid-body -- supervisor.rb's own idiom: each of
    # these is its own responsibility, and the split keeps every class body
    # within Metrics/ClassLength instead of loosening it.

    class Restart
      # The write side of the sidecar: an {Event::ChainWriter} observer
      # decorator on the SAME seam the session scribe occupies. A :snapshot
      # event's payload names each file's bytes by digest; this journals those
      # bytes -- once per content address -- BEFORE forwarding the event, so a
      # file-order reader meets bytes before the record that names them
      # ({Store#put}'s payload-then-envelope discipline, on disk).
      #
      # Stateful like {Workspace::Snapshot}'s last-files skip, and for the
      # mirrored reason: "which blobs did this writer already journal" is
      # writer state, not log content. The dedup set is also what keeps the
      # ChainWriter observer -- which fires even when the Store dedups a re-put
      # -- from doubling blob records.
      #
      # == Journal growth, measured
      #
      # Dedup collapses only bytes that repeat VERBATIM across snapshots: an
      # UNCHANGED file rides both snapshot maps yet journals once, but every
      # EDIT of a large file re-journals the WHOLE file, because a one-byte
      # change is a new content address. Growth is therefore file-size x
      # edit-count, not edit-size x edit-count -- 20 one-byte edits of a 64KiB
      # file measured as 20 full ~85KiB base64 blobs (~1.67 MiB, ~56% of that
      # journal). Accepted while the demo's files are small; the refinement is
      # a delta or size-threshold scheme, never trimming the record -- the same
      # content-addressed dedupe posture {Telemetry::RequestSent}'s own O(n^2)
      # note takes.
      class JournalBlobs
        # @param journal [#<<] where workspace_blob records land
        # @param store [Store] resolves the snapshot's blob digests to bytes;
        #   must be the store the snapshot writer puts blobs into
        # @param observer [#call] the next observer in the chain (the scribe)
        def initialize(journal:, store:, observer: Event::ChainWriter::Null.new)
          @journal = journal
          @store = store
          @observer = observer
          @written = Set.new
        end

        # A raise here propagates like the scribe's own (the seam's pinned
        # contract): a blob that could not be journaled is silent checkpoint
        # loss, the failure class replay-restart exists to close.
        #
        # @param event [Event]
        # @return [self]
        def call(event)
          journal_blobs(event) if event.kind == :snapshot
          @observer.call(event)
          self
        end

        private

        def journal_blobs(event)
          fresh = event.body.fetch("files").values.uniq.reject { |digest| @written.include?(digest) }
          fresh.each do |digest|
            @journal << WorkspaceBlob.from(@store.fetch(digest))
            @written.add(digest)
          end
        end
      end
    end
  end

  class Supervisor
    class Restart
      # One file's bytes, journaled beside their content address so the
      # checkpoint survives process death. Base64 (`pack("m0")`: strict, no
      # newlines) because the Journal is NDJSON and file bytes are arbitrary
      # binary -- JSON cannot carry them raw and the line must stay single.
      WorkspaceBlob = Data.define(:digest, :bytes_b64) do
        include Telemetry::Journalable

        # @param blob [Workspace::Snapshot::Blob]
        def self.from(blob)
          new(digest: blob.digest, bytes_b64: [blob.bytes].pack("m0"))
        end

        def initialize(digest:, bytes_b64:)
          super(digest: digest.dup.freeze, bytes_b64: bytes_b64.dup.freeze)
        end

        def bytes = bytes_b64.unpack1("m0")
      end

      # The restart's own record. `snapshot` is nil for a read-only life (nil is
      # a value here, {Telemetry::MemoryRoot}'s idiom).
      Restarted = Data.define(:role, :head, :snapshot) do
        include Telemetry::Journalable

        def initialize(role:, head:, snapshot:)
          super(role: role.dup.freeze, head: head&.dup&.freeze, snapshot: snapshot&.dup&.freeze)
        end
      end
    end
  end

  class Supervisor
    class Restart
      # The revived actor's registry handle: born SETTLED at the checkpoint.
      # Replay awaits nothing and re-spends nothing, so there is no in-flight
      # turn to park a fiber over. Answers the whole
      # {Supervisor::Registration} duck, so the registry, the drain and
      # {Supervisor#stop} treat it exactly like a live {Tools::Subagent::Actor}.
      #
      # `address` is the replayed head digest -- content-addressed and stable
      # like a :spawn digest, and honest: a revived actor has no :spawn event
      # of its own, so its name is the checkpoint it stands at.
      class Revived
        # A revived actor holds no {Tools::Subagent::Lineage}, so it cannot
        # write the attributed :message a tell is -- refused namedly rather
        # than surfacing as a bare NoMethodError.
        class Unaddressed < Error; end

        attr_reader :agent, :address

        def initialize(agent:, address:)
          @agent = agent
          @address = address
          @stopped = false
        end

        def timeline = @agent.timeline

        def session = @agent.session

        # The checkpoint is a settled state by construction.
        def settle = self

        # The tools the first life was granted are not in its record, so a
        # retirement's self-sync asks nobody and takes the work as it stands.
        def worker = Isolation::SelfSync::Unaskable

        def stopped? = @stopped

        def dead? = @stopped

        # Nothing to cancel -- no fiber runs -- so stopping is the registry
        # fact alone. Idempotent, like {Tools::Subagent::Actor#stop}.
        def stop
          @stopped = true
          self
        end

        def tell(_text)
          raise Unaddressed, "a revived actor holds no lineage to attribute a message through; " \
                             "continue it via its agent (Revived#agent) instead"
        end
      end
    end
  end
end
