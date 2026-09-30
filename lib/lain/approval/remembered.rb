# frozen_string_literal: true

module Lain
  module Approval
    # The answers a human already gave, applied so the same question is never
    # put to them twice.
    #
    # Almost every tool-approval UI offers permanent-YES and nothing else, so a
    # user repeatedly asked about something they will never want answers `n`
    # forever or eventually answers `y` out of fatigue. BOTH directions are
    # rememberable here, at Emacs' three strengths.
    #
    # == What each strength actually covers
    #
    # `allow` and `deny` match an EXACT call shape -- the tool plus every set
    # field -- so a remembered `deny` on `bash(command: "rm -rf /tmp/x")` does
    # NOT cover the same command with `timeout: 120` beside it. That is what
    # makes them safe to write from the prompt, and it is also their limit. The
    # durable refusal is `deny_tool`, which names the tool and nothing else.
    #
    # == Precedence: the strictest remembered answer wins
    #
    # `deny_tool` outranks `deny`, which outranks `allow`. A file carrying both
    # answers for one shape is a human who changed their mind and left the old
    # line behind, and the REFUSAL is the only reading safe to be wrong about.
    # Nothing is deduplicated on write: the file is the human's, and an editor
    # that tidies it is an editor that can lose a line they meant.
    #
    # == Where it is kept, and why there
    #
    # The `approval` verb of `.lain/config.rb` -- greppable, diffable, reviewable in a PR, revocable
    # where every other setting lives. The approval set is part of the
    # experimental configuration, so on a bench it has to be recorded with
    # everything else rather than in a dotfile nobody diffs.
    #
    # {Config::Answers} reads and validates the table; this class interprets it.
    # A table's SHAPE is the config's business, its MEANING is the owner's.
    #
    # READING is deliberately unguarded: a chain that refused to honour a
    # hand-written entry would make "edit the config yourself" a lie.
    class Remembered < Rule
      # Frozen explicitly: the locator composes a fresh String per call, where
      # the literal this replaced was frozen by the magic comment.
      WHERE = ProjectDir.config.freeze
      # Interpolation makes these mutable Strings whatever the magic comment
      # says, and a reason travels into the Journal.
      TOOL_REFUSED = "remembered in #{WHERE}: `deny_tool` in its `approval` block refuses every %s call".freeze
      SHAPE_REFUSED = "remembered in #{WHERE}: `deny` in its `approval` block refuses this %s call".freeze
      SHAPE_ALLOWED = "remembered in #{WHERE}: `allow` in its `approval` block permits this %s call".freeze

      Entry = Data.define(:tool, :input)

      # One remembered call shape, normalized so what a config row says
      # and what a live {Rule::Call} looks like are comparable by value. ONE
      # normalizer behind two doors, because two normalizers would drift and the drift's
      # shape is an answer written down that then never matches anything.
      class Entry
        # Reopened rather than written in the `Data.define` block: a constant
        # there is scoped to the enclosing module, not the Data class.

        # A live call and a config row, each handing over the same two fields.
        def self.for_call(call) = new(tool: call.tool_name, input: call.input.attributes)

        def self.from_table(row) = new(tool: row[Config::Answers::TOOL], input: row.fetch(Config::Answers::INPUT, {}))

        def initialize(tool:, input:)
          super(tool: -tool.to_s, input: settle(input))
        end

        private

        # An unset optional field is `nil` in `attributes` and CANNOT be
        # written to TOML, which has no null. BOTH sides drop it, so "the file
        # is silent about `timeout`" and "the call left `timeout` unset" are one
        # shape rather than two that can never match.
        def settle(input)
          input.to_h { |field, value| [-field.to_s, value.is_a?(String) ? value.dup.freeze : value] }
               .compact.freeze
        end
      end

      # @param config [Lain::Config] a loaded project config
      # @return [Remembered]
      def self.from(config)
        answers = config.approval
        new(allow: answers.allow, deny: answers.deny, deny_tools: answers.deny_tools)
      end

      # @param allow [Enumerable<Entry, Hash>] call shapes to allow
      # @param deny [Enumerable<Entry, Hash>] call shapes to deny
      # @param deny_tools [Enumerable<#to_s>] tools to deny outright
      def initialize(allow: [], deny: [], deny_tools: [])
        super()
        @allow = entries(allow)
        @deny = entries(deny)
        @deny_tools = Set.new(deny_tools.map { |name| -name.to_s }).freeze
        freeze
      end

      # A remembered set nobody wrote to decides nothing, which makes this rule
      # its own Null Object -- no second class, and no call site guards on nil.
      def empty? = @allow.empty? && @deny.empty? && @deny_tools.empty?

      # @param call [Rule::Call] a call whose input is already validated
      # @return [Rule::Decision, nil] nothing when this call shape was never
      #   answered, which is what escalates it to a human
      def decide(call)
        entry = Entry.for_call(call)
        return deny(call, because: format(TOOL_REFUSED, entry.tool)) if @deny_tools.include?(entry.tool)
        return deny(call, because: format(SHAPE_REFUSED, entry.tool)) if @deny.include?(entry)
        return allow(call, because: format(SHAPE_ALLOWED, entry.tool)) if @allow.include?(entry)

        nil
      end

      private

      # Sets, because this runs on every gated call and the question is
      # membership; frozen, because a rule rides wherever a chain rides.
      def entries(rows)
        Set.new(rows.map { |row| row.is_a?(Entry) ? row : Entry.from_table(row) }).freeze
      end
    end
  end
end
