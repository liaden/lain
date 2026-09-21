# frozen_string_literal: true

module Lain
  module CLI
    # The `you>` slash-command namespace: {Registry} dispatches a registered
    # `/word` ahead of the skill middleware, every command is one message --
    # call(args, env) over the frozen {Env} Wiring assembles once -- and each
    # RETURNS rendered text or a Repl action, never output (the Repl's boundary
    # renderer delivers it; output discipline holds mechanically).
    #
    # This index owns the command/* requires: a later command card adds its
    # leaf require here plus one register line in Wiring, and nothing else.
    module Command
    end
  end
end
