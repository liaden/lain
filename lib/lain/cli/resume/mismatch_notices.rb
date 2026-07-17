# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # Compares the CURRENT --model/--provider flags against what the header
      # recorded, and builds the LOUD-and-continue notices (T19's ruling, RES2
      # extends it to `provider`): name both, run with the flags, never a
      # silent override in either direction. Split out of {Resume} the same
      # way {Salvager} and {Selector} are (CLAUDE.md's rule: extract a real
      # collaborator, never loosen `Metrics/ClassLength`) -- the provider
      # notice pushed the class over the limit.
      class MismatchNotices
        # @param recording [Bench::Session::Recording] the resumed file's own
        #   rebuilt recording -- `recording.context.model` is display-only
        #   here, the header's own recorded value
        # @param path [String] the resumed file's own path, read directly for
        #   `provider`: NOT one of {Context}'s constructor inputs (see
        #   {Bench::Session}'s header comment), so it never rides
        #   `recording.context`, and adding it to {Bench::Session::Recording}
        #   would be a member for one CLI-layer notice
        def initialize(recording:, path:)
          @recording = recording
          @path = path
        end

        # @param model [String, nil] the current --model flag's resolution
        # @param provider [String, nil] the current --provider flag's resolution
        # @return [Array<String>] zero, one, or two notices, already compacted
        def call(model:, provider:)
          [model_notice(model), provider_notice(provider)].compact
        end

        private

        def model_notice(model)
          recorded = @recording.context.model
          return if model.nil? || model == recorded

          "recorded with model #{recorded}; continuing with #{model} (the current flags win)"
        end

        # A recorded-but-absent provider (every header before RES2) is its own
        # named case: "unrecorded", not silently treated as a match.
        def provider_notice(provider)
          return if provider.nil?

          recorded = recorded_provider
          return "recorded with provider unrecorded; continuing with #{provider} (the current flags win)" if
            recorded.nil?
          return if provider == recorded

          "recorded with provider #{recorded}; continuing with #{provider} (the current flags win)"
        end

        # Read straight off THIS file's own header record, the same duck
        # {Resume#prior_basename} already reads `resumed_from` through.
        def recorded_provider
          Journal.records(File.foreach(@path), type: SessionRecord::HEADER_TYPE).first&.dig("provider")
        end
      end
    end
  end
end
