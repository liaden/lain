# frozen_string_literal: true

require "pathname"

# Snapshot's own subtree index. Scope loads at the TOP because the class body
# below reads Scope::WriteSet::NOTE while it evaluates.
require_relative "snapshot/scope"

module Lain
  class Workspace
    # Writes the workspace's file state into the event log: one :snapshot event
    # whose payload maps each write-set path to the content address of its
    # current bytes, with the bytes themselves stored out of line as {Blob}s in
    # the same Store. {Event::Projection#workspace_at} is the read side; W2's
    # restore fetches the blobs back by digest.
    #
    # NOTE the record's lifetime: the Store is an in-memory Hash, so a snapshot
    # (event and blobs both) lives exactly as long as the process. Nothing here
    # journals -- W4 owes the scribe wiring and a journal representation for
    # blob bytes before replay-restart can restore files from the record.
    #
    # == The snapshot policy (whatever the {Scope} says, and it says so)
    #
    # Which paths get captured is the one axis of policy that is a study
    # variable, so it is an injected {Scope} object rather than a rule written
    # here: {Scope::WriteSet} is the default and sees only what structured tools
    # recorded, and a shadow-repo scope can see what `bash` did. The chosen
    # scope's own note rides every payload's "snapshot_scope" field, so the
    # record always names the policy that actually produced it.
    #
    # == Payload shape: root-relative keys, the root once as data
    #
    # File keys are relative to the workspace root; the absolute root rides the
    # payload ONCE, as data. Absolute keys would bake tmpdirs and $HOME into
    # the content-addressed file map, so the same workspace content at two
    # roots (two machines, a relocated checkout) would hash differently --
    # breaking exactly the cross-machine replay and relocated restore W2
    # freezes this format for. Relativization is LEXICAL (Pathname, no symlink
    # resolution), matching the expand_path identity the write-set itself uses;
    # a path outside the root keys by its honest ../ form rather than being
    # hidden or invented a home.
    #
    # Snapshots are additive to the DAG and invisible to render chains --
    # ask_human's idiom: causal edges only (backward, naming the turn whose
    # tools did the writing), no render_parent, so no Timeline walk, digest, or
    # prompt ever changes because a snapshot landed.
    #
    # Stateful like {Session}, not a value object: it remembers the last files
    # map it wrote so an unchanged workspace (a read-only turn, or no turn at
    # all) lands no event -- the skip that keeps "read-only turns snapshot
    # nothing" true without a per-tool dirty flag that bash could never set.
    class Snapshot
      # The default scope's note, kept under its old name because
      # {Plan::Closure} reads it as the fallback for a step that took no
      # snapshot. It delegates rather than duplicates, so the two cannot drift.
      SCOPE_NOTE = Scope::WriteSet::NOTE

      # A file's bytes as a content-addressed Store object. Parentless (no
      # Store edges), binary-safe, and addressed over the RAW bytes -- not
      # through {Canonical}, which pins UTF-8 and would refuse arbitrary file
      # content. The git-style "blob <size>\0" header domain-separates blob
      # digests from the JSON-canonical digests every other Store object uses,
      # so byte content that happens to spell a canonical dump cannot collide.
      class Blob
        include ContentAddressed

        attr_reader :bytes, :digest

        def initialize(bytes:)
          # `String#b` copies into BINARY encoding, so identical bytes address
          # identically whatever encoding the caller happened to read under.
          # The header is `.b`'d too: interpolating binary bytes into a UTF-8
          # literal raises Encoding::CompatibilityError, concatenation does not.
          @bytes = bytes.b.freeze
          @digest = -"#{Canonical::DIGEST_ALGORITHM}:#{Ext.blake3_hex("blob #{@bytes.bytesize}\0".b + @bytes)}"
          freeze
        end

        def to_s
          "#<Lain::Workspace::Snapshot::Blob #{bytes.bytesize}B #{digest[0, 19]}...>"
        end
        alias inspect to_s
      end

      # @param observer [#call] sees every :snapshot event written, the same
      #   study-bench seam {Event::ChainWriter} gives ask_human's Q/A events.
      # @param root [String] the workspace root file keys are made relative to.
      #   Defaults to the working directory at construction -- the same base
      #   `File.expand_path` resolves the Session's read/write sets against.
      # @param scope [Scope, Symbol, String] which paths to capture and the note
      #   that declares it; a scope object or a registered short name.
      def initialize(observer: Event::ChainWriter::Null.new, root: Dir.pwd, scope: Scope::WriteSet.new)
        @chain_writer = Event::ChainWriter.new(observer:)
        @root = Pathname.new(File.expand_path(root)).freeze
        @scope = Scope.resolve(scope)
        @last_files = nil
        # A difference-detecting scope needs a state to differ FROM, and this is
        # the only place that knows both the root and the moment the session
        # began. Priming here is what keeps the Symbol form of a scope usable
        # end to end: a posture names `:shadow_git` and stays inert, and turn 1
        # is still covered. A no-op for a scope with nothing to prime.
        @scope.baseline(@root)
      end

      # Snapshot the paths the {Scope} selects, given `paths`, as they stand on
      # disk, into `timeline`'s Store, causally parented to `timeline`'s head
      # turn. Blobs land first (the
      # payload's file digests must not dangle for W2's restore), then the
      # payload-then-envelope write rides {Event::ChainWriter#put}.
      #
      # Nothing NEW to say lands nothing: bytes identical to the last snapshot
      # this writer took, or a write-set that never had files, returns nil. A
      # path with no file behind it is omitted from the map, and the omission
      # is itself content: deleting one file lands a smaller map, deleting the
      # LAST file lands an EMPTY map -- a real snapshot recording total
      # deletion, never the stale silence that would let a restore resurrect
      # the file. Only an empty manifest with no snapshot history is skipped.
      #
      # @param timeline [Timeline] whose head the snapshot names as its cause
      # @param paths [Enumerable<String>] the session write-set
      # @return [Event, nil] the :snapshot event, or nil when nothing changed
      def write(timeline:, paths:)
        files = manifest(timeline.store, @scope.paths(write_set: paths, root: @root))
        return nil if skip?(files)

        @last_files = files
        @chain_writer.put(timeline, kind: :snapshot,
                                    from: Event::ChainWriter.correlation_of(timeline), to: nil,
                                    causal_parents: [timeline.head_digest].compact,
                                    body: { "root" => @root.to_s, "files" => files,
                                            "snapshot_scope" => @scope.note })
      end

      private

      # Empty-after-non-empty is NOT equal to `@last_files` and therefore
      # writes; only "nothing changed" and "never had anything" skip. The nil
      # sentinel is what distinguishes "no history" from "last snapshot was
      # (or became) empty".
      def skip?(files)
        files == @last_files || (files.empty? && @last_files.nil?)
      end

      # relative key => blob digest for every write-set file present on disk,
      # storing each blob as it is hashed. Sorted so the map cannot vary with
      # write-set recording order; {Store#put} is idempotent, so re-hashing an
      # unchanged file re-stores nothing.
      def manifest(store, paths)
        paths.sort.filter_map { |path| entry(store, path) }.to_h
      end

      # nil for a path with no regular file behind it -- including one deleted
      # BETWEEN the existence check and the read (the TOCTOU race): the rescue
      # collapses the race into the omission it raced, since omission already
      # means deletion.
      def entry(store, path)
        return nil unless File.file?(path)

        [relative(path), store.put(Blob.new(bytes: File.binread(path)))]
      rescue Errno::ENOENT
        nil
      end

      def relative(path)
        Pathname.new(path).relative_path_from(@root).to_s
      end
    end
  end
end
