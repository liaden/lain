# frozen_string_literal: true

module Lain
  module Tripwire
    # Every program a call's stages resolved, its wrappers included, read from
    # the stages of an `exec_resolution` record.
    class Resolution
      # @param stages [Array<Hash{String=>Object}>, nil] nil when the call journalled none
      def initialize(stages)
        @programs = Array(stages).flat_map { programs(_1) }
      end

      # @param path [String]
      # @return [Boolean] whether a stage resolved to it, by any link on its way
      def ran?(path) = @programs.any? { paths(_1).include?(path) }

      # @param path [String]
      # @return [Boolean] whether an unchanged program a reader profile may grant resolved to it
      def toolchain?(path) = @programs.any? { unchanged?(_1) && paths(_1).include?(path) }

      # @param path [String]
      # @return [Boolean] whether the PATH search met it, not executable, before what it resolved
      def skipped?(path) = @programs.any? { Array(_1["skipped"]).include?(path) }

      # @return [Array<String>]
      def fresh_programs = @programs.select { _1["fresh"] }.map { _1["realpath"] || _1["name"] }

      # @return [Array<String>]
      def fresh_run_files = @programs.flat_map { Array(_1["run_files"]) }.select { _1["fresh"] }.map { _1["path"] }

      private

      def programs(stage) = [*Array(stage["wrappers"]).flat_map { programs(_1) }, stage]

      def paths(program) = [program["resolved"], program["realpath"], *program["chain"]].compact

      def unchanged?(program)
        Confine::Profile::GRANTED_CLASSES.map(&:to_s).include?(program["klass"]) &&
          !program["fresh"]
      end
    end
  end
end
