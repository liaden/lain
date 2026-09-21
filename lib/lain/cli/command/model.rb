# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/model <id>`: writes the {Context::ModelSwitch} slot the session's
      # Context reads at render time, so the NEXT Request carries the new
      # model -- Agent's @context stays construction-fixed, the slot is the
      # seam. The id is passed VERBATIM: an unknown provider/model fails
      # loudly at dispatch (the provider's own refusal), never a silent
      # fallback here. The switch journals the change attributed to this
      # surface. Bare `/model` reports the model in force.
      class Model
        SURFACE = "tty"

        def initialize = freeze

        def name = "model"

        def usage = "/model [id] -- show the model in force, or switch the next turn's model"

        def call(args, env)
          id = args.strip
          return "model: #{env.model_switch.current}" if id.empty?

          from = env.model_switch.current
          env.model_switch.switch(id, surface: SURFACE)
          "model: #{from} -> #{id} (next turn; an unknown id fails at dispatch)"
        end
      end
    end
  end
end
