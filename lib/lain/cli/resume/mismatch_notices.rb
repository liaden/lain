# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # Compares what the current run resolved against what the header recorded
      # and builds the LOUD-and-continue notices: name both, run with the flags,
      # never a silent override in either direction.
      #
      # Only a field the human TYPED is noticed: an untyped one resolved to the
      # recording, or to the environment where the header recorded nothing,
      # and neither is an override the human asked for. The model is the
      # exception, compared whatever typed it: a typed provider moves the model
      # with it, and a session answered by a different model is the fact a
      # reader of the notice most needs.
      class MismatchNotices
        # How a notice names each field the recording can disagree about.
        LABELS = { provider: "provider", api_base: "api base", num_ctx: "num_ctx", num_batch: "num_batch" }.freeze

        # @param recording [Bench::Session::Recording] the resumed file's own
        #   rebuilt recording -- `recording.context.model` is display-only
        #   here, the header's own recorded value
        # @param path [String] the resumed file's own path, read directly for
        #   the recorded profile: not one of {Context}'s constructor inputs, so
        #   it never rides `recording.context`
        def initialize(recording:, path:)
          @recording = recording
          @path = path
        end

        # @param profile [RunProfile] what the current run resolved, carrying
        #   which fields the human typed
        # @param model [String, nil] the model the current run resolved
        # @return [Array<String>] one notice per disagreement, model first
        def call(profile:, model:)
          [model_notice(model), *typed_notices(profile)].compact
        end

        private

        def model_notice(model)
          recorded = @recording.context.model
          return if model.nil? || model == recorded

          continuing("model", recorded, model)
        end

        # A header that recorded no profile is its own named case for the
        # provider -- "unrecorded", not silently treated as a match -- and says
        # nothing about the rest, which it never had. Within a recorded profile
        # a field left unset is likewise no value to disagree with.
        def typed_notices(profile)
          recorded = RunProfile.from_header(header)
          return [unrecorded_notice(profile)] unless recorded.recorded?

          LABELS.keys.intersection(profile.typed).map do |field|
            ours = profile.public_send(field)
            theirs = recorded.public_send(field)
            continuing(LABELS.fetch(field), theirs, ours) unless theirs.nil? || ours == theirs
          end
        end

        def unrecorded_notice(profile)
          continuing("provider", "unrecorded", profile.provider) if profile.typed.include?(:provider)
        end

        def continuing(label, recorded, current)
          "recorded with #{label} #{recorded}; continuing with #{current} (the current flags win)"
        end

        # Read straight off THIS file's own header record, the same duck
        # {ChainWalk} already reads `resumed_from` through.
        def header = Resume.header(@path)
      end
    end
  end
end
