# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/keep` (T17): promote this ephemeral (--btw) session in place --
      # {Chronicle#promote!} renames journal+WAL off the `.btw` mark, so the
      # clean-exit reap skips it and it survives as an ordinary chained fork
      # (`lain sessions` lists it).
      #
      # WHEN it may run is the load-bearing half (T3 panel, binding):
      # {Chronicle::RelocatableSpool#relocate} is unsynchronized with the
      # ResponseWal monitor, so promote! must run strictly BETWEEN round
      # trips. Command dispatch IS between the MAIN agent's asks by
      # construction -- {Repl#converse} dispatches synchronously and an ask
      # completes inside the dispatch that started it ({Repl#respond}'s Sync)
      # -- so the one way a round trip can be mid-flight here is an adopted
      # fleet actor, whose initial turn runs under the supervisor's reactor
      # ACROSS asks. A `:running` registration cannot be told apart from a
      # parked-and-quiescent one from outside the actor, so /keep refuses
      # conservatively while any is running.
      class Keep
        def initialize = freeze

        def name = "keep"

        def usage = "/keep -- keep this ephemeral (--btw) session: promote it into a durable one"

        def call(_args, env)
          refuse_mid_flight!(env.supervisor)
          promoted = promotable(env).promote!
          "kept: #{File.basename(promoted)} -- now a durable chained fork (lain sessions lists it)"
        end

        private

        def refuse_mid_flight!(supervisor)
          roles = supervisor.select { |registration| registration.state == :running }.map(&:role)
          return if roles.empty?

          # Name the concrete unblocking action: a PARKED fleet actor reads
          # :running forever (its initial turn is spooling under the
          # supervisor's reactor across asks), so "wait" alone could leave
          # /keep refusing with no way out -- stopping the actors is the exit.
          raise Error, "wait for the turn to settle: actors still running (#{roles.join(", ")}) -- promotion " \
                       "is safe only between round trips; stop the actors (or let them finish), then /keep again"
        end

        # The named refusals fire before promote! so a /keep outside its
        # domain reads as policy, never as a wrapped ArgumentError from the
        # rename machinery.
        def promotable(env)
          path = env.chronicle.journal_path
          raise Error, "no session record to promote (--no-journal)" if path.nil?
          raise Error, "#{File.basename(path)} is not ephemeral; only a --btw session needs /keep" unless
            Paths.ephemeral?(path)

          env.chronicle
        end
      end
    end
  end
end
