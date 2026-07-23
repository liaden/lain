# frozen_string_literal: true

module Lain
  module CLI
    # The `you>` slash-command namespace (T9): {Registry} dispatches a
    # registered `/word` ahead of the skill middleware, every command is one
    # message -- call(args, env) over the frozen {Env} Wiring assembles once --
    # and each RETURNS rendered text or a Repl action, never output (the Repl's
    # boundary renderer delivers it; output discipline holds mechanically).
    #
    # This index owns the command/* requires: a later command card adds its
    # leaf require here plus one register line in Wiring, and nothing else.
    module Command
    end
  end
end

require_relative "command/env"
require_relative "command/registry"
require_relative "command/help"
require_relative "command/quit"
require_relative "command/rewind"
require_relative "command/fork"
require_relative "command/status"
require_relative "command/sessions"
require_relative "command/inbox"
require_relative "command/surface"
require_relative "command/approve"
require_relative "command/yolo"
require_relative "command/model"
