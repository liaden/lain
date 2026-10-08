# frozen_string_literal: true

module Lain
  # The files under a root that git would show, walked lazily.
  #
  # A repository is listed by `git ls-files` rather than descended, so its
  # ignores (a `target/` of thousands of files) are never visited. A directory
  # outside any repository is descended by hand, one directory at a time, so
  # taking the first few entries does not pay for the whole tree. A plain parent
  # of several repositories gets both: each repository it meets is listed by git
  # from its own directory, which is the only place its ignores are known.
  class FileWalk
    include Enumerable

    # `--cached` with `--others` is the working tree as it stands; `-z` because
    # git quotes an unusual name otherwise.
    LS_FILES = %w[ls-files -z --cached --others --exclude-standard].freeze

    # Seconds one `git` may take; a child that outlives it reads as "no repository".
    GIT_TIMEOUT = 10

    NUL = "\0"

    # @param root [String, Pathname] the directory to walk
    # @param links [Boolean] whether a symbolic link is yielded beside the regular
    #   files; a link is never descended
    # @param shell_out_factory [#call] builds the subprocess runner
    def initialize(root:, links: false, shell_out_factory: Shell::Out.public_method(:new))
      @root = File.expand_path(root)
      @links = links
      @shell_out_factory = shell_out_factory
    end

    # @yieldparam path [String] absolute path of an existing regular file (or link, with `links:`)
    def each(&block)
      return enum_for(:each) unless block

      visit(@root, probe: true, &block)
    end

    private

    # Only the root is probed without a `.git` entry: it may sit inside a
    # repository whose `.git` is above it.
    def visit(dir, probe:, &block)
      listed = (probe || File.exist?(File.join(dir, ".git"))) && listing(dir)

      listed ? list(dir, listed, &block) : descend(dir, &block)
    end

    # An empty answer falls through to the hand walk: it covers a repository
    # whose whole tree is ignored, which the human naming it still wants read.
    # Sorted per path segment, as the hand walk orders directory entries, so both arms agree;
    # on bytes, because a name that is not valid text raises out of a text split.
    def listing(dir)
      paths = git(dir, *LS_FILES).to_s.split(NUL).reject(&:empty?)
      paths = paths.sort_by { _1.b.split(File::SEPARATOR) }.map { _1.dup.force_encoding(FILESYSTEM) }

      paths unless paths.empty?
    end

    # A trailing slash is git naming an untracked nested repository, which it
    # will not look inside; a gitlink has none and is not a file, so it drops.
    def list(dir, relatives, &)
      relatives.each do |relative|
        absolute = File.join(dir, relative)
        relative.end_with?("/") ? visit(absolute.chomp("/"), probe: true, &) : yield_existing(absolute, &)
      end
    end

    def yield_existing(absolute)
      entry = lstat(absolute)
      yield absolute if entry && wanted?(entry)
    end

    def wanted?(entry) = entry.file? || (@links && entry.symlink?)

    # The rescue covers the filesystem call alone: an error the consumer's block
    # raises must reach the consumer.
    def lstat(path)
      File.lstat(path)
    rescue SystemCallError
      nil
    end

    def children(dir)
      Dir.each_child(dir).sort
    rescue SystemCallError
      []
    end

    def descend(dir, &block)
      children(dir).reject { _1 == ".git" }.each do |name|
        child = File.join(dir, name)
        entry = lstat(child)
        entry&.directory? ? visit(child, probe: false, &block) : yield_existing(child, &block)
      end
    end

    # nil for every way git can fail to answer, which callers read as "no repository".
    def git(dir, *argv)
      shell = @shell_out_factory.call("git", "-C", dir, *argv,
                                      environment: Isolation::Worktree::GIT_CONTEXT_SCRUB,
                                      timeout: GIT_TIMEOUT)
      shell.run_command
      shell.stdout if shell.exitstatus&.zero?
    rescue Shell::Out::Timeout, SystemCallError
      nil
    end
  end
end
