# frozen_string_literal: true

module Lain
  class Sensitivity
    module Secrets
      Egress = Data.define(:refused, :flagged) do
        def initialize(refused:, flagged:)
          super(refused: Ractor.make_shareable(refused.map { -_1.b }),
                flagged: Ractor.make_shareable(flagged.map { -_1.b }))
        end
      end

      # The values the masker knows, split for a request about to leave the
      # machine. The masker hides every one of them; a request is refused only
      # on the narrow set, because the rest is ordinary config as often as not
      # (`APP_ENV=staging-eu` in a committed `.env`, an agent socket's path),
      # and refusing a chat for naming its own deploy target protects nothing.
      #
      # @!attribute [r] refused
      #   @return [Array<String>] binary; a secret-named environment value that
      #     is not a plain path, a region the detector finds in a passed value,
      #     and a history value {HistoryLiterals#refusable} answers
      # @!attribute [r] flagged
      #   @return [Array<String>] binary; every other value the masker knows
      class Egress
        # A path a secret-shaped name holds, as SSH_AUTH_SOCK and
        # PASSWORD_STORE_DIR do; a socket variable needs no rule of its own,
        # since it holds a path too. It is only flagged when the detector finds
        # nothing in it and it is not random enough to be a key, so a key that
        # happens to begin with a slash is still refused.
        PATH = %r{\A~?/}

        # A released value is compared by region digest, so no byte of it reaches the ledger.
        #
        # @param child_env [Exec::ChildEnv]
        # @param history [#split] see {HistoryLiterals#split}; read once
        # @param released [Set<String>] region digests a human released, from {Ledger#released_digests}
        # @return [Egress]
        def self.of(child_env:, history:, released: Set.new)
          lent = Session::Null.instance.worker_env.env
          env = Literals.new(child_env:, lent:)
          past = history.split
          known = (env.to_a + past.known).map(&:b).uniq
          narrow = (named([*child_env.environment, *lent]) + env.detected_values + past.refusable).map(&:b)
          refused = unreleased(known & narrow, released)
          new(refused:, flagged: known - refused)
        end

        def self.unreleased(values, released)
          released.empty? ? values : values.reject { released?(_1, released) }
        end
        private_class_method :unreleased

        # A value holding more than its secret, as a URL or a JSON line does, is released once
        # every region inside it is. That trusts the detector to find each secret in the value.
        def self.released?(value, released)
          return true if released.include?(Regions::Region.address(value))

          inside = Regions.detect(value)
          inside.any? && inside.all? { released.include?(_1.digest) }
        end
        private_class_method :released?

        def self.named(variables)
          variables.filter_map do |name, value|
            value.to_s if Exec::ChildEnv::SECRET.match?(name) && !path?(value.to_s)
          end
        end
        private_class_method :named

        def self.path?(value)
          PATH.match?(value) && Regions.detect(value).empty? && !Entropy.high?(value)
        end
        private_class_method :path?
      end
    end
  end
end
