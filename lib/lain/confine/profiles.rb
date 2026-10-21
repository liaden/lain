# frozen_string_literal: true

module Lain
  module Confine
    # Chooses the {Profile} a call runs under. The ruling decides, never the
    # resolution: an approval by {Approval::ComposedTerm} rested on the call
    # only reading, so it runs under the reader profile, and any other allow
    # was given by someone who saw the command, so it is traced and not confined.
    #
    # What this kernel lacks narrows the profile: no trace leaves a reader
    # confined and untraced, and every other call unwatched.
    class Profiles
      # A listed link lands on a program or directory the call runs on, so its
      # mask would leave an empty view or an exec that fails for no visible reason.
      class Overmasked < Error
        attr_reader :path, :names

        # @param path [String] the program or directory the mask would hide
        # @param names [Array<String>] the listed names that landed on it
        def initialize(path:, names:)
          @path = path
          @names = names
          super("#{names.join(", ")} lands on #{path}, which the call needs")
        end
      end

      # @param masks [#masks] the session's {MaskList}, asked on every call so a
      #   mask whose file has gone never reaches bwrap, which fails on one
      # @param probe [#supports?] which sandbox layers this kernel offers
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param root [String] absolute; the session's project, for a request that names no root of its own
      def initialize(masks:, probe:, home:, root:)
        @masks = masks
        @probe = probe
        @home = home
        @root = root
      end

      # @param request [Request]
      # @return [Profile]
      # @raise [Overmasked] when a mask would empty a directory the reader profile grants
      def for(request)
        return reader(request) if read_only?(request.ruling)

        traceable? ? Profile::TRACED : Profile::NONE
      end

      private

      def read_only?(ruling) = ruling.allow? && ruling.rule == Approval::ComposedTerm.rule_name

      def traceable? = @probe.supports?(:trace)

      def reader(request)
        profile = Profile.reader(root: request.root || @root, home: @home, masks: @masks.masks.map(&:path),
                                 exec_files: exec_files(request.executables), trace: traceable?)
        overmask = profile.overmask
        raise Overmasked.new(path: overmask, names: @masks.landed_on(overmask)) if overmask

        profile
      end

      # A program the call resolved to outside /usr may run, unless the project
      # could have put it there: that is the plant the reader profile exists to stop.
      def exec_files(executables)
        executables.flat_map(&:programs).select { grantable?(_1) }.map(&:realpath).uniq
      end

      def grantable?(executable)
        Profile::GRANTED_CLASSES.include?(executable.klass) && !executable.realpath.nil? &&
          Profile::SYSTEM_EXEC.none? { executable.realpath.start_with?("#{_1}/") }
      end
    end
  end
end
