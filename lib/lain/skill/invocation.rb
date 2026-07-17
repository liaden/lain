# frozen_string_literal: true

module Lain
  # Invocation grammar for a `you>` line: `/skill`, `@role/skill`, and
  # `@role[/skill]`. See {Skill::Invocation}. Reopens the {Skill} value class
  # (`Skill = Data.define`) to nest the parser under it.
  class Skill
    # A parsed `you>` line naming a skill invocation, or the frozen-value
    # counterpart of "this line is ordinary text" ({.parse} returns `nil`
    # rather than an instance for that case).
    #
    # Three grammar shapes, disambiguated by the leading marker:
    #
    #   "/skill args"          -> role: nil,       context: nil
    #   "@role/skill args"     -> role: "role",    context: :inherit
    #   "@role[/skill] args"   -> role: "role",    context: :fresh
    #
    # == Disambiguation (not-an-invocation vs {Malformed})
    #
    # A line that does not match one of the three shapes above is NOT
    # necessarily malformed -- ordinary prose legitimately starts with `/`
    # (a path) or `@` (a mention, an email). {.parse} returns `nil` for
    # those, leaving the caller's `env[:text]` untouched. The rule: only a
    # leading token that unambiguously ATTEMPTS the grammar raises loudly.
    #
    # - A leading `/` never raises. `/etc/passwd was modified` is
    #   indistinguishable, at the grammar level, from a slash command typo,
    #   and paths vastly outnumber typos in ordinary prose -- so an
    #   unparseable `/`-line is just text, silently.
    # - A leading `@` raises only when its token (up to the first
    #   whitespace) also contains a `/`. No legitimate mention or email
    #   opens with `@word/` or `@/word` -- that shape occurs only as a
    #   broken attempt at `@role/skill` or `@role[/skill]` (empty role,
    #   empty skill, unbalanced bracket), so it fails loudly instead of
    #   silently discarding the user's intent. A bare `@joel ...` (no `/`)
    #   is ordinary text and returns `nil`.
    Invocation = Data.define(:skill, :role, :context, :args) do
      # `role` and `context` default nil (the in-line shape); `args`
      # defaults to "" (a skill invoked with no remainder). Values are
      # normalized to frozen Strings/Symbols so an instance stays
      # `Ractor.shareable?` regardless of how the caller built it.
      def initialize(skill:, role: nil, context: nil, args: "")
        super(
          skill: skill.to_s.freeze,
          role: role&.to_s&.freeze,
          context: context&.to_sym,
          args: args.to_s.freeze
        )
      end

      def inline? = context.nil?
      def inherit? = context == :inherit
      def fresh? = context == :fresh
    end

    # Reopened rather than folded into the `Data.define` block above: per
    # CLAUDE.md's known trap, a `class`/constant written INSIDE that block is
    # lexically scoped to this file's enclosing module (`Lain::Skill`), not
    # to the Data-defined class -- `Malformed` would land as
    # `Lain::Skill::Malformed` instead of `Lain::Skill::Invocation::Malformed`.
    # Reopening puts it, and the grammar regexes, where they read (see
    # `lib/lain/request.rb` for the same pattern with `SYSTEM_PREFIX`).
    class Invocation
      class Malformed < Error; end

      IDENTIFIER = /[\w-]+/

      INLINE = %r{\A/(?<skill>#{IDENTIFIER})(?:\s+(?<args>.*))?\z}m
      FRESH = %r{\A@(?<role>#{IDENTIFIER})\[/(?<skill>#{IDENTIFIER})\](?:\s+(?<args>.*))?\z}m
      INHERIT = %r{\A@(?<role>#{IDENTIFIER})/(?<skill>#{IDENTIFIER})(?:\s+(?<args>.*))?\z}m

      # Tried in this order for a `@`-led line: {FRESH} before {INHERIT}
      # because the bracket form is the more specific shape -- not that
      # order is actually load-bearing, since {IDENTIFIER} excludes `[`, so
      # the two never both match the same line.
      ROLE_BOUND_GRAMMAR = [[FRESH, :fresh], [INHERIT, :inherit]].freeze

      class << self
        # The parsed invocation, or `nil` if +text+ is not an invocation.
        # Raises {Malformed} for a line that attempts the grammar and breaks
        # it -- see the disambiguation rule documented above.
        def parse(text)
          line = text.to_s
          return parse_inline(line) if line.start_with?("/")
          return parse_role_bound(line) if line.start_with?("@")

          nil
        end

        private

        def parse_inline(line)
          match = INLINE.match(line)
          match && from_match(match, context: nil)
        end

        # A leading token with no `/` is ordinary `@`-prose (a mention, an
        # email) -- not an attempt at this grammar, so it is not malformed.
        def parse_role_bound(line)
          return nil unless line[/\A\S+/].include?("/")

          regex, context = ROLE_BOUND_GRAMMAR.find { |candidate, _| candidate.match?(line) }
          raise Malformed, "malformed skill invocation: #{line.inspect}" unless regex

          from_match(regex.match(line), context:)
        end

        def from_match(match, context:)
          new(skill: match[:skill], role: match.names.include?("role") ? match[:role] : nil,
              context:, args: match[:args] || "")
        end
      end
    end
  end
end
