# frozen_string_literal: true

module Lain
  class Supervisor
    # Replay-restart (W4, OM-6's flagship): a killed actor resumed from its own
    # session record. Supervision-as-replay IS M2 session resume -- the record
    # replays through {Bench::Session::Loader}'s verified re-commit (every turn
    # re-derives its content address against the recorded one; never a second
    # replay implementation), the workspace comes back through W2's
    # {Workspace::Restore} from the LAST recorded :snapshot, and the revived
    # actor is adopted under the {Supervisor}. Zero provider calls occur on
    # this path: replay is re-commit, restore is blob fetch, and the revival
    # block only SEEDS an agent at the replayed head -- {CLI::Resume}'s
    # no-respend property, on the supervision axis.
    #
    # == The workspace-blob sidecar (closing W1's stated persistence gap)
    #
    # The Store is in-memory, so W1's snapshot BLOB bytes died with the killed
    # process: the :snapshot EVENT journals (a {Telemetry::Message} through the
    # scribe observer chain) but its payload only NAMES each file's bytes by
    # content address. {JournalBlobs} closes that gap on the JOURNAL side --
    # one additive "workspace_blob" record per blob, base64 bytes beside their
    # digest, dedup'd by content address -- chosen over an on-disk blob
    # directory because the session file then IS the whole checkpoint: one
    # artifact to copy or ship, nothing to desync from it. The Loader stays
    # untouched: {#call} re-puts the sidecar records into the replayed Store
    # itself, so an old journal (no blob records) still replays -- its files
    # just are not restorable, and that is a loud notice ({CLI::Resume}'s
    # idiom), never a silent no-op.
    #
    # == Identity
    #
    # A restart never looks an actor up by address: registry addresses are
    # :spawn digests and legitimately collide for identical spawns (the
    # registry's own comment). The identity of a restart is the RECORD -- the
    # entries handed in -- and what it creates is a NEW adoption under the
    # caller's role; the dead registration, if the supervisor still holds one,
    # stays in the registry as the honest history of the first life.
    class Restart
      # A revival that does not stand at the replayed head would register an
      # actor whose registry row lies about its checkpoint -- refused INSIDE
      # the adopted task, before the registration append lands.
      class Diverged < Error; end

      # What one restart did: the adopted actor, the replayed timeline, the
      # restored :snapshot's digest (nil when the record holds none -- a
      # read-only life snapshots nothing, so nil is a value here), the
      # restore's written/deleted record, and the notices a frontend renders.
      Result = Data.define(:actor, :timeline, :snapshot, :restored, :notices) do
        def initialize(actor:, timeline:, snapshot:, restored:, notices:)
          super(actor:, timeline:, snapshot:, restored:, notices: notices.freeze)
        end
      end

      # The no-restore value ({Workspace::Restore::Result}'s own shape, empty)
      # -- a real answer for "what landed on disk", never a nil a caller must
      # guard.
      NOTHING_RESTORED = Workspace::Restore::Result.new(written: [].freeze, deleted: [].freeze)

      # @param entries [Enumerable<Hash, String>] the killed actor's session
      #   record in the {Journal.parse} duck -- materialized ONCE here, because
      #   both the Loader and the blob re-put walk it and a one-shot enumerator
      #   (an IO's each_line) would silently replay empty the second time
      # @param supervisor [Supervisor] the running reactor the revived actor is
      #   adopted under; {Supervisor#adopt} refuses loudly when it is not
      # @param journal [#<<] where the "restarted" record lands
      # @param root [String] where the snapshot's root-relative keys restore --
      #   the recorded root is provenance, never authority (W2's ruling)
      # @param force [Boolean] waive {Workspace::Restore}'s dirty check, so
      #   post-crash out-of-band bytes are clobbered instead of refused; never
      #   the confinement
      def initialize(entries:, supervisor:, journal:, root: Dir.pwd, force: false)
        @records = Journal.records(entries).to_a
        @supervisor = supervisor
        @journal = journal
        @root = root
        @force = force
      end

      # Replay, restore, adopt, record. The block is the revival seam: it
      # receives the verified {Bench::Session::Recording} (whose Store already
      # holds the re-put blobs) and returns the Agent to revive -- provider,
      # toolset, and context are the CALLER's wiring, exactly as at first
      # launch, because none of the three survive a journal. The agent must
      # stand at the replayed head ({Diverged}); seed it with
      # `recording.timeline`.
      #
      # A fresh isolation lease is RE-ACQUIRED here (via {Supervisor#adopt}), so
      # a restarted worker regains an equivalent isolated environment rather
      # than inheriting the dead worker's abandoned one. The block receives that
      # lease's {WorkerEnv} as its second yield arg -- seed the revived Agent's
      # Session with it so the worker's tools run under the new lease. A block
      # that ignores it (the shared-process default) is unchanged. A failed
      # re-acquire raises out of {Supervisor#adopt}, failing the restart LOUDLY
      # before any worker is revived -- never a worker on a leaked environment.
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

        recording = replay
        notices = open_notices(recording)
        restore_blobs(recording.timeline.store)
        snapshot = latest_snapshot(recording)
        restored = restore(recording, snapshot, notices)
        actor = adopt(role, recording, revive)
        record(role, recording, snapshot)
        Result.new(actor:, timeline: recording.timeline, snapshot: snapshot&.digest, restored:, notices:)
      end

      private

      # The AC's record: the restarted head and the restored snapshot, side by
      # side in one journal line.
      def record(role, recording, snapshot)
        @journal << Restarted.new(role:, head: recording.timeline.head_digest, snapshot: snapshot&.digest)
      end

      # THE M2 code path: {Bench::Session::Loader}'s verified replay over the
      # already-materialized records (its own entries duck) -- re-commit plus
      # digest check, no provider anywhere.
      def replay = Bench::Session::Loader.new(@records).recording

      # A killed actor's record is OPEN by construction (no session_closed, no
      # farewell) -- said out loud, {CLI::Resume#open_notice}'s idiom.
      def open_notices(recording)
        return [] unless recording.open?

        ["the session record was not gracefully closed (the kill); restarting from its last verified turn"]
      end

      # The sidecar re-put: every recorded blob back into the replayed Store,
      # verified by re-derivation exactly as the Loader verifies a turn --
      # {Workspace::Snapshot::Blob} recomputes its address from the bytes, so a
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

      # The checkpoint's workspace side: the last :snapshot among the Loader's
      # own re-put (already digest-verified) message events, or nil for a
      # read-only life.
      def latest_snapshot(recording)
        recording.messages.select { |event| event.kind == :snapshot }.last
      end

      # W2's restore, driven at the log's last snapshot ({Workspace::
      # Restore::ANY_TURN}); EscapesRoot/Dirty/PartialApply semantics are its,
      # untouched. Skipped -- loudly -- when the record cannot back the
      # snapshot with bytes (a pre-sidecar journal).
      def restore(recording, snapshot, notices)
        return NOTHING_RESTORED if snapshot.nil?

        store = recording.timeline.store
        missing = snapshot.body.fetch("files").values.reject { |digest| store.key?(digest) }
        return blob_gap(snapshot, missing, notices) unless missing.empty?

        Workspace::Restore.new(projection: Event::Projection.new(recording.messages), store:, root: @root)
                          .restore(turn: Workspace::Restore::ANY_TURN, force: @force)
      end

      # A journal from before the sidecar existed (or a torn one): the
      # snapshot names bytes the record does not carry. Replay proceeds -- the
      # conversation is whole -- but the files are honestly not restorable.
      def blob_gap(snapshot, missing, notices)
        notices << "snapshot #{snapshot.digest} names #{missing.size} file blob(s) the record does not " \
                   "carry (a journal from before workspace_blob records?); files were NOT restored"
        NOTHING_RESTORED
      end

      # The new registration, under the supervisor's reactor. The head guard
      # runs INSIDE the adopted task, before {Supervisor#adopt}'s registration
      # append -- so a diverged revival raises out of the adoption and
      # registers nothing.
      # RETENTION: the fresh lease this revival acquires is reclaimed at the
      # supervisor's #stop, NOT at the next restart. A restart is a NEW adoption
      # under a NEW worker_id (the supervisor allocates one per adoption), so
      # B2's same-id reap never fires across restarts -- N crash-restarts leave
      # N stale worktrees standing until #stop. This is deliberate: the dead
      # registration is honest HISTORY of the first life (see the Restart class
      # doc's "Identity" note), so its lease is not force-reclaimed under a
      # successor that never held it; #stop reclaims the whole fleet at once.
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

  # Reopened rather than nested mid-body -- supervisor.rb's own idiom: each of
  # these is its own responsibility, and the split keeps every class body
  # within Metrics/ClassLength instead of loosening it.
  class Supervisor
    class Restart
      # The write side of the sidecar: an {Event::ChainWriter} observer
      # decorator on the SAME seam the session scribe occupies, so wiring is
      # one line around the observer the exe already builds. A :snapshot
      # event's payload names each file's bytes by digest; this journals those
      # bytes -- once per content address, however many snapshots share the
      # blob -- BEFORE forwarding the event, so a file-order reader meets
      # bytes before the record that names them ({Store#put}'s
      # payload-then-envelope discipline, on disk). Every other kind passes
      # through untouched.
      #
      # Stateful like {Workspace::Snapshot}'s last-files skip, and for the
      # mirrored reason: "which blobs did this writer already journal" is
      # writer state, not log content. The dedup set is also what keeps the
      # W1 review caveat (the ChainWriter observer fires even when the Store
      # dedups a re-put) from doubling blob records.
      #
      # == Journal growth, stated honestly (review probe c)
      #
      # The Journal IS the experiment record, and its own size is
      # experiment-relevant -- so the cost of persisting blob bytes into it is
      # made visible here rather than discovered later. Dedup collapses only
      # bytes that repeat VERBATIM across snapshots: an UNCHANGED file rides
      # both snapshot maps yet journals its bytes once (spec'd), but every EDIT
      # of a large file re-journals the WHOLE file, because a one-byte change
      # is a new content address and thus a new blob. Growth is therefore
      # file-size x edit-count, not edit-size x edit-count -- probe (c)
      # measured 20 one-byte edits of a 64KiB file as 20 full ~85KiB base64
      # blobs (~1.67 MiB, ~56% of that journal). Accepted while the demo's
      # files are small; the legitimate future refinement is a delta or
      # size-threshold scheme (journal a patch against the prior blob, or skip
      # sidecar bytes past some size and accept an unrestorable file with a
      # loud notice), not trimming the record -- the same content-addressed
      # dedupe posture {Telemetry::RequestSent}'s own O(n^2) note takes.
      class JournalBlobs
        # @param journal [#<<] where workspace_blob records land -- the same
        #   session journal the scribe writes
        # @param store [Store] resolves the snapshot's blob digests to bytes;
        #   must be the store the snapshot writer puts blobs into
        # @param observer [#call] the next observer in the chain (the scribe)
        def initialize(journal:, store:, observer: Event::ChainWriter::Null.new)
          @journal = journal
          @store = store
          @observer = observer
          @written = Set.new
        end

        # The {Event::ChainWriter} observer duck. A raise here propagates like
        # the scribe's own (the seam's pinned contract): a blob that could not
        # be journaled is silent checkpoint loss, the failure class W4 exists
        # to close.
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
      # Journals as "workspace_blob".
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

      # The restart's own record: which role was revived, the head it stands
      # at, and the :snapshot restored beside it -- the two digests the AC
      # names. `snapshot` is nil for a read-only life (nil is a value here,
      # {Telemetry::MemoryRoot}'s idiom). Journals as "restarted".
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
      # turn to park a fiber over -- {#settle} answers immediately, and the
      # NEXT ask (new work, new spend) is the caller's decision, driven
      # through {#agent}. Answers the whole {Supervisor::Registration} duck
      # (address, timeline, settle, stopped?/dead?, stop), so the registry,
      # the drain, and {Supervisor#stop} treat it exactly like a live
      # {Tools::Subagent::Actor}.
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

        # The checkpoint is a settled state by construction.
        def settle = self

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
