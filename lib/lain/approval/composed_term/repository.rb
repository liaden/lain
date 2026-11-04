# frozen_string_literal: true

require "pathname"

module Lain
  module Approval
    class ComposedTerm < Rule
      # The config files of the repository git would find from a directory, read
      # as text and refused on any line this cannot place, and the config of
      # every submodule git status or diff would recurse into.
      #
      # MEASURED: `git status` and `git diff --stat` ran a submodule's
      # `core.fsmonitor` whether or not `.gitmodules` named it, so the
      # submodules are the index's gitlinks, not the `.gitmodules` list, and
      # git itself lists them ({Gitlinks}). One git absorbed lives under
      # `modules`, where its config is read; one whose repository is anywhere
      # else is refused.
      module Repository
        MARKER = ".git"
        HEAD = "HEAD"
        POINTER = /\Agitdir: (.+)$/
        # Sections and keys whose value is a program to run, a file to include,
        # or a working tree elsewhere; matched case-insensitively, as git does.
        SECTIONS = %w[include includeif pager filter difftool mergetool gpg credential].freeze
        KEYS = %w[pager fsmonitor external textconv command process clean smudge driver program editor hookspath
                  sshcommand askpass gitproxy alternaterefscommand packobjectshook difffilter cmd helper worktree
                  showsignature].freeze
        # git writes every submodule's own `core.worktree`, pointing back into the superproject.
        MODULE_KEYS = (KEYS - %w[worktree]).freeze
        MODULES = "modules"
        BLANK = /\A\s*(?:[#;].*)?\z/
        HEADER = /\A\s*\[\s*([A-Za-z0-9.-]+)(?:\s+"(?:[^"\\\n]|\\.)*")?\s*\](?:\s*[#;].*)?\s*\z/
        ENTRY = /\A\s*([A-Za-z][A-Za-z0-9-]*)\s*(?:=.*)?\z/
        # git reads a value ending in a backslash on into the next line, which a
        # reading line by line cannot place.
        CONTINUED = /\\\s*\z/
        BOUND = 64 * 1024

        # @param directory [String] absolute, where the git stage runs
        # @return [Boolean]
        def self.quiet?(directory)
          found = Pathname.new(directory).ascend.lazy.filter_map { |dir| dirs_at(dir) }.first
          found.nil? || plain?(*found)
        end

        # git takes a directory holding a HEAD for a repository itself, with no
        # working tree of its own.
        def self.dirs_at(dir)
          marker = dir.join(MARKER)
          return [*pointed(marker), dir] if marker.file?
          return [marker, marker, dir] if marker.directory?

          [dir, dir, nil] if dir.join(HEAD).exist?
        end

        def self.pointed(marker)
          gitdir = marker.dirname.join(File.read(marker)[POINTER, 1].to_s.strip)
          common = gitdir.join("commondir")
          [gitdir, common.file? ? gitdir.join(File.read(common).strip) : gitdir]
        end

        def self.plain?(gitdir, common, worktree)
          modules = common.join(MODULES)
          configs(gitdir, common).all? { |file| plain_file?(file, KEYS) } &&
            submodules(modules).all? { |dir| configs(dir, dir).all? { plain_file?(_1, MODULE_KEYS) } } &&
            absorbed?(worktree, modules)
        end

        def self.configs(gitdir, common) = [common.join("config"), gitdir.join("config.worktree")].uniq

        # Each repository under `modules`, its own nested ones included; a name
        # may hold slashes, so a directory with no HEAD is read through.
        def self.submodules(dir)
          return [] unless dir.directory?

          dir.children.select(&:directory?).flat_map do |child|
            child.join(HEAD).exist? ? [child, *submodules(child.join(MODULES))] : submodules(child)
          end
        end

        # Every gitlink checked out under the working tree is a repository git
        # absorbed into `modules`, and so is every one checked out inside it.
        def self.absorbed?(worktree, modules)
          return true if worktree.nil?

          links = Gitlinks.of(worktree)
          !links.nil? && links.all? { |path| absorbed_link?(worktree.join(path), modules) }
        end

        # A gitlink with nothing checked out is skipped by git, so it is plain.
        def self.absorbed_link?(checkout, modules)
          marker = checkout.join(MARKER)
          return true unless marker.exist? || marker.symlink?
          return false if marker.symlink? || !marker.file?

          gitdir, = pointed(marker)
          under?(gitdir, modules) && absorbed?(checkout, modules)
        end

        # A path that does not resolve is under nothing.
        def self.under?(gitdir, modules)
          gitdir.realpath.to_s.start_with?("#{modules.realpath}#{File::SEPARATOR}")
        rescue SystemCallError
          false
        end

        def self.plain_file?(file, keys)
          return true unless file.exist?

          text = File.read(file, BOUND + 1)
          text.bytesize <= BOUND && text.each_line.all? { |line| plain_line?(line.chomp, keys) }
        end

        def self.plain_line?(line, keys)
          return false if line.match?(CONTINUED)
          return true if line.match?(BLANK)

          header = line.match(HEADER)
          return !SECTIONS.include?(header[1].downcase.split(".").first) if header

          entry = line.match(ENTRY)
          !entry.nil? && !keys.include?(entry[1].downcase)
        end
        private_class_method :dirs_at, :pointed, :plain?, :configs, :submodules, :absorbed?, :absorbed_link?,
                             :under?, :plain_file?, :plain_line?

        # The paths git's own index lists as gitlinks, asked of git: an index
        # git accepts can show a byte reader a different entry list, as review
        # MEASURED with a crafted one, and git also reads a split index's shared
        # half. Every setting through which reading the index could run a
        # program or write it back is forced off, the optional locks with them,
        # and this process's own git variables are dropped but the two that
        # name which global config applies. Anything but a clean exit with
        # output that parses answers nil, which refuses. It runs the `git` on
        # lain's own PATH, as the judge's driver check does: lain already trusts
        # that binary to say what a repository holds.
        module Gitlinks
          SETTINGS = %w[core.fsmonitor=false core.untrackedCache=false core.hooksPath=/dev/null
                        core.pager=cat].flat_map { ["-c", _1] }.freeze
          KEPT_ENV = %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].freeze
          GIT_ENV = /\AGIT_/
          ENTRY = /\A(\d{6}) \h+ [0-3]\t(.+)\z/m
          GITLINK = "160000"
          SEPARATOR = "\0"
          TIMEOUT = 10

          # @param worktree [Pathname] where git finds the repository whose index is read
          # @return [Array<String>, nil]
          def self.of(worktree)
            out = Shell::Out.new("git", "--no-pager", *SETTINGS, "ls-files", "-s", "-z",
                                 environment:, cwd: worktree.to_s, timeout: TIMEOUT).run_command
            parsed(out.stdout.b) if Shell::Out.ok?(out)
          rescue Shell::Out::Timeout, SystemCallError
            nil
          end

          def self.environment
            dropped = ENV.keys.grep(GIT_ENV).reject { KEPT_ENV.include?(_1) }
            dropped.to_h { [_1, nil] }.merge("GIT_OPTIONAL_LOCKS" => "0")
          end

          def self.parsed(output)
            entries = output.split(SEPARATOR).map { _1.match(ENTRY) }
            entries.select { _1[1] == GITLINK }.map { _1[2] } if entries.all?
          end
          private_class_method :environment, :parsed
        end
        private_constant :Gitlinks
      end
    end
  end
end
