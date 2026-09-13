# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "securerandom"

module Lain
  class Workspace
    class Snapshot
      module Scope
        class ShadowGit
          # The bare repository lain keeps for ONE project under XDG state, and
          # every git call made against it. {ShadowGit} decides what a snapshot
          # captures; this only asks git and reads the answer.
          #
          # Git hands names back as bytes. {#name} is the one place they become
          # Ruby strings: UTF-8 when they are valid UTF-8, and a named refusal
          # when they are not. A name left in git's bytes cannot be joined onto
          # a UTF-8 root, and a name forced into some other encoding would have
          # an undo write a file that is not the one the turn changed.
          #
          # Two chats on one project share the store's objects, never its index:
          # each session stages through its own index file inside the store, so
          # neither stages over the other or loses the other's `index.lock`.
          class Repository
            # One path between two trees: each side's mode and blob id, both nil
            # on the side where the path did not exist.
            Row = Data.define(:key, :before_mode, :before_id, :after_mode, :after_id)

            ABSENT_MODE = "000000"

            # A second process creating the same store can hold its config lock
            # for a moment; `init` on a finished store is harmless, so it is
            # simply asked again.
            INIT_TRIES = 3
            INIT_PAUSE = 0.05

            # @param root [String, Pathname] the project work tree
            # @param paths [Paths] resolves XDG state and the per-project key
            # @param session [String] names this session's own index in the store
            # @param shell_out_factory [#call] builds the subprocess runner
            # @raise [Failed, Paths::Unwritable] when the store cannot be made
            def self.open(root:, paths:, session: SecureRandom.hex(6),
                          shell_out_factory: Mixlib::ShellOut.public_method(:new))
              expanded = File.expand_path(root.to_s)
              dir = ProjectDir.new(root: expanded, paths:).container("workspace")
              new(root: expanded, dir:, index: File.join(dir, "index-#{session}"), shell_out_factory:).ready
            end

            def initialize(root:, dir:, index:, shell_out_factory:)
              @root = root
              @dir = dir
              @index = index
              @shell_out_factory = shell_out_factory
            end

            # Always initialises, rather than when the directory is missing: a
            # directory another process is still creating exists before it is a
            # repository.
            #
            # @return [self]
            def ready
              init
              self
            end

            # `add --all` is what honours `.gitignore` and what notices
            # deletions; `write-tree` freezes the staged state as a tree id.
            #
            # A SUBMODULE is recorded as a gitlink, so a write inside one is
            # invisible here -- declared in {NOTE} rather than papered over.
            #
            # @return [String] the tree id
            def stage
              attempt("add") { git("add", "--all") }
              attempt("write-tree") { git("write-tree") }.stdout.strip
            end

            # `--no-renames` states a dependency rather than changing today's
            # behaviour: a detected rename reports only its DESTINATION, and the
            # path that vanished is exactly what a restore has to know about.
            #
            # @param since [String] a tree id
            # @return [Array<String>] root-relative names staged differently
            def changed(since)
              names(attempt("diff-index") { git("diff-index", "--cached", "--name-only", "--no-renames", "-z", since) })
            end

            # @return [Array<Row>] every path that differs between the trees
            def rows(before, after)
              shell = attempt("diff-tree") { git("diff-tree", "-r", "--no-renames", "-z", before, after) }
              fields(shell).each_slice(2).map { |meta, raw| row(meta, raw) }
            end

            # @return [String] the blob's bytes, binary
            def blob(id) = attempt("cat-file") { git("cat-file", "blob", id) }.stdout.b

            # check-ignore answers in its exit status: 0 is ignored, 1 is not.
            def ignored?(key)
              attempt("check-ignore", answers: [0, 1]) { git("check-ignore", "-q", "--", key) }.exitstatus.zero?
            end

            private

            # `-z` output, split before any encoding is trusted: splitting a
            # string labelled UTF-8 that holds invalid bytes raises.
            def fields(shell) = shell.stdout.b.split("\0".b).reject(&:empty?)

            def names(shell) = fields(shell).map { |raw| name(raw) }

            def name(raw)
              utf8 = raw.dup.force_encoding(Encoding::UTF_8)
              return utf8.freeze if utf8.valid_encoding?

              raise Failed, "shadow git named a path that is not valid UTF-8: #{raw.inspect}"
            end

            # `:<old mode> <new mode> <old id> <new id> <status>`
            def row(meta, raw)
              before_mode, after_mode, before_id, after_id = meta.delete_prefix(":").split.first(4)
              Row.new(key: name(raw), **side(:before, before_mode, before_id), **side(:after, after_mode, after_id))
            end

            def side(which, mode, id)
              present = mode != ABSENT_MODE
              { "#{which}_mode": present ? -mode : nil, "#{which}_id": present ? -id : nil }
            end

            # Under the plain scrub, with no GIT_DIR of its own: the directory
            # argument is the only thing that may decide where the store lands.
            def init(tries = INIT_TRIES)
              ensure_state_home(File.dirname(@dir))
              attempt("init") { run("init", "--bare", "--quiet", @dir, environment: GIT_CONTEXT_SCRUB) }
            rescue Failed
              raise if tries <= 1

              sleep(INIT_PAUSE * (INIT_TRIES - tries + 1))
              init(tries - 1)
            end

            # {Paths::Unwritable} rather than a raw `Errno`: that is the refusal
            # {Paths} raises for every other XDG directory it creates, and the
            # taxonomy is what a caller rescues.
            def ensure_state_home(dir)
              FileUtils.mkdir_p(dir)
            rescue SystemCallError => e
              raise Paths::Unwritable.new(dir, e)
            end

            def attempt(operation, answers: [0])
              shell = yield
              raise Failed.from_git(operation, shell) unless answers.include?(shell.exitstatus)

              shell
            rescue Errno::ENOENT, Mixlib::ShellOut::CommandTimeout => e
              raise Failed.from_error(operation, e)
            end

            def git(*)
              run("-C", @root, *, environment: GIT_CONTEXT_SCRUB.merge("GIT_DIR" => @dir, "GIT_WORK_TREE" => @root,
                                                                       "GIT_INDEX_FILE" => @index))
            end

            def run(*, environment:)
              @shell_out_factory.call("git", *, environment:).tap(&:run_command)
            end
          end
        end
      end
    end
  end
end
