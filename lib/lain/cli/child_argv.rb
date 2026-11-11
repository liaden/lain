# frozen_string_literal: true

require "shellwords"

module Lain
  module CLI
    # Every `lain` command line a running chat hands to another process (a
    # forked window, a /btw popup, a fleet watch window, a restarted pane),
    # built from the LIVE run instead of from whatever the launching shell
    # happened to type. The words are for {PaneCommand.call}'s recipe, which
    # escapes them, or for {#printable}, which a human pastes.
    class ChildArgv
      SESSION_PICKERS = %w[--resume --fork].freeze

      # What a child chat never inherits: it either names a session of its own
      # or would ask the parent's first question again.
      DROPPED = [*SESSION_PICKERS, "--prompt"].freeze

      class << self
        # @param args [Array<String>] chat's own flags
        # @param drop [Array<String>] the flags to remove, each with its value
        # @return [Array<String>] args without those flags; a bare flag takes the next word that is not a flag
        def fresh(args, drop: DROPPED)
          valued = false
          args.reject do |arg|
            named = drop.include?(arg)
            gone = named || arg.start_with?(*drop.map { |flag| "#{flag}=" }) || (valued && !arg.start_with?("-"))
            valued = named
            gone
          end
        end

        # @param root [String] the run's project root
        # @param cwd [String] where the run sits inside the root
        # @param profile [RunProfile] the run's resolved profile, of which only the typed fields travel
        # @param chronicle [#journal_path] the run's session file, read at each use
        # @return [ChildArgv] a child launches with no --nvim, --windows or --input, which stay the parent's
        def for(root:, cwd:, chronicle:, profile:)
          new(root:, cwd:, journal_path: -> { chronicle.journal_path },
              typed: profile.to_options.slice(*profile.typed), chat_flags: [])
        end

        # A child's argv keeps what the human typed, as the parent's own does; a line lain SHOWS
        # masks URL credentials, so a hint is not a second place they are written.
        #
        # @param argv [Array<String>] a command line from {#chat} or {#watch}
        # @return [String] one shell-quoted line a human can run, URL credentials masked
        def printable(argv) = mask("lain #{Shellwords.join(argv)}")

        # @param text [String] words about to be shown to the human
        # @return [String] the text with `scheme://user:secret@` read as `scheme://***@`
        def mask(text) = text.gsub(%r{(://)[^/\s@]*@}, '\1***@')

        # A command line for a run that resolved no project and keeps no journal.
        def bare = new(root: nil, cwd: nil, journal_path: -> {}, typed: {}, chat_flags: [])
      end

      # @param root [String, nil] the live run's project root, which a child started elsewhere cannot guess
      # @param cwd [String, nil] where the live run sits inside the root
      # @param journal_path [#call] answers the session file now, because `/keep` moves it after promotion
      # @param typed [Hash{Symbol=>Object}] the model flags the human typed, by profile field
      # @param chat_flags [Array<String>] the chat's own flags as launched
      def initialize(root:, cwd:, journal_path:, typed:, chat_flags:)
        @root = root
        @cwd = cwd
        @journal_path = journal_path
        @typed = typed
        @chat_flags = chat_flags
        freeze
      end

      # @param extra [Array<String>] words kept as given, after the live run's flags
      # @return [Array<String>] a `chat` command line, `--resume`, `--fork` and `--prompt` left off the run's flags
      def chat(*extra)
        ["chat", *pins("--root" => @root, "--cwd" => @cwd), *typed_flags, *self.class.fresh(@chat_flags), *extra]
      end

      # @return [Array<String>] a `watch` command line tailing this chat's session
      def watch = ["watch", *pins("--session" => @journal_path.call)]

      private

      def pins(flags) = flags.compact.flat_map { |flag, value| [flag, value.to_s] }

      def typed_flags = pins(@typed.transform_keys { |field| "--#{field.to_s.tr("_", "-")}" })
    end
  end
end
