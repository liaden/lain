# frozen_string_literal: true

module Lain
  class Tool
    # The one path-resolution, guard and failure seam every file tool shares.
    #
    # Eight tools -- read_file, write_file, edit_file, list_files, glob, grep,
    # ast_search, file_symbols -- open a path the model named, and each used to
    # re-derive the same four steps in its own spelling: expand the path against
    # the session's cwd, refuse a target that is missing or the wrong kind, do
    # the work, turn a failed open into an error Result. The spellings had
    # drifted: three wordings for "the path is not there", two for "it cannot be
    # read", one tool omitting IOError from its rescue, and
    # {Lain::WorkerEnv#resolve} -- written to be THE cwd-resolution rule -- with
    # not one of the eight among its callers.
    #
    # == What this is NOT
    #
    # It is not a place the secret boundary lives. That boundary is three
    # places and stays three: {Sensitivity::Policy} gates on the effect,
    # {Middleware::WithholdSecretPaths} filters the result,
    # {Middleware::RedactSecretReads} masks the content. Tier-1 read_file, grep,
    # glob and list_files deliberately check no path, and nothing here changes
    # that -- these four methods answer "where is it, is it there, and what do I
    # say when opening it failed", never "may this be read". A sensitivity
    # question arriving here would be the per-tool checking the architecture
    # rejected, wearing a shared helper's clothes.
    #
    # == What it deliberately does not absorb
    #
    # `grep` and `ast_search` rescue INSIDE their walks with a nil body -- a
    # file that vanished mid-walk is a silent per-file skip, not a failed tool
    # call -- and that rescue stays on the walk. {#failing} takes its extra
    # exception classes as an argument rather than hardcoding a set, because
    # `EncodingError` rides along on a STRUCTURAL read and on nothing else.
    module FileTarget
      # Each expectation is an ORDERED list of [rules-it-out?, sentence]. The
      # first rule that fires names the refusal, which is why order is data
      # here: a directory handed to a file tool must be told it is a directory
      # rather than told it merely cannot be read.
      ABSENT = ->(path) { !File.exist?(path) }
      A_DIRECTORY = ->(path) { File.directory?(path) }
      NOT_A_DIRECTORY = ->(path) { !File.directory?(path) }
      UNREADABLE = ->(path) { !File.readable?(path) }

      # A MEMORY guard wearing a validation's clothes, and the whole difference
      # between `:regular_file` and `:file`. `File.size` is 0 for a character
      # device and for a fifo, so both sail through a size bound: measured under
      # `ulimit -v`, `read_file /dev/zero` died with `NoMemoryError`, which is
      # not a StandardError and so escapes both {#failing} and
      # {Effect::Handler::Live}'s rescue. A fifo does not even fail -- it blocks
      # until somebody writes. `File.file?` and not `File.ftype`, which uses
      # `lstat` and would answer "link" for a symlink to a perfectly ordinary
      # file.
      #
      # Its POSITION in the list is the constraint, not merely its presence: a
      # chardev IS readable, so any rule after UNREADABLE would let
      # `read_file /dev/zero` reach the bound reads. Ordering is data here for
      # exactly that reason.
      IRREGULAR = ->(path) { !File.file?(path) }

      EXPECTATIONS = {
        file: [[ABSENT, "no such file"],
               [A_DIRECTORY, "is a directory, not a file"],
               [UNREADABLE, "file is not readable"]],
        regular_file: [[ABSENT, "no such file"],
                       [A_DIRECTORY, "is a directory, not a file"],
                       [IRREGULAR, "not a regular file (a device, socket or fifo has no size to bound)"],
                       [UNREADABLE, "file is not readable"]],
        directory: [[ABSENT, "no such directory"],
                    [NOT_A_DIRECTORY, "not a directory"],
                    [UNREADABLE, "directory is not readable"]],
        # grep and ast_search take either, so their sentence names both and no
        # wrong-kind rule fires at all.
        either: [[ABSENT, "no such file or directory"],
                 [UNREADABLE, "not readable"]]
      }.freeze

      private

      # The RESOLVED absolute path, which is what the read, the write, the
      # read-set, the contracts and every error message agree on, whatever
      # spelling the model sent. Delegated to {Lain::WorkerEnv#resolve} rather
      # than respelled: a relative path lands under the session's cwd, an
      # absolute one is honored as given, and an absent one IS the cwd -- the
      # nil arm `glob` used to spell as `input.path || "."`.
      #
      # @param invocation [Tool::Invocation, nil]
      # @param path [String, nil] the path as the model spelled it
      # @return [String]
      def target(invocation, path)
        session_of(invocation).worker_env.resolve(path)
      end

      # A missing path, a wrong-kind path or an unreadable one is a reasonable
      # question the model asked, so it earns one sentence and an error Result
      # rather than a raise.
      #
      # @param path [String] already resolved
      # @param expecting [Symbol] a key of {EXPECTATIONS}
      # @return [String, nil] the refusal, or nil when the path is usable
      def problem_with(path, expecting:)
        ruled_out = EXPECTATIONS.fetch(expecting).find { |rule, _sentence| rule.call(path) }
        ruled_out && "#{ruled_out.last}: #{path}"
      end

      # Wraps the tool's actual IO, and nothing wider: a failed open is the
      # model's answer, not an exception past the loop.
      #
      # @param verb [String] what the tool was doing -- "read", "write", "edit", "list"
      # @param path [String] already resolved, so the message says where it really looked
      # @param also [Array<Class>] extra classes this tool counts as the same answer
      # @return [Tool::Result]
      def failing(verb, path, *also)
        yield
      rescue SystemCallError, IOError, *also => e
        Result.error("could not #{verb} #{path}: #{e.message}")
      end

      # The odd one out, and named as such so this seam does not become a junk
      # drawer: two of the eight call it, both of them STRUCTURAL readers
      # handing bytes to the tree-sitter ext. It is here because the reason is
      # one reason, not because everything file-shaped belongs in one module.
      #
      # `encoding:` is not decoration: a bare File.read tags its result with
      # Encoding.default_external, US-ASCII under a C locale, so every ordinary
      # UTF-8 source file would come back mislabelled and the ext would refuse
      # it -- truthfully but uselessly. The file is source code; source code is
      # UTF-8; say so at the read.
      #
      # @param path [String]
      # @return [String]
      def utf8_source(path)
        File.read(path, encoding: Encoding::UTF_8)
      end
    end
  end
end
