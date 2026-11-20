# frozen_string_literal: true

module Lain
  class Sensitivity
    module Secrets
      # A process's own secret values, read per call, so a value committed or
      # written to an ignored file after the source was built is still known.
      # The gateway and the egress guard both read one.
      #
      # @!attribute [r] child_env
      #   @return [Exec::ChildEnv] the environment a child would inherit
      # @!attribute [r] history
      #   @return [#to_a, #refusable] see {HistoryLiterals}
      Source = Data.define(:child_env, :history) do
        # @param context [#worker_env, nil] the call whose worker's own environment is added
        # @return [Array<String>] every value the masker knows for that call
        def for(context) = Secrets.for(child_env:, context:, history:)

        # @return [Array<String>] every value the masker knows, with no call's worker
        def to_a = self.for(nil)

        # A file's bytes are masked for the narrower set, since ordinary config
        # such as `DB_HOST=localhost`, or the socket path SSH_AUTH_SOCK holds,
        # would otherwise mask every file naming it. A windowed read or a search
        # row can show 1 line of a multi-line value alone, so each line that
        # carries a secret by itself is sought too, and the value spelled with
        # CRLF line ends.
        #
        # @param context [#worker_env, nil] the call whose worker's own environment is added
        # @return [Array<String>] the environment's values, the worker's lent ones, the
        #   history's refusable ones, and their spellings and lines
        def for_reads(context)
          refusable = history.refusable
          ordinary = ordinary(context, refusable)
          Secrets.for(child_env:, context:, history: refusable).reject { ordinary.include?(_1) }
                 .flat_map { _1.include?("\n") ? [_1, *spellings(_1)] : [_1] }.uniq.freeze
        end

        # @param released [Set<String>] region digests a human released
        # @return [Egress] the same values, split into those refused from
        #   leaving the machine and those only flagged
        def egress(released: Set.new) = Egress.of(child_env:, history:, released:)

        private

        # Follows `Regions::SECRET_NAMING`, so a read drops only what the detector
        # would call ordinary; a value any other source also lists is kept.
        def ordinary(context, refusable)
          lent = (context || Session::Null.instance).worker_env.env
          pairs = [*child_env.environment, *lent].map { |name, value| [name.to_s, value.to_s] }
          secret, plain = pairs.partition { |name, _| Regions::SECRET_NAMING.match?(name) }
          plain.map(&:last).select { Regions::ORDINARY_VALUE.match?(_1.b) }.to_set -
            listed_elsewhere(lent, secret.map(&:last), refusable)
        end

        def listed_elsewhere(lent, secret, refusable)
          literals = Literals.new(child_env:, lent:)
          secret + literals.detected_values + refusable
        end

        # Keyed by the value itself, so a history value edited mid-chat is judged afresh rather
        # than answered stale. Bounded, since the values it no longer sees are never asked again.
        def spellings(value)
          Source::SPELLINGS.clear if Source::SPELLINGS.size >= Source::SPELLINGS_LIMIT
          Source::SPELLINGS.compute_if_absent(-value) { judged(value).freeze }
        end

        # A line shared with ordinary config, such as `"type": "service_account",`,
        # is not sought. A PEM's short last body line is neither detected nor
        # random enough, so it can show: the rest of the key is masked, and the
        # tail alone is not a usable key.
        def judged(value)
          lines = value.b.lines.map(&:strip).select { Regions.detect(_1, hinted: true).any? || Entropy.high?(_1) }
          [value.b.gsub(/\r?\n/n, "\r\n"), value.b.gsub("\r\n", "\n"), *lines].uniq - [value.b]
        end
      end

      class Source
        DEFAULT = new(child_env: Exec::ChildEnv::DEFAULT, history: HistoryLiterals::Null)
        SPELLINGS = Concurrent::Map.new
        SPELLINGS_LIMIT = 256
      end
    end
  end
end
