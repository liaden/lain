# frozen_string_literal: true

require "shellwords"

module Lain
  module CLI
    module Command
      # One parse for every `/command` that reads flags, switches and a fixed
      # count of positionals off its line -- `/survey`, `/review` and
      # `/implement-epic` each hand-rolled `words.split`, which is why a
      # directory named `my notes` could not be surveyed, an extra word after
      # the target vanished with no refusal, and `--base x --base y` silently
      # kept the second `x`. {.parse} splits with {Shellwords} instead, so a
      # quoted word survives a space, and refuses the other two by NAME rather
      # than let them slide: a flag typed twice, and a bare word beyond what
      # the command declared it reads.
      #
      # What stays with the CALLER is the needs-value refusal (a declared flag
      # given no value, or a value that is itself another flag): that
      # sentence names the THING missing -- "a ref", "a scope", "a value" --
      # and only the command knows which noun. {#pairs} on the result hands
      # back exactly what the callers' own checks already read: a value of
      # `nil`, or a String starting with `--`.
      class Args
        UNTERMINATED_QUOTE = "%<text>s has no closing quote -- %<usage>s"
        UNKNOWN_FLAG = "%<word>s is not a flag /%<name>s can read -- %<usage>s"
        DUPLICATE_FLAG = "%<word>s was given more than once -- %<usage>s"
        EXTRA_POSITIONAL = "%<word>s is more than /%<name>s takes -- %<usage>s"

        # `pairs` keys on the BARE flag name (`"scope"`, not `"--scope"`), the
        # way every caller's own needs-value check already reads it.
        # `switches` keys on the Symbol {Command::Survey#switched} and
        # {Command::Review#switched} already build their `Parsed` values from.
        Parsed = Data.define(:positionals, :pairs, :switches)

        # @param text [String] the line after the verb
        # @param name [String] the command word, named in a refusal so a human
        #   reads which command is speaking
        # @param usage [String] appended to every refusal here
        # @param flags [Array<String>] the `--flag`s that take the word after
        #   them
        # @param switches [Array<String>] the `--flag`s that take nothing
        # @param positionals [Integer] how many bare words this command reads
        # @return [Parsed]
        def self.parse(text, name:, usage:, flags: [], switches: [], positionals: 1)
          new(name:, usage:, flags:, switches:, positionals:).parse(text)
        end

        def initialize(name:, usage:, flags:, switches:, positionals:)
          @name = name
          @usage = usage
          @flags = flags
          @switches = switches
          @positionals = positionals
          freeze
        end

        def parse(text)
          words = split(text)
          located = locate(words)
          refuse_duplicate!(located)
          Parsed.new(positionals: leftover(words, located), pairs: located.values.to_h, switches: switched(words))
        end

        private

        def split(text)
          Shellwords.split(text.to_s)
        rescue ArgumentError
          raise Lain::Error, format(UNTERMINATED_QUOTE, text: text.to_s, usage: @usage)
        end

        # Keyed by INDEX, not by flag name, so `--base x --base y` shows up as
        # TWO entries here -- {#refuse_duplicate!} is what collapses them,
        # deliberately, rather than a Hash silently keeping the last write.
        def locate(words)
          at = words.each_index.select { |index| @flags.include?(words[index]) }
          at.to_h { |index| [index, [words[index].delete_prefix("--"), words[index + 1]]] }
        end

        def refuse_duplicate!(located)
          repeated = located.values.map(&:first).tally.select { |_, count| count > 1 }.keys
          return if repeated.empty?

          refuse!(DUPLICATE_FLAG, repeated.map { |flag| "--#{flag}" })
        end

        def switched(words) = @switches.to_h { |switch| [switch.delete_prefix("--").to_sym, words.include?(switch)] }

        # Everything not consumed as a declared flag, a declared flag's value,
        # or a declared switch. A word beginning with `--` here is nobody's --
        # neither {@flags} nor {@switches} claims it -- so it is refused by
        # name rather than folded into the positionals it plainly is not one
        # of; what remains past {@positionals} is refused the same way.
        def leftover(words, located)
          rest = words.reject.with_index do |word, index|
            located.key?(index) || located.key?(index - 1) || @switches.include?(word)
          end
          refuse!(UNKNOWN_FLAG, rest.grep(/\A--/))
          refuse!(EXTRA_POSITIONAL, rest.reject { |word| word.start_with?("--") }.drop(@positionals))
          rest
        end

        def refuse!(sentence, words)
          raise Lain::Error, format(sentence, word: words.join(", "), name: @name, usage: @usage) if words.any?
        end
      end
    end
  end
end
