# frozen_string_literal: true

module Lain
  class Sensitivity
    ScanInput = Data.define(:text, :checksums, :literals)

    # What one command's output is scanned as, so the mask the model is shown
    # and the scan that withholds an automatically approved command's output
    # cannot disagree on a lockfile or a known value.
    #
    # @!attribute [r] text
    #   @return [String] the output
    # @!attribute [r] checksums
    #   @return [Boolean] whether every file the command reads is one the policy calls checksums
    # @!attribute [r] literals
    #   @return [Array<String>] the known values masked wherever they recur
    class ScanInput
      # They print the environment, and a value there may sit behind a checksum word.
      ENVIRONMENT_PRINTERS = %w[env printenv].freeze
      ASSIGNMENT = /\A\w+=/

      # @param result [String] the command's output
      # @param parse [Shell::Parse::Result, nil] the command's parse; nil when the call names no command
      # @param named [Shell::Named] the paths the command names
      # @param policy [#checksums?] the session's path policy
      # @param secrets [#to_a] the values the call's worker knows
      # @return [ScanInput]
      def self.of_bash(result, parse:, named:, policy:, secrets:)
        checksums = !named.opaque? && !parse.nil? && !prints_environment?(parse) && lockfiles?(named, policy)
        new(text: result, checksums:, literals: secrets.to_a.map(&:-@).freeze)
      end

      def self.lockfiles?(named, policy)
        read = named.paths.reject { _1.written || _1.guess }
        read.any? && read.all? do |path|
          path.pattern.nil? && policy.checksums?(path.resolved, within: File.dirname(path.resolved))
        end
      end

      def self.prints_environment?(parse)
        parse.stages.any? do |stage|
          program = stage.argv.drop_while { _1.match?(ASSIGNMENT) }.first.to_s.delete(%q('"))
          ENVIRONMENT_PRINTERS.include?(program.split(File::SEPARATOR).last)
        end
      end
      private_class_method :lockfiles?, :prints_environment?

      # @return [Array<Regions::Region>]
      def regions = Regions.detect(text, checksums:)

      # @param output [String]
      # @return [ScanInput] this scan over another text
      def over(output) = with(text: output)
    end
  end
end
