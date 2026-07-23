# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/sessions` (T13): Command::Env's `sessions` reader IS
      # {Lain::CLI::Sessions} (T3's `#listing(all:)`) -- this command adds
      # nothing but the argument parse, rendering its answer verbatim.
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
