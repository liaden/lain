# frozen_string_literal: true

require "thor"

module Lain
  module CLI
    module Exe
      # What the REAL argv said, kept because Thor's parsed `options` cannot say
      # it. `extend`ed rather than written as `def self.` so this class's own body
      # stays the commands (`Metrics/ClassLength`); `super` still reaches Thor's
      # `start`, which sits behind this module in the singleton ancestry.
      module Argv
        # A flag written before `--` that took its value from PAST the separator.
        # Its own class because the answer is a sentence about argv, not about
        # anything the command does -- the shape `Up::Cockpit::SwallowedFlag` used
        # to name, retargeted: `--nvim` no longer takes a value, but the socket did
        # not stop existing, it moved to `--nvim-socket`, which does and which sits
        # in the same slot. The guard's reason outlived its subject.
        class SwallowedFlag < ::Thor::Error
          def initialize(written, delivered)
            super("`--` did not forward what it looks like it forwards: #{written.inspect} follows the " \
                  "separator, but #{delivered.inspect} is what would reach `chat`. A value-taking `up` flag " \
                  "written LAST before `--` takes the first forwarded token as its own value, and the PATH " \
                  "you typed is what gets forwarded in its place. Write that flag with an `=` -- " \
                  "`--nvim-socket=SOCKET`, `--session=NAME` -- so its value cannot come from past `--`.")
          end
        end

        # Thor swallows the "--" separator before a command method sees its argv,
        # so remember what followed it. `up` forwards trailing args to the chat
        # window ONLY from past `--`; anything else is a stray positional
        # {Boundary#refuse_strays!} turns into a loud error.
        #
        # The TOKENS, not merely their count. Thor leaves everything after `--`
        # unparsed and hands it over as ordinary positionals -- verified against
        # this bundle's Thor, flags `up` itself declares included -- so `lain up --
        # --provider ollama` reaches `def up(path = nil, *chat_args)` with
        # "--provider" sitting in PATH's own slot, and only what was really in argv
        # puts it back.
        #
        # A count alone is not enough, and the first edition of this used one. Thor
        # SKIPS the separator when the flag before it still wants a value, so
        # `lain up /tmp --nvim-socket -- --provider ollama` hands over
        # `["/tmp", "ollama"]` -- two positionals for two forwarded tokens, so the
        # arithmetic still balances while the PATH the user typed has silently
        # become a chat flag. Comparing the delivered tail against the written
        # tokens is what tells those two apart; see {SwallowedFlag}.
        def start(given_args = ARGV, config = {})
          separator = given_args.index("--")
          @forwarded = separator ? given_args[(separator + 1)..] : []
          super
        end

        # A command's positionals, cut back into its OWN and the ones argv's `--`
        # forwarded.
        #
        # @param positionals [Array<String>]
        # @return [Array(Array<String>, Array<String>)]
        # @raise [SwallowedFlag] when the tail Thor delivered is not the tail argv wrote
        def split_forwarded(positionals)
          forwarded = @forwarded || []
          return [positionals, []] if forwarded.empty?

          tail = positionals.last(forwarded.length)
          raise SwallowedFlag.new(forwarded, tail) unless tail == forwarded

          [positionals[0...-forwarded.length], tail]
        end
      end
    end
  end
end
