# frozen_string_literal: true

module Lain
  class Config
    Answers = Data.define(:allow, :deny, :deny_tools)

    # The `[approval]` table: the answers a human chose to remember, so a call
    # shape they have already ruled on is never put to them twice.
    # {Approval::Remembered} interprets them; this class only decides whether the
    # file says something well-formed, which is why it names no tool, no verdict
    # and no precedence of its own.
    #
    # It is `Answers` rather than `Approval`, and that name is FORCED: a
    # `Config::Approval` constant would win Ruby's lexical lookup over
    # `Lain::Approval` for every reference lexically inside {Config}, in any
    # file of this unit -- {Epics::Gates} asks
    # `Approval::Gate::Policies.known?` -- and the failure would be a
    # NameError nowhere near the constant that caused it.
    #
    # The shape is an array of tables per strength, because that is the one
    # TOML form a writer can APPEND to without rewriting the file: every other
    # table, and every comment a human wrote, survives an answer being
    # remembered.
    #
    #   [[approval.allow]]
    #   tool = "read_file"
    #   input = { path = "README.md" }
    #
    #   [[approval.deny_tool]]
    #   tool = "bash"
    class Answers
      # Reopened rather than written in the `Data.define` block, per
      # {Request::SYSTEM_PREFIX}: nested constants declared there belong to the
      # enclosing module instead.
      TOOL = "tool"
      INPUT = "input"
      # Two strengths keyed by call SHAPE, one by tool name whatever the call
      # says -- Emacs' `ignored-local-variable-values` against
      # `ignored-local-variables`.
      ALLOW = "allow"
      DENY = "deny"
      SHAPED = [ALLOW, DENY].freeze
      # Singular, because each `[[approval.deny_tool]]` is ONE tool's denial;
      # the reader over all of them is {#deny_tools}.
      TOOL_WIDE = "deny_tool"
      KEYS = [*SHAPED, TOOL_WIDE].freeze

      # The table as `config.toml` spells it, which is how a refusal about the
      # table as a whole names it; a refusal about one ENTRY names the list it
      # sits in ({.entry_table}), because that is the line a human has to open.
      TABLE = "[approval]"

      # @param table [Object] whatever `raw["approval"]` parsed to; nil when absent
      # @param path [String, nil] the config file, named in every refusal
      # @return [Answers]
      def self.from(table, path: nil)
        table = {} if table.nil?
        check!(table, path:)

        new(allow: table.fetch(ALLOW, []), deny: table.fetch(DENY, []),
            deny_tools: table.fetch(TOOL_WIDE, []).map { |entry| entry[TOOL] })
      end

      # {Epics::Gates.coerce}'s reason, one table over: a caller that is not
      # {.from} may reasonably hand a plain Hash, or nil for "nothing
      # remembered", and coercing here is what keeps a hand-built {Config} from
      # carrying a shape the loader would have refused.
      def self.coerce(answers) = answers.is_a?(self) ? answers : from(answers)

      # @return [Answers] the value an absent table yields
      def self.empty = EMPTY

      # @raise [Config::Refusal]
      def self.check!(table, path: nil)
        raise Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        # A silently dropped `[[approval.alow]]` reads as an answer that was
        # remembered and is not, so the human is asked again and cannot see why.
        raise Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) unless unknown.empty?

        table.each { |key, list| check_list!(key, list, path:) }
      end

      # `[[approval.allow]]` -- the list one entry sits in.
      def self.entry_table(key) = "[[approval.#{key}]]"

      def self.check_list!(key, list, path: nil)
        check_list_shape!(key, list, path:)

        list.each { |entry| check_entry!(key, entry, path:) }
      end

      # Public because {#initialize} runs it too, and one copy rather than one
      # per caller: the parse and the constructor drifted apart precisely
      # because each carried its OWN copy of a shape rule ({#named} records what
      # that cost). The constructor's side passes no path -- a value built by
      # hand names no config file to open.
      def self.check_list_shape!(key, list, path: nil)
        raise not_a_list(key, list, path:) unless list.is_a?(Array)
      end

      # `allow = "read_file"` -- the single-table form of a key that is a list
      # of tables. The fix is a syntax change (`[[approval.allow]]`), not a
      # value change, so the message spells the shape rather than the value.
      #
      # @return [Config::Refusal]
      def self.not_a_list(key, list, path: nil)
        Refusal.new("#{key} is a list of tables (#{entry_table(key)}), got #{list.class}",
                    path:, table: TABLE, key:, value: list)
      end

      # Public because {#initialize} runs it too: a value built by hand carries
      # entries that never came through {.from}, and the closed-set check
      # belongs to the VALUE as much as to the parse ({Epics#initialize}).
      def self.check_entry!(key, entry, path: nil)
        raise malformed_entry(key, entry, "must be a table", path:) unless entry.is_a?(Hash)
        # Blank as well as absent: `tool = ""` names no tool, so it can never
        # match a call, and this class exists to refuse exactly that.
        raise malformed_entry(key, entry, "needs a #{TOOL} name", path:) unless named?(entry)

        check_fields!(key, entry, path:)
      end

      def self.named?(entry) = entry[TOOL].is_a?(String) && !entry[TOOL].strip.empty?

      # A tool-wide denial has no call shape by definition, so an `input`
      # beside it is a misunderstanding that would otherwise sit in the file
      # doing nothing. A shaped answer needs the key even when the tool takes
      # no fields (`input = {}`), because an entry with no input silently
      # matches only a call whose every field is unset -- which is not what
      # anyone writing it means.
      def self.check_fields!(key, entry, path: nil)
        known = key == TOOL_WIDE ? [TOOL] : [TOOL, INPUT]
        extra = entry.keys - known
        raise malformed_entry(key, entry, "has no #{extra.map(&:inspect).join(", ")}", path:) unless extra.empty?
        raise malformed_entry(key, entry, "needs an #{INPUT} table", path:) if missing_input?(key, entry)

        check_input!(key, entry, path:)
      end

      def self.missing_input?(key, entry) = key != TOOL_WIDE && !entry.key?(INPUT)

      def self.check_input!(key, entry, path: nil)
        input = entry.fetch(INPUT, {})
        raise malformed_entry(key, entry, "#{INPUT} must be a table", path:) unless input.is_a?(Hash)

        loose = input.reject { |_, value| scalar?(value) }
        return if loose.empty?

        raise malformed_entry(key, entry, "#{INPUT} #{loose.keys.map(&:inspect).join(", ")} is not a scalar", path:)
      end

      # What a {Tool::Input} field can hold, which is also what TOML can carry
      # back unchanged. A datetime parses fine and could never match a call, so
      # it is refused with the arrays and tables.
      def self.scalar?(value) = value.is_a?(String) || value.is_a?(Numeric) || [true, false].include?(value)

      # One entry that cannot mean anything: no tool, a key this table does not
      # have, or an input carrying something that is not a scalar. Every entry
      # in this file was written to be MATCHED against a live call, and an entry
      # that can never match is indistinguishable from an answer that was never
      # remembered.
      #
      # @return [Config::Refusal]
      def self.malformed_entry(key, entry, detail, path: nil)
        Refusal.new("#{detail}: #{entry.inspect}", path:, table: entry_table(key), key:, value: entry)
      end

      private_class_method :check_list!, :named?, :check_fields!, :missing_input?, :check_input!,
                           :entry_table, :not_a_list, :malformed_entry

      # Validated in the value's own constructor as well as in {.from}, the
      # {Epics#initialize} precedent: an entry that CONSTRUCTS but can never
      # match is an answer silently forgotten.
      def initialize(allow: [], deny: [], deny_tools: [])
        super(allow: settled(ALLOW, allow), deny: settled(DENY, deny), deny_tools: named(deny_tools))
      end

      private

      # Re-frozen rather than stored as handed over: the caller's Hashes are
      # theirs to keep mutating, and this value rides inside a
      # Ractor-shareable {Config}.
      def settled(key, entries)
        self.class.check_list_shape!(key, entries)

        entries.map do |entry|
          self.class.check_entry!(key, entry)
          { TOOL => -entry[TOOL], INPUT => scalars(entry.fetch(INPUT, {})) }.freeze
        end.freeze
      end

      # The third member earns the SAME constructor guarantee as the other two,
      # through the same validator: `deny_tools: [42]` used to construct and
      # store `"42"`, a refusal for a tool that does not exist, silently
      # forgotten -- while `.from` refused it. One of them was lying.
      def named(names)
        self.class.check_list_shape!(TOOL_WIDE, names)

        names.map do |name|
          self.class.check_entry!(TOOL_WIDE, { TOOL => name })
          -name.to_s
        end.freeze
      end

      # Interning is deliberate for the field NAMES (a bounded set) and
      # deliberately absent for the values ({Risk::Keepsake.scalar}'s reason:
      # an unbounded tool argument in the fstring table leaks for the life of
      # the process).
      def scalars(input)
        input.to_h { |field, value| [-field.to_s, value.is_a?(String) ? value.dup.freeze : value] }.freeze
      end

      EMPTY = new.freeze
      private_constant :EMPTY
    end
  end
end
