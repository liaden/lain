# frozen_string_literal: true

module Lain
  module Tools
    # Structured, direct-Ruby whole-file write: creates `path` with `content`,
    # or replaces its entire contents, no subprocess -- the same tier-1
    # reasoning as {ReadFile} and {EditFile}: the model has no command string
    # to interpolate.
    #
    # The read-before-write contract this tool enforces is narrower than
    # {EditFile}'s: {EditFile} always requires a prior read, because it can
    # only ever mutate a file that already exists. `write_file` also CREATES,
    # and a path that does not exist yet cannot possibly have been read this
    # session -- so the precondition below only fires when `path` already
    # exists on disk. Creation of a brand-new file is unconditionally allowed;
    # overwriting an existing one still demands the same read-before-write
    # discipline as {EditFile}, so a model cannot blind-clobber a file it
    # never looked at.
    class WriteFile < Tool
      # The wire shape: the path to write, and its full new contents.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to write.", required: true
        # blank_ok: content="" is a legitimate whole-file write (an empty file,
        # or truncating one to empty) -- see Tool::Input#field. The key stays
        # required in the wire schema; only the blank-VALUE rejection lifts.
        field :content, :string, description: "Full contents to write to the file.", required: true, blank_ok: true
      end

      input_model Input

      # Only an OVERWRITE (path already exists) is guarded. A nonexistent
      # path short-circuits the predicate to true so first-time creation is
      # never blocked on a read that was impossible to perform. The
      # exist?-then-write is a check-then-act, not a lock: within one turn a
      # single tool call runs to completion before the next fiber gets
      # scheduled, so this is sound for the one-call-at-a-time model this
      # harness runs today, not in general against a concurrent writer.
      requires("path exists and was never read this session") do |input, invocation|
        session = session_of(invocation)
        path = File.expand_path(input.path, session.worker_env.cwd)
        !File.exist?(path) || session.read?(path)
      end

      def name = "write_file"

      def description
        "Writes content to the file at path, creating it if it does not " \
          "exist and overwriting it if it does. Creating a new file needs no " \
          "prior read. Overwriting a file that already exists requires it " \
          "was read with read_file earlier this session -- writing over a " \
          "file that was never read is refused, never a silent clobber."
      end

      protected

      def perform(input, invocation)
        session = session_of(invocation)
        # The RESOLVED path (a relative one lands under the WorkerEnv cwd, Dir.pwd
        # by default) is what is written and recorded, so the contract above and
        # this write agree on the same file.
        path = File.expand_path(input.path, session.worker_env.cwd)
        File.write(path, input.content)
        # A successful write means the session now KNOWS this file's
        # contents -- recording the read lets a following write_file or
        # edit_file call see it as read, exactly as a real read_file would.
        # The write-set mirrors edit_file's ({Workspace::Snapshot}: write-set
        # only, the documented bash gap).
        session.record_read(path).record_write(path)
        Tool::Result.ok("wrote #{input.content.bytesize} bytes to #{path}")
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not write #{path}: #{e.message}")
      end
    end
  end
end
