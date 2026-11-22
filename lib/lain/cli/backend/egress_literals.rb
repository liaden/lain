# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # The values every provider a {Backend} builds refuses to send, held for
      # {Provider::HTTP::EgressGuard}. Late-bound because providers are built
      # before whatever owns the run's secrets source; unbound it raises, so a
      # request sent before the bind is refused rather than sent unchecked.
      class EgressLiterals
        REBOUND = "the egress literals are already bound to another source and ledger (or sensitivity policy)"

        # @param configured [#http_entries] the run's configured middleware, which the guard follows
        # @param identity [#alias] the home path, account and host every request body names as placeholders
        def initialize(configured = Config::Middleware.empty, identity: Sensitivity::Secrets::Identity.session)
          @configured = configured
          @identity = identity
        end

        # A chat binds its board's own source, so nothing walks the history twice,
        # and its one ledger, so a value a human released at a secret path is no
        # longer refused. A copy of the file at an ordinary path is somewhere the
        # human never agreed to send from, so its release lifts nothing.
        #
        # @param source [#egress] read on every ask, never copied
        # @param ledger [Sensitivity::Ledger] the run's one region ledger
        # @param sensitivity [#classify] what marks a path secret; the default marks none
        # @return [self]
        # @raise [ArgumentError] on a nil ledger
        # @raise [Rebound] when already bound to a different source, ledger or policy
        def bind(source, ledger:, sensitivity: Sensitivity::Policy::Null.instance)
          raise ArgumentError, "a ledger is required: the run's one region ledger, never a fresh one" if ledger.nil?
          raise Rebound, REBOUND unless unbound_or?(source, ledger, sensitivity)

          @source = source
          @ledger = ledger
          @sensitivity = sensitivity
          self
        end

        # A command with no board: its child environment's secrets, and no
        # walk of the project's history. Equal environments are one source, so
        # two callers on one command may both bind. It has no release surface,
        # so its ledger is its own and nothing is ever released into it.
        #
        # @param child_env [Exec::ChildEnv]
        # @return [self]
        def bind_env(child_env = Exec::ChildEnv::DEFAULT)
          bind(Sensitivity::Secrets::Source.new(child_env:, history: Sensitivity::HistoryLiterals::Null),
               ledger: @ledger || Sensitivity::Ledger.new)
        end

        # @return [Sensitivity::Secrets::Egress]
        # @raise [Provider::HTTP::EgressGuard::NotBound] before {#bind}
        def egress
          raise Provider::HTTP::EgressGuard::NotBound, "the egress literals are not bound" if @source.nil?

          @source.egress(released: @ledger.released_digests { secret?(_1) })
        end

        # After the configured entries, so the guard checks the body they hand on.
        #
        # @param journal [#<<] where the guard's records land
        # @param hold [#supervises?, #call] what the guard asks before a request leaves
        # @return [Array<Array>] a provider's http middleware entries
        def entries(journal, hold: Provider::HTTP::EgressGuard::Unsupervised)
          [*@configured.http_entries, guard(journal, hold:)]
        end

        # The guard alone, for a provider that runs no configured middleware.
        #
        # @param journal [#<<] where the guard's records land
        # @param hold [#supervises?, #call] what the guard asks before a request leaves
        # @return [Array] the guard's http middleware entry
        def guard(journal, hold: Provider::HTTP::EgressGuard::Unsupervised)
          Provider::HTTP::EgressGuard.entry(literals: self, journal:, hold:, identity: @identity)
        end

        private

        def unbound_or?(source, ledger, sensitivity)
          @source.nil? || (@source == source && @ledger.equal?(ledger) && @sensitivity.equal?(sensitivity))
        end

        def secret?(path) = !@sensitivity.classify(path).oracle_approvable?
      end
    end
  end
end
