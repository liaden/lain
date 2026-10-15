# frozen_string_literal: true

module Lain
  module Shell
    Term = Data.define(:pipelines)

    # What {Verdict} authorises and {Pipeline} runs: argv stages, never a
    # string. {Verdict} builds one pipeline, and {Pipeline} joins every stage of
    # a term into one pipe.
    #
    # One shape every consumer reads, so the approval rules, the exec backends
    # and the Journal cannot each grow their own idea of what a nested Array
    # meant. Each level refuses a member of the wrong type, which is what makes
    # a term deeply frozen and `Ractor.shareable?` by construction: it rides on
    # journal records and on a {Verdict::Decision}.
    class Term
      # The streams a stage may send to /dev/null instead of the capture.
      STREAMS = %i[stdout stderr].freeze

      # One command of a pipeline. Every word must be a String: Open3 pops a
      # trailing Hash off a stage and merges it into the SPAWN OPTIONS, so a
      # Hash here would be another chdir or an fd redirection. Refused when the
      # stage is built, so no runner has to remember to check.
      Stage = Data.define(:argv, :discards) do
        def initialize(argv:, discards:)
          raise ArgumentError, "a stage's argv must be an Array, got #{argv.inspect}" unless argv.is_a?(Array)

          strays = argv.grep_v(String)
          raise ArgumentError, "every word of a stage must be a String, got #{strays.first.inspect}" if strays.any?

          unknown = discards - STREAMS
          raise ArgumentError, "a stage discards only #{STREAMS.inspect}, got #{unknown.inspect}" if unknown.any?

          super(argv: argv.map(&:-@).freeze, discards: discards.uniq.freeze)
        end

        # @return [String, nil] the word that names what runs, as written
        def program = argv.first

        # @return [Hash{String=>Object}] JSON-safe, for a journal record
        def to_journal = { "argv" => argv, "discards" => discards.map(&:to_s) }
      end

      Pipeline = Data.define(:stages) do
        def initialize(stages:) = super(stages: Term.members_of(stages, Stage, "stages"))
      end

      def initialize(pipelines:) = super(pipelines: Term.members_of(pipelines, Pipeline, "pipelines"))

      # A nested Array where a member belongs would freeze shallowly and pass
      # for a term until a runner reached into it.
      #
      # @param members [Array] what a level was handed
      # @param type [Class] what each member must be
      # @param name [String] the member list, for the message
      # @return [Array] the members, frozen
      # @raise [ArgumentError] naming the first member of the wrong type
      def self.members_of(members, type, name)
        strays = members.to_a.grep_v(type)
        if strays.any?
          raise ArgumentError,
                "#{name} must be #{type.name.delete_prefix("Lain::Shell::")}, got #{strays.first.inspect}"
        end

        members.to_a.dup.freeze
      end

      # The term of a command nobody authorised: the Null Object a caller reads
      # instead of guarding on nil.
      NONE = new(pipelines: [])

      # @param argvs [Array<Array<String>>] the stages of one pipeline, in order
      # @return [Term]
      def self.of(*argvs)
        new(pipelines: [Pipeline.new(stages: argvs.map { |argv| Stage.new(argv:, discards: []) })])
      end

      # Words read back off the Journal arrive as fresh mutable Strings, and
      # going through {Stage} interns them again.
      #
      # @param record [Hash{String=>Object}]
      # @return [Term] {NONE} itself when no pipeline was written
      def self.from_journal(record)
        pipelines = record.fetch("pipelines").map do |stages|
          Pipeline.new(stages: stages.map do |stage|
            Stage.new(argv: stage.fetch("argv"), discards: stage.fetch("discards").map(&:to_sym))
          end)
        end
        pipelines.empty? ? NONE : new(pipelines:)
      end

      # @return [Array<Stage>] every pipeline's stages, in order
      def stages = pipelines.flat_map(&:stages)

      # @return [Array<String>] every word of every stage, programs included
      def words = stages.flat_map(&:argv)

      # @return [Array<String>] each stage's program, as written
      def programs = stages.map(&:program)

      def empty? = pipelines.empty?

      # @return [Hash{String=>Object}] JSON-safe, for a journal record
      def to_journal = { "pipelines" => pipelines.map { |pipeline| pipeline.stages.map(&:to_journal) } }
    end
  end
end
