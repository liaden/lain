# frozen_string_literal: true

module Lain
  module Tools
    # Structured, direct-Ruby whole-file write, no subprocess -- the same
    # tier-1 reasoning as {ReadFile} and {EditFile}.
    #
    # Its read-before-write contract is NARROWER than {EditFile}'s, which
    # always requires a prior read because it can only mutate a file that
    # already exists. `write_file` also CREATES, and a path that does not exist
    # yet cannot possibly have been read this session -- so the overwrite
    # precondition fires only when `path` already exists on disk. Creating a
    # brand-new file is unconditionally allowed; overwriting still demands the
    # same discipline, so a model cannot blind-clobber a file it never read.
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

      # Resolved as {#perform} resolves it -- {Tools::EditFile::SUBJECT}'s
      # reason, mirrored.
      SUBJECT = ->(input, invocation) { resolved_path(input, invocation) }
      private_constant :SUBJECT

      # The masked case FIRST, and for a harder reason than {EditFile}'s: an
      # edit over a masked file rewrites one span, but a WRITE replaces the
      # whole file with what the model has -- and what the model has is the
      # projection, PLACEHOLDERS INCLUDED. So the secret is not merely
      # clobbered, it is replaced on disk by the literal `<redacted:1>` and
      # gone. That is the destruction {Lain::Session}'s read-set comment names
      # as the reason the masked state exists at all.
      #
      # Deliberately NOT short-circuited by `!File.exist?`, unlike the
      # overwrite guard below: a path that was read is a path that exists, so
      # the create case cannot reach this predicate with a mask recorded, and
      # ordering the exist? test first would only hide that.
      #
      # No remedy named, for {EditFile}'s reason: there is none within the
      # session, and a message that implies one produces a loop.
      requires("%<subject>s was read only in part this session -- sensitive regions were masked out of " \
               "what you saw, so writing it back would replace them with their placeholders. Nothing in " \
               "this session will lift that: report it and do something else",
               subject: SUBJECT) do |input, invocation|
        !session_of(invocation).masked_read?(resolved_path(input, invocation))
      end

      # Only an OVERWRITE is guarded: a nonexistent path short-circuits the
      # predicate to true, so first-time creation is never blocked on a read
      # that was impossible to perform. The exist?-then-write is a
      # check-then-act, NOT a lock -- sound for the one-call-at-a-time model
      # this harness runs today, not in general against a concurrent writer.
      requires("%<subject>s exists and was never read this session", subject: SUBJECT) do |input, invocation|
        path = resolved_path(input, invocation)
        !File.exist?(path) || session_of(invocation).read?(path)
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
        path = resolved_path(input, invocation)
        File.write(path, input.content)
        # The session now KNOWS this file's contents, so recording the read
        # lets a following write_file or edit_file see it as read. The
        # write-set mirrors edit_file's ({Workspace::Snapshot}: write-set only,
        # the documented bash gap).
        session_of(invocation).record_read(path).record_write(path)
        Tool::Result.ok("wrote #{input.content.bytesize} bytes to #{path}")
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not write #{path}: #{e.message}")
      end

      private

      # The RESOLVED path is what the contracts above, the write, the read-set
      # and the refusals all agree on, whatever spelling the model sent.
      def resolved_path(input, invocation)
        File.expand_path(input.path, session_of(invocation).worker_env.cwd)
      end
    end
  end
end
