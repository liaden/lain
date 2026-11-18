# frozen_string_literal: true

module RuboCop
  module Cop
    module Lain
      # Only the frontend may write to the terminal. A stray write elsewhere scribbles
      # over the chat pane and the line editor the frontend is painting.
      #
      # The rule earns its keep by forcing a shim, not by catching slips:
      # Lain::Provider::HTTP::Logging::SinkLogger exists because RubyLLM's Faraday
      # logger defaults to $stdout and this rule refused it.
      #
      # @example
      #   # bad
      #   puts "done"
      #   $stderr.write(line)
      #
      #   # good
      #   sink.puts("done")
      class TerminalOutput < Base
        MSG = "`%<name>s` writes to the terminal. Write to an injected Lain::Sink or push onto a " \
              "Lain::Channel; only lib/lain/frontend/ touches the terminal. A file is exempted only in " \
              ".rubocop.yml's Lain/TerminalOutput Exclude, with its reason."

        RESTRICT_ON_SEND = %i[puts print warn].freeze
        TERMINAL_GLOBALS = %i[$stdout $stderr].freeze
        TERMINAL_CONSTANTS = %i[STDOUT STDERR].freeze

        # A call with a receiver (`sink.puts`) is somebody else's IO.
        def on_send(node)
          flag(node.loc.selector, node.method_name) unless node.receiver
        end

        def on_gvar(node)
          flag(node, node.name) if TERMINAL_GLOBALS.include?(node.name)
        end

        def on_gvasgn(node)
          flag(node.loc.name, node.name) if TERMINAL_GLOBALS.include?(node.name)
        end

        def on_const(node)
          flag(node, node.source) if TERMINAL_CONSTANTS.include?(node.short_name)
        end

        private

        def flag(range, name) = add_offense(range, message: format(MSG, name:))
      end
    end
  end
end
