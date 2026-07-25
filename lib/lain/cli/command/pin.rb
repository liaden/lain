# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/pin [digest]` (B1): mark a committed turn as one compaction may not
      # elide. Zero model turns -- the mark lands on the run's {Session}
      # pin-set, and (through {Session::Journaled}) in the session record, so a
      # `--resume` rebuilds it. Making the mark actually protect anything is a
      # later card's job; this is the seam it reads.
      #
      # A bare `/pin` names the LAST ASSISTANT TURN, because that is what an
      # operator has just read and wants kept -- the user turn that prompted it
      # is cheap by comparison.
      #
      # There is deliberately no `/pin N` count form, though {Rewind} offers
      # one: rewind's argument is a DISTANCE and pin's is an IDENTITY. But
      # dropping the form is not enough on its own, because a short numeric
      # argument is ALSO a valid hex prefix -- `/pin 3` resolved whenever
      # exactly one digest happened to start with "3", pinning an arbitrary
      # turn and reporting success to an operator who meant "three turns back".
      # {Target::MIN_PREFIX} is what closes that, and every refusal on the
      # digest path says the grammar out loud ({Target::NO_COUNT}), because the
      # guard alone cannot teach.
      class Pin
        class Refusal < Error; end

        # The `[digest]` resolution both /pin and /unpin share -- ONE
        # implementation, so the two commands cannot drift on what a prefix
        # means. The rules are {Rewind}'s, restated over the live chain
        # because the authority here is the same live Timeline: hex-only
        # below a full "blake3:" scheme (a partial scheme spelling would
        # otherwise match every digest through the scheme string), unique or
        # refuse. `verb` only spells the refusals, so /unpin's read the way an
        # operator typed them.
        class Target
          # The shortest argument that may name a turn. Below it, resolution
          # does not even run: a 1-3 character argument is far likelier to be
          # the turn COUNT `/rewind` accepts than a digest prefix an operator
          # typed on purpose, and resolving it silently pins whichever turn's
          # digest happens to start that way. Four hex characters is short
          # enough to type from a rendered `blake3:989b401d9e88...` and long
          # enough that no plausible count reaches the matcher.
          MIN_PREFIX = 4

          # Said on EVERY digest-path refusal, not just the too-short one: the
          # length guard cannot catch `/pin 3921`, which is both a plausible
          # count and a well-formed prefix, so the message is what actually
          # teaches the grammar.
          NO_COUNT = "names a turn, not a count"

          def initialize(timeline:, verb:)
            @timeline = timeline
            @verb = verb
            freeze
          end

          # @return [String] the digest the argument names
          def resolve(argument)
            raise Refusal, "nothing to #{@verb}: this session has no committed turns" if @timeline.empty?

            argument.empty? ? last_assistant : sole_match(argument)
          end

          private

          def last_assistant
            turn = @timeline.ancestors.find { |candidate| candidate.role == "assistant" }
            raise Refusal, "no assistant turn to #{@verb} yet; name a turn digest instead" if turn.nil?

            turn.digest
          end

          def sole_match(prefix)
            long_enough!(prefix)
            matches = @timeline.ancestor_digests.select { |digest| match?(digest, prefix) }
            return matches.first if matches.size == 1

            raise Refusal, "no turn matching #{prefix.inspect} on this session's chain -- #{grammar}" if matches.empty?

            raise Refusal, "#{prefix.inspect} is ambiguous on this session's chain: #{matches.join(", ")}"
          end

          def long_enough!(prefix)
            return if prefix.length >= MIN_PREFIX

            raise Refusal, "#{prefix.inspect} is too short to name a turn (#{MIN_PREFIX} characters minimum) " \
                           "-- #{grammar}"
          end

          def grammar
            "/#{@verb} #{NO_COUNT}: give a turn digest, or bare /#{@verb} for the last assistant turn"
          end

          def match?(digest, prefix)
            return digest.start_with?(prefix) if prefix.start_with?("blake3:")

            digest.delete_prefix("blake3:").start_with?(prefix)
          end
        end

        def initialize = freeze

        def name = "pin"

        def usage = "/pin [digest] -- keep a turn out of compaction (default: the last assistant turn)"

        def call(args, env)
          digest = Target.new(timeline: env.agent.timeline, verb: name).resolve(args.to_s.strip)
          env.agent.session.record_pin(digest)
          "pinned #{digest[0, 19]}... -- compaction keeps this turn (/unpin to release it)"
        end
      end
    end
  end
end
