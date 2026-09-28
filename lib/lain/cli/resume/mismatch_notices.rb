# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # Compares what the current run resolved against what a session header
      # recorded and builds the LOUD-and-continue notices: name both, run with
      # the flags, never a silent override in either direction. A resumed or
      # forked chat asks it, and so does a journal pass over a recorded session.
      #
      # Only a field the human TYPED is noticed: an untyped one resolved to the
      # recording, or to the environment where the header recorded nothing,
      # and neither is an override the human asked for. The model is the
      # exception, compared whatever typed it: a typed provider moves the model
      # with it, and a session answered by a different model is the fact a
      # reader of the notice most needs.
      class MismatchNotices
        # How a notice names each field the recording can disagree about.
        # DERIVED from the fields a header records, so a seventh is noticed by
        # existing: hand-kept, a drifted entry would buy SILENCE about a
        # disagreement, which is what this class exists to prevent. Only
        # `api_base` reads as anything but its field name.
        # `Symbol#name` rather than `to_s`: `to_s` hands back an UNFROZEN String,
        # which would leave this constant holding mutable values and quietly
        # drop the deep-freeze the literal it replaced had.
        LABELS = RunProfile::HEADER_FIELDS.to_h { |field| [field, field.name] }
                                          .merge(api_base: "api base").freeze

        # @param path [String] the session file's own path, whose header holds
        #   both the recorded model and the recorded profile
        def initialize(path:)
          @path = path
        end

        # What the header recorded, for a caller that lays its typed flags over
        # it before it has anything to compare.
        #
        # @return [RunProfile]
        def recorded_profile = RunProfile.from_header(header)

        # @param profile [RunProfile] what the current run resolved, carrying
        #   which fields the human typed
        # @param model [String, nil] the model the current run resolved
        # @return [Array<String>] one notice per disagreement, model first
        def call(profile:, model:)
          [model_notice(model), *typed_notices(profile)].compact
        end

        private

        def model_notice(model)
          recorded = header["model"]
          return if model.nil? || model == recorded

          continuing("model", recorded, model)
        end

        # A header that recorded no profile is its own named case for the
        # provider -- "unrecorded", not silently treated as a match -- and says
        # nothing about the rest, which it never had. Within a recorded profile
        # a field left unset is likewise no value to disagree with.
        def typed_notices(profile)
          recorded = recorded_profile
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
        # {ChainWalk} already reads `resumed_from` through. It is also the
        # record a load rebuilds `context.model` from, so the model compared
        # here is the one a resumed recording carries.
        def header = @header ||= Resume.header(@path)
      end
    end
  end
end
