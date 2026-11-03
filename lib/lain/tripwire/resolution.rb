# frozen_string_literal: true

module Lain
  module Tripwire
    # Every program a call's stages resolved, its wrappers included, read from
    # the stages of an `exec_resolution` record.
    class Resolution
      # A launcher's own path is only a claim; it names a home that {#launched_from_toolchain?} then checks.
      HOME_OF = %r{\A(.+?)/(?:\.cargo/bin|\.rustup|\.local/share/mise)/}

      # Answers every path fresh, so an unwired resolution excuses no exec.
      module AllFresh
        def self.fresh?(_path) = true
      end

      # @param stages [Array<Hash{String=>Object}>, nil] nil when the call journalled none
      # @param fresh [#fresh?] whether a file changed during this lineage
      # @param home [String] the home whose toolchain roots a launcher may exec into
      # @param execs [Confine::ExecRules] named build output, whose fresh run files are expected
      def initialize(stages, fresh: AllFresh, home: Dir.home, execs: Confine::ExecRules::NONE)
        @fresh = fresh
        @execs = execs
        @home = real(home)
        @programs = Array(stages).flat_map { programs(_1) }
      end

      # @param path [String]
      # @return [Boolean] whether a stage resolved to it, by any link on its way
      def ran?(path) = @programs.any? { paths(_1).include?(path) }

      # @param path [String]
      # @return [Boolean] whether an unchanged program a reader profile may grant resolved to it
      def toolchain?(path) = @programs.any? { unchanged?(_1) && paths(_1).include?(path) }

      # @param path [String] a program the call exec'd
      # @return [Boolean] whether an unchanged granted launcher exec'd it, unchanged, out of its own toolchain root
      def launched_from_toolchain?(path)
        real = real(path)
        !real.nil? && @programs.any? { unchanged?(_1) && roots(_1).any? { |root| real.start_with?("#{root}/") } } &&
          !@fresh.fresh?(path)
      end

      # @param path [String]
      # @return [Boolean] whether the PATH search met it, not executable, before what it resolved
      def skipped?(path) = @programs.any? { Array(_1["skipped"]).include?(path) }

      # @return [Array<String>]
      def fresh_programs = @programs.select { _1["fresh"] }.map { _1["realpath"] || _1["name"] }

      # @return [Array<String>] each fresh run file not held by a named exec rule
      def fresh_run_files
        @programs.flat_map { Array(_1["run_files"]) }.select { _1["fresh"] }.map { _1["path"] }
                 .reject { built?(_1) }
      end

      private

      def programs(stage) = [*Array(stage["wrappers"]).flat_map { programs(_1) }, stage]

      def paths(program) = [program["resolved"], program["realpath"], *program["chain"]].compact

      def roots(program)
        claimed = paths(program).filter_map { _1[HOME_OF, 1] }.first
        return [] unless @home && claimed && real(claimed) == @home

        [*Confine::Profile::HOME_EXEC, Confine::Profile::INSTALLS].filter_map { real(File.join(@home, _1)) }
      end

      # The fence grants the file a link lands on, so a link out of the build output is not build output.
      def built?(path)
        landing = real(path)
        !landing.nil? && @execs.exec?(path) && @execs.exec?(landing)
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        nil
      end

      def unchanged?(program)
        Confine::Profile::GRANTED_CLASSES.map(&:to_s).include?(program["klass"]) &&
          !program["fresh"]
      end
    end
  end
end
