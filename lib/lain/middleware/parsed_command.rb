# frozen_string_literal: true

require "delegate"

module Lain
  module Middleware
    # Parses a bash call's command once, at the head of a gated stack, so each
    # member and ladder rung below, and the tool itself, reads one
    # {Shell::Parse::Result} instead of parsing the same text again, and the
    # members that read paths share one {Shell::Named} of it, so no two spell
    # the directory differently and name different paths.
    #
    # The ladder is asked a context rather than the env, so the parse also rides
    # on the context, read by respond_to? as {Approval::Escalation::Noted} is,
    # and so does the call's {Approval::Disclosure}: built here rather than in a
    # rung, because a rung that adds a note changes what the rungs below it see.
    class ParsedCommand < Base
      # @!attribute parsed_command [Shell::Parse::Result, nil] nil when the call names no command
      # @!attribute named_command [Shell::Named] the paths the gate reads off that parse
      # @!attribute disclosure [Approval::Disclosure] what the call's files hold and where it sends
      class Parsed < SimpleDelegator
        attr_reader :parsed_command, :named_command

        # @param context [Object] the context the call was asked in
        # @param parsed [Shell::Parse::Result, nil]
        # @param named [Shell::Named]
        # @param disclose [#call] `-> Approval::Disclosure`, asked at most once
        def initialize(context, parsed, named, disclose)
          super(context)
          @parsed_command = parsed
          @named_command = named
          @disclose = disclose
        end

        # Computed on first read, so a call a rule approves never reads its files;
        # a memo adds no note, so no rung below sees anything it would not have.
        def disclosure = @disclosure ||= @disclose.call
      end

      # @param context [Object]
      # @param effect [Lain::Effect]
      # @param home [String, nil]
      # @return [Shell::Named] the paths a {ParsedCommand} left on the context, else a fresh parse's
      def self.named_in(effect, context, home:)
        context.respond_to?(:named_command) ? context.named_command : Shell::Named.for_call(effect, context, home:)
      end

      # A member between the gate's parse and its reader may rewrite the command, so a parse is used only for
      # the text it was made of.
      #
      # @param command [Object] the command a reader is about to judge or run
      # @param context [Object]
      # @return [Shell::Parse::Result, nil] the context's parse of exactly that command, else nil
      def self.carried(command, context)
        parsed = context.respond_to?(:parsed_command) ? context.parsed_command : nil
        parsed if parsed && parsed.source == command
      end

      # @param home [String, nil] for a `~` in the command, as the session's path policy reads it
      # @param scan [#call] `path -> Approval::Disclosure::Scanner::Count or nil`, what a file the call
      #   reads holds; required, so no stack reads the live disk by default
      def initialize(scan:, home: nil)
        @home = home
        @scan = scan
        super()
        freeze
      end

      def call(env, &app)
        effect = ::Lain::Sensitivity::Policy.unwrapped(env.fetch(:effect))
        return downstream(env, &app) unless effect.tool_call? && effect.name == "bash"

        context = env[:context]
        parsed = parse(effect)
        named = Shell::Named.for_call(effect, context, home: @home, parsed:)
        # A caller threading no session has no context to carry it.
        downstream(env.merge(named:, context: context && carrying(context, parsed, named)), &app)
      end

      private

      def carrying(context, parsed, named)
        Parsed.new(context, parsed, named, -> { disclosure(context, parsed, named) })
      end

      # Named from the session's directory, the one the row shows beside the call.
      def disclosure(context, parsed, named)
        Approval::Disclosure.of(named, parsed&.stages || [], cwd: ::Lain::Session.cwd_of(context).to_s, scan: @scan)
      end

      def parse(effect)
        command = Shell::Named.field_of(effect.input, Shell::Named::COMMAND)
        Shell::Parse.new.call(command) if command.is_a?(String)
      end
    end
  end
end
