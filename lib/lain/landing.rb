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

    def resolve(path)
      File.realpath(path)
    rescue Errno::ENOENT
      parent = File.dirname(path)
      raise if parent == path
      raise Dangling, "#{path} is a link to nothing" if File.symlink?(path)

      Pathname.new(File.join(resolve(parent), File.basename(path))).cleanpath.to_s
    end

    def respell(real, lexical)
      anchor = File.realpath(lexical)
      return if anchor == lexical || !under?(real, anchor)

      File.join(lexical, real.delete_prefix(anchor))
    rescue SystemCallError
      nil
    end

    def under?(path, anchor) = path == anchor || path.start_with?(File.join(anchor, ""))

    private_class_method :resolve, :respell, :under?
  end
end
