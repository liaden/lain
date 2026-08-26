# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/sessions`: Command::Env's `sessions` reader IS
      # {Lain::CLI::Sessions}, whose `#listing(all:)` answers -- this command
      # adds nothing but the argument parse, rendering that answer verbatim.
      class Sessions
        ALL_FLAGS = %w[--all all].freeze

        def initialize = freeze

        def name = "sessions"

        def usage = "/sessions [--all] -- list recorded sessions, newest first (--all includes ephemeral .btw ones)"

        def call(args, env) = env.sessions.listing(all: ALL_FLAGS.include?(args.to_s.strip))
      end
    end
  end
end
