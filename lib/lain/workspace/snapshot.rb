# frozen_string_literal: true

require "pathname"

# Snapshot's own subtree index. Scope loads at the TOP because the class body
# below reads Scope::WriteSet::NOTE while it evaluates.

module Lain
  class Workspace
    # Writes the workspace's file state into the event log: one :snapshot event
    # whose payload maps each write-set path to the content address of its
    # current bytes, the bytes themselves stored out of line as {Blob}s in the
    # same Store. {Event::Projection#workspace_at} is the read side, and WHICH
    # paths are captured is the injected {Scope}'s to say -- its note rides every
    # payload's "snapshot_scope", so the record names the policy that made it.
    #
    # @note The Store is an in-memory Hash, so a snapshot lives exactly as long
    #   as the process. Nothing here journals -- the scribe wiring and a journal
    #   representation for blob bytes are still owed before replay-restart can
    #   restore files from the record.
    #
    # File keys are relative to the workspace root; the absolute root rides the
    # payload ONCE, as data. Absolute keys would bake tmpdirs and $HOME into the
    # content-addressed file map, so the same content at two roots would hash
    # differently -- breaking the cross-machine replay and relocated restore this
    # format is frozen for. Relativization is LEXICAL (Pathname, no symlink
    # resolution), matching the expand_path identity the write-set uses; a path
    # outside the root keys by its honest ../ form rather than being hidden.
    #
    # Snapshots are additive to the DAG and invisible to render chains --
    # ask_human's idiom: causal edges only, no render_parent, so no Timeline
    # walk, digest, or prompt ever changes because a snapshot landed.
    #
    # Stateful like {Session}, not a value object: it remembers the last files
    # map it wrote, so an unchanged workspace lands no event without a per-tool
    # dirty flag that bash could never set.
    class Snapshot
      # {Plan::Closure} reads this as the fallback for a step that took no
      # snapshot. Delegated rather than duplicated, so the two cannot drift.
      SCOPE_NOTE = Scope::WriteSet::NOTE

      # Addressed over the RAW bytes -- not through {Canonical}, which pins UTF-8
      # and would refuse arbitrary file content. The git-style "blob <size>\0"
      # header domain-separates blob digests from the JSON-canonical digests
      # every other Store object uses, so byte content that happens to spell a
      # canonical dump cannot collide.
      class Blob
        include ContentAddressed

        attr_reader :bytes, :digest

        def initialize(bytes:)
          # `String#b` copies into BINARY, so identical bytes address identically
          # whatever encoding the caller read under. The header is `.b`'d too:
          # interpolating binary bytes into a UTF-8 literal raises
          # Encoding::CompatibilityError, concatenation does not.
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
      #   study-bench seam {Event::ChainWriter} gives ask_human's Q/A events
      # @param root [String] the workspace root file keys are made relative to;
      #   the same base `File.expand_path` resolves the Session's sets against
      # @param scope [Scope, Symbol, String] a scope object or a registered
      #   short name
      def initialize(observer: Event::ChainWriter::Null.new, root: Dir.pwd, scope: Scope::WriteSet.new)
        @chain_writer = Event::ChainWriter.new(observer:)
        @root = Pathname.new(File.expand_path(root)).freeze
        @scope = Scope.resolve(scope)
        @last_files = nil
        # A difference-detecting scope needs a state to differ FROM, and this is
        # the only place knowing both the root and the moment the session began
        # -- so a posture may name `:shadow_git`, stay inert, and still cover
        # turn 1.
        @scope.baseline(@root)
      end

      # Blobs land first -- the payload's file digests must not dangle for a
      # restore -- then the payload-then-envelope write rides
      # {Event::ChainWriter#put}.
      #
      # A path with no file behind it is omitted, and the omission is itself
      # content: deleting the LAST file lands an EMPTY map, a real snapshot
      # recording total deletion rather than the stale silence that would let a
      # restore resurrect the file.
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

      # Restages what the next turn is measured from: called just before a
      # turn's tools run, so the turn's delta holds the turn and nothing the
      # human did before it.
      #
      # @return [self]
      def prime
        @scope.baseline(@root)
        self
      end

      # The trees the last prime and the last write staged, or the scope's
      # NoTrees.
      def pair = @scope.pair(@root)

      # What disk holds now, after something other than a write moved it (an
      # undo): the next write is measured against this, not stale memory.
      #
      # @param files [Hash{String => String}, nil] a recorded file map, or nil
      #   for no history
      # @return [self]
      def resume(files)
        @last_files = files
        self
      end

      private

      # What counts as unchanged is the scope's question, because only the
      # scope knows whether its map is a whole state or one turn's delta.
      def skip?(files) = @scope.unchanged?(root: @root, files:, last: @last_files)

      # Sorted so the map cannot vary with write-set recording order; {Store#put}
      # is idempotent, so re-hashing an unchanged file re-stores nothing.
      def manifest(store, paths)
        paths.sort.filter_map { |path| entry(store, path) }.to_h
      end

      # nil for a path with no regular file behind it, including one deleted
      # BETWEEN the existence check and the read: the rescue collapses that race
      # into the omission it raced, since omission already means deletion.
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
