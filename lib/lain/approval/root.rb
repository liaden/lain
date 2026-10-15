# frozen_string_literal: true

module Lain
  module Approval
    # Whether a path lies under the project root, answered LEXICALLY --
    # expand against a base, then test the prefix -- and that is a decision:
    # {Workspace::Restore} refuses an escaping key by exactly this test and
    # refuses symlinks separately by lstat. Resolving links here would make
    # the two disagree about what "outside the root" means, and would put a
    # stat syscall in a check that must stay free.
    #
    # {ComposedTerm} asks it about every word of a shell command it would
    # approve with nobody asked.
    class Root
      TILDE = "~"

      # The root of a session that has no boundary to approve inside -- a
      # home directory, or a directory nothing detected as a project. It
      # contains nothing, so a caller that forgot to ask for a real one fails
      # closed rather than open.
      class Nowhere
        def contains?(*) = false
      end

      NOWHERE = Nowhere.new.freeze

      # @param path [String] an absolute root
      def initialize(path)
        @path = -path.to_s
        freeze
      end

      # So a caller that DOES want the disk's answer can hand this root to
      # `File.realpath`; nothing here calls it.
      def to_path = @path

      # @param path [String] as written, relative or absolute
      # @param from [String] the ABSOLUTE directory a relative path resolves
      #   against -- the root itself unless the caller names a cwd
      # @return [Boolean] never raising, and false for anything unresolvable
      def contains?(path, from: @path)
        return false unless resolvable?(path, from)

        expanded = File.expand_path(path, from)
        expanded == @path || expanded.start_with?("#{@path}#{File::SEPARATOR}")
      rescue ArgumentError, EncodingError
        # A NUL byte is the one input known to reach this, as an
        # ArgumentError. Unresolvable is exactly the case that must not be
        # waved through.
        false
      end

      private

      # `~` is refused LEXICALLY and never handed to File.expand_path, which
      # would resolve it through getpwnam -- on an SSSD or LDAP-backed host a
      # socket to nscd, i.e. a NETWORK CALL from a classifier whose whole
      # contract is that it makes none. Nothing is lost: a home-relative path
      # is outside the project root by construction. A relative base would
      # resolve against `Dir.pwd`, which is the process's and not the call's.
      def resolvable?(path, from)
        path.is_a?(String) && from.is_a?(String) && !path.start_with?(TILDE) &&
          from.start_with?(File::SEPARATOR)
      end
    end
  end
end
