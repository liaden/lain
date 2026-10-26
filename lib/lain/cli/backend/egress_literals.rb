# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # The values every provider a {Backend} builds refuses to send, held for
      # {Provider::HTTP::EgressGuard}. Late-bound because providers are built
      # before whatever owns the run's secrets source; unbound it raises, so a
      # request sent before the bind is refused rather than sent unchecked.
      class EgressLiterals
        # @param configured [#http_entries] the run's configured middleware, which the guard follows
        def initialize(configured = Config::Middleware.empty)
          @configured = configured
        end

        # @param source [#egress] read on every ask, never copied
        # @return [self]
        # @raise [Rebound] when already bound to a different source
        def bind(source)
          raise Rebound, "the egress literals are already bound to another source" unless unbound_or?(source)

          @source = source
          self
        end

        # A chat's board: its child environment and the history it primed,
        # the objects the read masker holds, so nothing walks the history twice.
        #
        # @param inputs [#child_env, #history] a board's {ToolGuard::Inputs}
        # @return [self]
        def bind_board(inputs)
          bind(Sensitivity::Secrets::Source.new(child_env: inputs.child_env, history: inputs.history))
        end

        # A command with no board: its child environment's secrets, and no
        # walk of the project's history. Equal environments are one source, so
        # two callers on one command may both bind.
        #
        # @param child_env [Exec::ChildEnv]
        # @return [self]
        def bind_env(child_env = Exec::ChildEnv::DEFAULT)
          bind(Sensitivity::Secrets::Source.new(child_env:, history: Sensitivity::HistoryLiterals::Null))
        end

        # @return [Sensitivity::Secrets::Egress]
        # @raise [Provider::HTTP::EgressGuard::NotBound] before {#bind}
        def egress
          raise Provider::HTTP::EgressGuard::NotBound, "the egress literals are not bound" if @source.nil?

          @source.egress
        end

        # After the configured entries, so the guard checks the body they hand on.
        #
        # @param journal [#<<] where the guard's records land
        # @param hold [#supervises?, #call] what the guard asks before a request leaves
        # @return [Array<Array>] a provider's http middleware entries
        def entries(journal, hold: Provider::HTTP::EgressGuard::Unsupervised)
          [*@configured.http_entries, Provider::HTTP::EgressGuard.entry(literals: self, journal:, hold:)]
        end

        private

        def unbound_or?(source) = @source.nil? || @source == source
      end
    end
  end
end
