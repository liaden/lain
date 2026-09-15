# frozen_string_literal: true

module Lain
  module CLI
    RunProfile = Data.define(:provider, :model, :api_base, :num_ctx, :num_batch, :typed)

    # Which model server answers a run, and how it is asked: the provider, the
    # model, the endpoint, and the two ollama runner knobs. One value, resolved
    # once, so a chat, its session header and every chat forked or resumed from
    # that header agree on it rather than each re-deriving it from whatever
    # flags and environment happen to reach them.
    #
    # `typed` names the fields the human put on argv. It is what lets a
    # resumed or forked chat resolve typed, then recorded, then environment,
    # then built-in: a flag Thor filled from a `default:` would be
    # indistinguishable from one the human typed, which is why the exe declares
    # these five flags without one.
    class RunProfile
      FIELDS = %i[provider model api_base num_ctx num_batch].freeze

      # What a run with no `--provider` and no LAIN_PROVIDER talks to.
      DEFAULT_PROVIDER = "anthropic"

      # The header already carries the model as the context's own field, so
      # the profile adds the other four beside it rather than a second copy.
      HEADER_FIELDS = (FIELDS - %i[model]).freeze

      class << self
        # The fields an options hash carries a value for, each counted as typed.
        # Read by literal key, so `chat_flags_spec`'s scan of what the CLI reads
        # still sees every one.
        #
        # @param options [#[]] Thor's parse, or any hash spelling the same keys
        # @return [RunProfile]
        def from_options(options)
          values = { provider: options[:provider], model: options[:model], api_base: options[:api_base],
                     num_ctx: options[:num_ctx], num_batch: options[:num_batch] }
          new(**values, typed: FIELDS.reject { |field| values[field].nil? })
        end

        # What a session header recorded. A header with no provider recorded no
        # profile at all, and answers {UNRECORDED}. A field it has no key for is
        # nil, which {#over} reads as not recorded.
        #
        # @param record [Hash{String=>Object}] a session header record
        # @return [RunProfile]
        def from_header(record)
          return UNRECORDED unless record.key?("provider")

          new(**FIELDS.to_h { |field| [field, record[field.to_s]] })
        end
      end

      def initialize(provider:, model:, api_base:, num_ctx:, num_batch:, typed: [])
        unknown = typed - FIELDS
        raise ArgumentError, "typed names #{unknown.inspect}, which are not profile fields #{FIELDS.inspect}" \
          unless unknown.empty?

        super(provider: provider&.dup&.freeze, model: model&.dup&.freeze, api_base: api_base&.dup&.freeze,
              num_ctx:, num_batch:, typed: typed.dup.freeze)
      end

      # @return [Boolean] whether this came from a header that recorded a profile
      def recorded? = !provider.nil?

      # The environment's and the built-in answers, for the fields nobody typed.
      #
      # @param defaults [Hash{Symbol=>Object}] a subset of {FIELDS}
      # @return [RunProfile]
      def with_defaults(**defaults) = with(**defaults.slice(*untyped))

      # These fields laid over a recording, per field: an untyped field takes
      # the recorded value when the header recorded one. A field it left unset
      # is not a recorded value, so it keeps the environment's or the built-in
      # answer this profile already holds.
      #
      # Nothing is taken when the human typed a DIFFERENT provider. The recorded
      # model, endpoint and runner knobs belong to the recorded provider, and
      # carried onto another one an ollama model id reaches Anthropic.
      #
      # @param recorded [RunProfile] what the resumed or forked header recorded
      # @return [RunProfile] still carrying this profile's `typed`
      def over(recorded)
        return self unless recorded.recorded? && follows?(recorded)

        with(**recorded.to_options.slice(*untyped).compact)
      end

      # @return [Hash{Symbol=>Object}] the five fields, keyed as {Backend} reads them
      def to_options = FIELDS.to_h { |field| [field, public_send(field)] }

      # @return [Hash{String=>Object}] the header's profile fields, with no key
      #   for an unset one
      def to_header = HEADER_FIELDS.to_h { |field| [field.to_s, public_send(field)] }.compact

      # The header that recorded no profile: laid under typed fields, it changes nothing.
      UNRECORDED = new(provider: nil, model: nil, api_base: nil, num_ctx: nil, num_batch: nil)

      private

      def untyped = FIELDS - typed

      def follows?(recorded) = !typed.include?(:provider) || provider == recorded.provider
    end
  end
end
