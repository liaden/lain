# frozen_string_literal: true

require "pathname"

module Lain
  module Isolation
    class Clone
      # What lain knows about a clone it cut, kept in a record beside the
      # clone where no sandboxed call can write, and how lain runs its own git
      # there, which is outside any sandbox.
      #
      # A call writes the clone's whole git dir, and git reads names there
      # that redirect it: an absent `commondir` naming a git dir the call made,
      # whose config runs a program as `core.fsmonitor` the next time lain
      # asks `git status`. So every git lain runs in a clone pins the git dir
      # and common dir by environment and turns fsmonitor off, and a clone
      # holding any such name is one lain runs no git in at all, kept for a
      # human. The pins do not stop git reading refs through a planted
      # `commondir` (measured, git 2.55), so the check runs before every git
      # call, not once.
      #
      # A record is trusted only where no profile can write: directly in a
      # lease root under lain's lease container, or in its `retained/`. One a
      # call planted beside a directory of its own project is not a record.
      module Guard
        TAMPERED = %w[commondir config.worktree worktrees modules].freeze

        # Beside the clone, named for it: its mtime is when the clone was cut,
        # its first line the object store lain cut it to read, and its second
        # the hooks dir lain set it to run.
        RECORD = ".lease"

        # @param path [String] a clone
        # @return [String] its record
        def self.record(path) = File.join(File.dirname(path), ".#{File.basename(path)}#{RECORD}")

        # Every lease root is one project's worktrees container, so their parent holds them all.
        #
        # @param paths [Paths]
        # @return [String] the tree every lease root lives under
        def self.container(paths = Paths.new)
          File.dirname(ProjectDir.new(root: File::SEPARATOR, paths:).container("worktrees"))
        end

        # @param path [String]
        # @return [Boolean] whether lain cut a clone there
        # A link named like a record is never one: only its own dir is resolved, never the record itself. The two
        # overlap on purpose: past the lstat, resolving the dir and resolving the record land in one place.
        def self.cut?(path)
          record = record(path)
          File.lstat(record).file? && laid_out?(File.join(File.realpath(File.dirname(record)), File.basename(record)))
        rescue SystemCallError
          false
        end

        # A lease root's own record, or one in its aside dir: a key and a name, or a key, `retained/` and a name.
        def self.laid_out?(record)
          base = File.realpath(container)
          return false unless Landing.under?(record, base)

          parts = Pathname(record).relative_path_from(base).each_filename.to_a
          parts.size == 2 || (parts.size == 3 && parts[1] == Worktree::RETAINED)
        rescue SystemCallError, ::Lain::Error
          false
        end
        private_class_method :laid_out?

        # @param path [String]
        # @return [Array<String>] each redirecting name present in the clone's git dir
        def self.tampered(path)
          git = File.join(path, ".git")
          TAMPERED.select { |name| File.exist?(File.join(git, name)) || File.symlink?(File.join(git, name)) }
        end

        # @param path [String]
        # @return [String] why lain runs no git there, or "" when nothing stops it
        def self.refusal(path)
          found = cut?(path) ? tampered(path) : []
          found.empty? ? "" : Tampered.new(found:).why(nil)
        end

        # @param dir [String] any directory, a clone lain cut or one inside it included
        # @param shell_out_factory [#call]
        # @return [Checkout] in `dir`, pinned to the enclosing clone's own git dir, refusing when that clone was
        #   tampered with, and plain for anything outside a clone lain cut
        def self.checkout(dir, shell_out_factory:)
          clone = enclosing(dir)
          return Checkout.new(dir, shell_out_factory:) unless clone

          Guarded.new(dir, clone:, shell_out_factory:)
        end

        # A nested repository inside a clone is read as part of the clone, so its own config is never read.
        #
        # @param dir [String]
        # @return [String, nil] the nearest clone lain cut at or above `dir`
        def self.enclosing(dir)
          expanded = resolved(dir)
          return unless inside_container?(expanded)

          Pathname(expanded).ascend.map(&:to_s).find { cut?(_1) }
        end

        # A link from anywhere into a clone reaches the clone, so the clone is what is judged.
        def self.resolved(dir)
          File.realpath(dir)
        rescue SystemCallError
          File.expand_path(dir)
        end
        private_class_method :resolved

        def self.inside_container?(path)
          base = container
          Landing.under?(path, base) || Landing.under?(path, File.realpath(base))
        rescue SystemCallError, ::Lain::Error
          false
        end
        private_class_method :inside_container?

        # What a workspace profile seals in a clone lain cut, from the layout lain made rather than from git's
        # answer, which a plant in the git dir could steer.
        #
        # @param root [String]
        # @return [Array<String>, nil] common dir, git dir and hooks dir; nil for anything lain did not cut
        def self.git_dirs(root)
          return unless cut?(root)

          git = File.join(root, ".git")
          hooks = File.readlines(record(root), chomp: true)[1].to_s
          [git, git, hooks.empty? ? File.join(git, "hooks") : hooks]
        rescue SystemCallError
          nil
        end

        # Read from lain's record, never from the clone's alternates file,
        # which a call may have written.
        #
        # @param root [String] a project root
        # @return [Array<String>] the object store a clone lain cut there reads, or none
        def self.upstream_objects(root)
          return [] unless cut?(root)

          objects = File.readlines(record(root), chomp: true).first.to_s
          File.basename(objects) == "objects" && File.directory?(objects) ? [objects] : []
        rescue SystemCallError
          []
        end
      end
    end
  end
end
