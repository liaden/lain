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
        # @param header [Hash, nil] a header the caller already read, so a path
        #   is not read twice
        def initialize(path:, header: nil)
          @path = path
          @header = header
        end

        # What the header recorded, for a caller that lays its typed flags over
        # it before it has anything to compare.
        #
        # @return [RunProfile]
        def recorded_profile = RunProfile.from_header(header)

        # @param profile [RunProfile] what the current run resolved, carrying
        #   which fields the human typed
        # @param model [String, nil] the model the current run resolved
        # @param compaction [CompactionProfile, nil] the compaction flags the human
        #   typed; nil when the caller compacts nothing, so nothing is compared
        # @param arms [Arms, nil] the bench arms the human typed, an unset arm
        #   nil; nil when the caller resolves no arms, so nothing is compared
        # @return [Array<String>] one notice per disagreement, model first
        def call(profile:, model:, compaction: nil, arms: nil)
          [model_notice(model), *typed_notices(profile), *compaction_notices(compaction), *arm_notices(arms)].compact
        end

        # Only a ceiling the human typed carries over: a per-model or default
        # one is re-resolved by the run that resumes it.
        #
        # @return [Integer, nil] the ceiling the session was launched with via
        #   `--max-tokens`; nil when the recording did not type one
        def typed_ceiling
          header["max_tokens"] if header["max_tokens_source"] == "typed"
        end

        # @param typed [Integer, nil] the `--max-tokens` the current run was typed with
        # @return [String, nil] a notice when it replaces the recorded typed ceiling
        def ceiling_notice(typed)
          recorded = typed_ceiling
          continuing("--max-tokens", recorded, typed) unless typed.nil? || recorded.nil? || typed == recorded
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

        def compaction_notices(compaction)
          return [] if compaction.nil?

          recorded = CompactionProfile.from_header(header)
          [*switch_notice(compaction, recorded), *typed_compaction_notices(compaction, recorded)]
        end

        def typed_compaction_notices(compaction, recorded)
          CompactionProfile::FLAGS.except(:compact).filter_map do |field, flag|
            ours = compaction.public_send(field)
            theirs = recorded.public_send(field)
            continuing("--#{flag.to_s.tr("_", "-")}", theirs, ours) unless ours.nil? || theirs.nil? || ours == theirs
          end
        end

        # An untyped switch keeps the recording's, and a run that silently stops
        # compacting looks like a broken one, so the kept "off" is named. An
        # unrecorded switch is on, so a typed --no-compact over it is a change.
        def switch_notice(compaction, recorded)
          if compaction.compact.nil?
            "running without compaction, as recorded (pass --compact to compact)" unless recorded.compacts?
          elsif compaction.compact != recorded.compacts?
            "recorded with #{switch_flag(recorded.compacts?)}; continuing with " \
              "#{switch_flag(compaction.compact)} (the current flags win)"
          end
        end

        def switch_flag(compacts) = compacts ? "--compact" : "--no-compact"

        # A typed arm is the same loud-and-continue notice as any field. An
        # untyped one keeps the recording, and is named only when it is weaker
        # than a fresh chat's default or has no order against it.
        def arm_notices(typed)
          return [] if typed.nil?

          recorded = Arms.from_header(header)
          differing = recorded.differs_from_default
          Arms::SETS.keys.filter_map do |arm|
            arm_notice(arm, typed.public_send(arm), recorded.public_send(arm), kept_differing: differing.include?(arm))
          end
        end

        def arm_notice(arm, ours, theirs, kept_differing:)
          return kept_notice(arm, theirs) if ours.nil? && kept_differing
          return if ours.nil? || ours == theirs

          "recorded #{as_recorded(arm, theirs)}; continuing with #{ours} (the current flags win)"
        end

        def kept_notice(arm, recorded)
          default = Arms::DEFAULT.public_send(arm)
          "running #{as_recorded(arm, recorded)}, as recorded; a fresh chat runs #{default} " \
            "(pass #{Arms.flag(arm)} #{default} to run it)"
        end

        # A header writes only the arms that are on, so an off arm was never recorded as off,
        # except round_dedup, which is always written.
        def as_recorded(arm, value)
          value == :off ? "without #{Arms.flag(arm)} (off)" : "with #{Arms.flag(arm)} #{value}"
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
