# frozen_string_literal: true

require "pathname"

module Lain
  # Where a path really lands: the real path of its longest existing prefix,
  # with the part not on disk yet appended and cleaned. Cleaning only AFTER
  # resolution matters -- `link/..` is the link target's parent to the kernel,
  # and lexical cleaning would call it the cwd.
  #
  # The filesystem is asked here and nowhere in {Sensitivity}, whose
  # classifier stays lexical by contract.
  module Landing
    # A link whose target does not exist is not a missing file: the target can
    # be created later, outside the root, and the next read would follow it.
    class Dangling < Error; end

    # Links followed before giving up, Linux's own `MAXSYMLINKS`.
    HOPS = 40

    module_function

    # @param path [String] as the call wrote it, uncleaned
    # @param cwd [String] absolute; what a relative path is joined to
    # @param home [String, nil] the lexical home, spelled as configured
    # @param root [String, nil] the lexical project root, spelled as configured
    # @return [Array<String>] the real path first, then the same path re-spelled
    #   under the lexical home and root when their real paths differ, so a rule
    #   anchored on either spelling still matches
    # @raise [Dangling] when the path or a prefix is a link to nothing
    # @raise [SystemCallError] when no prefix resolves
    def of(path, cwd:, home: nil, root: nil)
      real = resolve(path.start_with?(File::SEPARATOR) ? path : File.join(cwd, path))
      [real, *[home, root].compact.filter_map { |lexical| respell(real, lexical) }]
    end

    # Where a path would land once written: {.of}, except that a dangling link
    # is followed to where its target would be created, each target read
    # against its own link's directory, as the kernel reads it.
    #
    # @param path [String] as the call wrote it, uncleaned
    # @param cwd [String] absolute; what a relative path is joined to
    # @param home [String, nil] the lexical home, spelled as configured
    # @param root [String, nil] the lexical project root, spelled as configured
    # @param hops [Integer] how many dangling links to follow, the kernel's
    #   own symlink limit by default
    # @return (see .of)
    # @raise [Dangling] past `hops` links
    # @raise [SystemCallError] when no prefix resolves
    def eventual(path, cwd:, home: nil, root: nil, hops: HOPS)
      absolute = path.start_with?(File::SEPARATOR) ? path : File.join(cwd, path)
      of(absolute, cwd:, home:, root:)
    rescue Dangling
      raise if hops.zero?

      eventual(through(absolute), cwd:, home:, root:, hops: hops - 1)
    end

    # Where a path lands, when that is somewhere other than its own name --
    # what a human or a judge is shown beside the name a call wrote.
    #
    # @param path [String] as the call wrote it
    # @param cwd [String] absolute; what a relative path is joined to
    # @return [String, nil] nil when it lands on itself or cannot be resolved
    def redirect(path, cwd:)
      named = File.expand_path(path, cwd)
      landing = eventual(named, cwd:).first
      landing unless landing == named
    rescue Error, SystemCallError, ArgumentError, EncodingError
      nil
    end

    def resolve(path)
      File.realpath(path)
    rescue Errno::ENOENT
      parent = File.dirname(path)
      raise if parent == path
      raise Dangling, "#{path} is a link to nothing" if File.symlink?(path)

      Pathname.new(File.join(resolve(parent), File.basename(path))).cleanpath.to_s
    end

    # The deepest prefix that is a link to nothing, swapped for its target.
    # Joined, never expanded: a `..` in the target is left for {.of} to resolve
    # through the filesystem, where it may climb out of another link.
    def through(path)
      link = Pathname.new(path).ascend.map(&:to_s).find { File.symlink?(_1) && !File.exist?(_1) }
      raise Dangling, "#{path} is a link to nothing" unless link

      target = File.readlink(link)
      joined = target.start_with?(File::SEPARATOR) ? target : File.join(File.realpath(File.dirname(link)), target)
      joined + path.delete_prefix(link)
    end

    def respell(real, lexical)
      anchor = File.realpath(lexical)
      return if anchor == lexical || !under?(real, anchor)

      File.join(lexical, real.delete_prefix(anchor))
    rescue SystemCallError
      nil
    end

    def under?(path, anchor) = path == anchor || path.start_with?(File.join(anchor, ""))

    private_class_method :resolve, :through, :respell, :under?
  end
end
