# frozen_string_literal: true

module Lain
  class Journal
    # Whether the file a {Journal} created may be removed once it closes with
    # nothing ever recorded into it, and the inode-pinned check that decides.
    # Split out of {Journal} because appending NDJSON lines under a mutex and
    # owning the harness's ONE destructive operation on the experiment record
    # are separate responsibilities -- {Journal} tripped `Metrics/ClassLength`
    # carrying both, which is the cop naming the missing object
    # ({Resume::Salvager}'s precedent: extract, never loosen).
    class Unwritten
      # @param path [String, nil] the file {Journal.open} CREATED, and nothing
      #   else. nil -- an injected IO whose file is the caller's, or a name that
      #   already existed when `.open` ran -- means there is nothing this object
      #   could ever remove, which is the whole of its Null case.
      def initialize(path)
        @path = path
        @shared = false
      end

      # The descriptor has left the Journal ({Journal#share_fd}), so another
      # writer may land bytes after our close. Retires the discard for good:
      # those writes would otherwise go to an inode we had already unlinked,
      # invisibly, since nothing on this side can see them coming.
      def shared!
        @shared = true
      end

      # The inode to judge, stat'd through the caller's fd WHILE IT IS STILL
      # OPEN: a path can be re-pointed underneath us, an open descriptor cannot.
      # Answers nil whenever no discard could be justified at all.
      #
      # That size means "no record ever landed" only because
      # {Journal#initialize} puts the fd in sync mode unconditionally -- every
      # `#record` is on the inode before it returns, so no written bytes sit in
      # a buffer where `stat` cannot see them. An unsynced fd would report 0
      # for a file with a record in it, and this would delete it.
      def inode(io)
        return nil if @path.nil? || @shared || !io.respond_to?(:stat)

        io.stat
      rescue IOError, SystemCallError
        nil
      end

      # {Journal.open} creates the session file, but the header lands much later
      # ({SessionRecord::Scribe} writes it), so a run that died in between used
      # to leave a zero-byte NDJSON on disk forever -- and since the names are
      # UTC-timestamped, that file sorts NEWEST, so it became the answer every
      # reader got when it asked for the newest session. The writer cleans up
      # after itself rather than leaving each reader to recognise the artifact.
      #
      # Deleting is not the mirror of creating, though: deferring creation could
      # never destroy anything, while this can, so the check is pinned to the
      # INODE `.open` created and never to the name that reached it:
      #
      # - `@path` is set only for a file {Journal.open} won an O_EXCL create on,
      #   so one that already existed is never a candidate. That covers
      #   {Resume::Salvager} reopening a crashed session, and the SECOND of two
      #   Journals racing onto one filename (a clock-tick collision
      #   {CLI::Chronicle} and {CLI::ChatLaunch} both document) -- there,
      #   unlinking would cost the live session its header and every turn,
      #   landing them on a nameless inode.
      # - the size comes from our own fd ({#inode}), so it is that inode's, not
      #   whatever the name resolves to by now.
      # - the unlink runs only while the name STILL resolves to that same
      #   dev/ino, so a different file renamed onto the path survives.
      #
      # TWO slivers remain, and neither is closable from here:
      #
      # - another process that opened this same path independently, wrote
      #   nothing before our close, and writes after it. No check on this side
      #   can see a writer it was never told about.
      # - the gap between {#still_named?} and the `unlink` itself. POSIX has no
      #   inode-verifying unlink -- `unlink(2)` takes a name, always -- so a
      #   rename landing in that window removes a file we never opened, however
      #   many turns are in it. The check narrows the window to two syscalls; it
      #   cannot eliminate it.
      def discard(inode)
        return if inode.nil? || inode.size.positive? || !still_named?(inode)

        File.unlink(@path)
      rescue SystemCallError
        # Gone already, between the check and the unlink -- which is the state
        # this method wanted anyway.
        nil
      end

      private

      # `lstat`, never `stat`: a symlink has to be compared as the LINK, or we
      # would measure a target and unlink a pointer. (O_EXCL refuses to create
      # THROUGH a symlink, so `@path` should never BE one -- this is the belt to
      # that braces.)
      def still_named?(inode)
        named = File.lstat(@path)
        named.dev == inode.dev && named.ino == inode.ino
      rescue SystemCallError
        false
      end
    end
  end
end
