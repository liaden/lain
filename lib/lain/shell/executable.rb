# frozen_string_literal: true

module Lain
  module Shell
    Executable = Data.define(:name, :resolved, :realpath, :chain, :shadowed, :anomalies, :klass, :fresh, :run_files,
                             :wrappers)

    # One stage's program, resolved: which file runs, through which links, and
    # whether a user or the project could have put it there. {Resolver} builds
    # one per stage of a term.
    #
    # `klass` is `:system`, `:user`, `:project` or `:unresolved`. `chain` is each
    # link from `resolved` to `realpath`; `shadowed` the later `PATH` hits, one
    # per realpath. `anomalies` name what in the environment could change what
    # runs: `:empty_path_entry`, `:relative_path_entry`, `:project_path_entry`,
    # `:exported_function`, `:ld_preload`. `wrappers` are the programs (`nice`,
    # `env`, `bundle exec`) that ran this one, outermost first, each resolved
    # in its own right because a planted `nice` runs as surely as a planted `cat`.
    #
    # Rides on journal records and approval decisions, so it is deeply frozen.
    class Executable
      # @param members [Hash{Symbol=>Object}]
      def initialize(**members) = super(**members.transform_values { |value| Ractor.make_shareable(value) })

      # @return [Hash{String=>Object}] JSON-safe, for a journal record
      def to_journal
        { "name" => name, "resolved" => resolved, "realpath" => realpath, "chain" => chain, "shadowed" => shadowed,
          "anomalies" => anomalies.map(&:to_s), "klass" => klass.to_s, "fresh" => fresh,
          "run_files" => run_files.map(&:to_journal), "wrappers" => wrappers.map(&:to_journal) }
      end

      # @return [Array<Executable>] every wrapper that runs this one, outermost first, then this one
      def programs = [*wrappers.flat_map(&:programs), self]

      # @param name [String] the program word, as written or as unwrapped
      # @param anomalies [Array<Symbol>]
      # @param wrappers [Array<Executable>]
      # @return [Executable] a stage nothing is known about but its name
      def self.unresolved(name, anomalies: [], wrappers: [])
        new(name:, resolved: nil, realpath: nil, chain: [], shadowed: [], anomalies:, klass: :unresolved,
            fresh: false, run_files: [], wrappers:)
      end
    end
  end
end
