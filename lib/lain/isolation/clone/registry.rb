# frozen_string_literal: true

require "fileutils"

module Lain
  module Isolation
    class Clone
      # The shared clones under one lease root, answering what
      # {Worktree::Registry} answers, so {Worktree::Release},
      # {Worktree::Leftover}, {Gc} and the backend drive either one.
      #
      # Upstream keeps no list of its clones, so the list is the root's
      # directories whose `.git` is a directory, and every lock left beside a
      # clone that is gone. A lock and the {Guard} record are files BESIDE the
      # clone: inside it, a sandboxed call could rewrite its own lease's. While
      # a clone exists upstream holds its base under {PINS}, keyed by this root,
      # since the clone reads that history through alternates and an upstream
      # prune would otherwise take it.
      class Registry
        include Registered

        LABEL = "clone lease"
        PINS = "refs/lain/lease"
        PINNED = "lain: pinned a clone lease's base"
        LOCKED = ".locked"
        IDENTITY = %w[user.name user.email].freeze

        Done = Checkout::Done

        # @param repo_root [String] upstream: any checkout of the repository
        # @param root [String] the lease root the clones live under
        # @param shell_out_factory [#call] builds the subprocess runner
        # @param paths [Paths] keys this root's pins
        def initialize(repo_root:, root:, shell_out_factory:, paths: Paths.new)
          @repo_root = repo_root
          @root = root
          @shell_out_factory = shell_out_factory
          @git = Checkout.of(repo_root, shell_out_factory:)
          @pins = "#{PINS}/#{paths.project_hash(root)}"
        end

        # @return [String] upstream, the repository every lease is cut from
        attr_reader :repo_root

        # @return [String] what a refusal names these checkouts by
        def label = LABEL

        # @return [Array<Worktree::Registry::Entry>]
        def entries = (clones | orphans).sort.map { entry_at(_1) }

        # Locked before the clone exists, so no moment has it unlocked. Only
        # what this call made is removed on a failure: a foreign directory at
        # `path` makes the clone itself refuse.
        def add(path, commit, reason:)
          held = lock(path, reason)
          return held unless Shell::Out.ok?(held)

          made = recorded(path)
          made = cloned(path) if Shell::Out.ok?(made)
          return forgotten(path, made) unless Shell::Out.ok?(made)

          failed = cut(path, commit).find { !Shell::Out.ok?(_1) }
          failed ? discarded(path, failed) : Done.ok
        end

        # Refused when already locked, as `git worktree lock` refuses.
        def lock(path, reason)
          File.open(lock_file(path), File::WRONLY | File::CREAT | File::EXCL, 0o600) { _1.write("#{reason}\n") }
          Done.ok
        rescue SystemCallError => e
          Done.refused("#{path} could not be locked: #{e.message}")
        end

        def unlock(path)
          File.delete(lock_file(path))
          Done.ok
        rescue SystemCallError => e
          Done.refused("#{path} was not locked: #{e.message}")
        end

        def move(from, to)
          return Done.refused("#{to} already exists") if File.exist?(to)

          File.rename(from, to)
          [lock_file(from), Guard.record(from)].zip([lock_file(to), Guard.record(to)])
                                               .select { File.exist?(_1.first) }.each { File.rename(*_1) }
          repin(from, to)
        rescue SystemCallError => e
          Done.refused("#{from} could not be moved to #{to}: #{e.message}")
        end

        # Refused while locked, which is what makes a lock that appears after
        # a {#claim} stop the removal, and for a clone kept for a human.
        def remove(path)
          return Done.refused("#{path} is locked") if File.exist?(lock_file(path))
          return Done.refused(Tampered.refusal(Guard.tampered(path))) if tampered?(path)

          FileUtils.rm_rf(path)
          FileUtils.rm_f(Guard.record(path))
          unpin(path)
          Done.ok
        end

        def prune
          stale_pins.each { |ref, held| @git.run("update-ref", "-d", ref, held) }
          Done.ok
        end

        # @return [Array<Array(String, String)>] each of this root's pins whose clone is gone, and its commit
        def stale_pins
          @git.run("for-each-ref", "--format=%(refname) %(objectname)", "#{@pins}/").stdout.split("\n")
              .map(&:split).reject { |ref, _| dirs.any? { File.directory?(File.join(_1, File.basename(ref))) } }
        end

        # Its own clones, judged whatever tree its root sits in.
        def tampered?(path) = File.file?(Guard.record(path)) && Guard.tampered(path).any?

        # @param path [String] a clone
        # @param clock [#call] answers now
        # @return [Time] when it was cut, from lain's record; now when that cannot be read, which errs
        #   towards keeping
        def cut_at(path, clock)
          File.mtime(Guard.record(path))
        rescue SystemCallError
          clock.call
        end

        protected

        def lock_file(path) = File.join(File.dirname(path), ".#{File.basename(path)}#{LOCKED}")

        def at(path) = Guarded.new(path, clone: path, shell_out_factory: @shell_out_factory)

        private

        def dirs = [@root, File.join(@root, Worktree::RETAINED)]

        def clones
          dirs.flat_map { Dir.glob(File.join(_1, "*", ".git")) }.select { File.directory?(_1) }
              .map { File.dirname(_1) }
        end

        def orphans
          dirs.flat_map { Dir.glob(File.join(_1, ".*#{LOCKED}")) }
              .map { File.join(File.dirname(_1), File.basename(_1, LOCKED).delete_prefix(".")) }
              .reject { File.exist?(_1) }
        end

        # A clone that is gone or was tampered with gets no git run in it.
        def entry_at(path)
          seal = read_lock(path)
          found = File.directory?(path) ? Guard.tampered(path) : []
          lock = found.empty? ? LeaseLock.parse(seal) : Tampered.new(found:)
          head, branch = found.empty? && File.directory?(path) ? tip(path) : ["", ""]
          Worktree::Registry::Entry.new(path: -path, head: -head, branch: -branch, lock:, seal: -seal.to_s)
        end

        def tip(path)
          tree = at(path)
          [tree.target("HEAD"), tree.symbolic_head]
        end

        def read_lock(path)
          File.read(lock_file(path)).chomp
        rescue SystemCallError
          nil
        end

        def recorded(path)
          dirs = @git.run("rev-parse", "--path-format=absolute", "--git-common-dir", "--git-path", "hooks")
          return dirs unless Shell::Out.ok?(dirs)

          common, hooks = dirs.stdout.lines(chomp: true)
          File.write(Guard.record(path), "#{File.join(common, "objects")}\n#{hooks}\n")
          Done.ok
        end

        # The clone runs upstream's hooks, resolved as git resolves them for
        # upstream; its config is sealed in the sandbox, so a call cannot undo it.
        # A linked worktree reads upstream's own config and a clone does not, so the identity a commit needs is
        # carried over from upstream's repository config.
        def cloned(path)
          hooks = File.readlines(Guard.record(path), chomp: true)[1]
          configs = [*carried, "core.hooksPath=#{hooks}"].flat_map { |pair| ["--config", pair] }
          @git.run("clone", "--quiet", "--shared", "--no-checkout", "--no-tags", "--single-branch", *configs, "--",
                   @repo_root, path)
        end

        def carried
          IDENTITY.filter_map do |key|
            value = @git.run("config", "--local", "--get", key)
            "#{key}=#{value.stdout.chomp}" if Shell::Out.ok?(value)
          end
        end

        # Lazily, so the first failure stops the rest. The clone's own refs go:
        # a stale remote ref is what an upstream prune breaks, and a branch
        # would be one a retry could check out.
        def cut(path, commit)
          tree = at(path)
          [-> { tree.run("checkout", "--quiet", "--detach", commit) },
           -> { tree.run("update-ref", "--no-deref", "--stdin", input: refs_deleted(tree)) },
           -> { @git.update_ref(pin(path), commit, reason: PINNED) }].lazy.map(&:call)
        end

        def refs_deleted(tree) = tree.run("for-each-ref", "--format=delete %(refname)").stdout

        def discarded(path, failed)
          FileUtils.rm_rf(path)
          forgotten(path, failed)
        end

        def forgotten(path, failed)
          FileUtils.rm_f(Guard.record(path))
          unlock(path)
          failed
        end

        def pin(path) = "#{@pins}/#{File.basename(path)}"

        def repin(from, to)
          held = @git.target(pin(from))
          return Done.ok if held.empty?

          moved = @git.update_ref(pin(to), held, reason: PINNED)
          return moved unless Shell::Out.ok?(moved)

          unpin(from)
          Done.ok
        end

        def unpin(path) = @git.run("update-ref", "-d", pin(path))
      end
    end
  end
end
