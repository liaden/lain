# frozen_string_literal: true

module Lain
  module Budget
    Table = Data.define(:rows)

    # How many iterations an ask may run, by what it is: a skill, a role, or
    # neither. A row is a flat count, or a base plus a figure per issue for the
    # skills whose work grows with the epic they drive.
    #
    # Rows are strings because they come from a skill name or a config key.
    class Table
      DEFAULT = "default"

      PER_ISSUE = { base: DEFAULT_ITERATIONS, per_issue: 3 }.freeze

      ROWS = {
        DEFAULT => DEFAULT_ITERATIONS,
        "researcher" => 60,
        "issue_orchestrator" => 200,
        "plan-epic" => 60,
        "create-epic-issues" => PER_ISSUE,
        "iterate-epic" => PER_ISSUE,
        "implement-epic" => PER_ISSUE
      }.freeze

      # @param rows [Hash{String, Symbol => Integer, Hash}] rows replacing the defaults of the same name
      # @raise [ArgumentError] for a row that is not a positive whole number of iterations
      def initialize(rows: {})
        super(rows: ROWS.merge(rows.to_h { |name, row| [name.to_s, checked(name, row)] }).freeze)
      end

      # @param role [String, Symbol, nil] a role's name, read when no skill is named
      # @param skill [String, Symbol, nil]
      # @param issues [Integer] the mounted epic's issue count, for the rows that scale
      # @return [Integer] the row for the skill, else the role, else the default
      def iterations(role: nil, skill: nil, issues: 0)
        row = rows.fetch((skill || role).to_s) { rows.fetch(DEFAULT) }
        row.is_a?(Integer) ? row : row.fetch(:base) + (row.fetch(:per_issue) * issues)
      end

      def named?(name) = name.to_s != DEFAULT && rows.key?(name.to_s)

      private

      def checked(name, row)
        figures = row.is_a?(Hash) ? row.transform_keys(&:to_sym) : row
        raise ArgumentError, "#{name} needs positive whole iterations, got #{row.inspect}" unless sound?(figures)

        figures.is_a?(Hash) ? figures.freeze : figures
      end

      def sound?(row)
        return whole?(row) && row.positive? unless row.is_a?(Hash)

        row.keys.sort == %i[base per_issue] && row.values.all? { |figure| whole?(figure) } && row[:base].positive?
      end

      def whole?(figure) = figure.is_a?(Integer) && !figure.negative?
    end
  end
end
