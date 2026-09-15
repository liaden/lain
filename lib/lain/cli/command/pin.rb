# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/pin [digest]`: mark a committed turn as one compaction may not
      # elide. Zero model turns -- the mark lands on the run's {Session}
      # pin-set, and through the Session's journal in the session record, so a
      # `--resume` rebuilds it.
      #
      # A bare `/pin` names the LAST ASSISTANT TURN, because that is what an
      # operator has just read and wants kept -- the user turn that prompted it
      # is cheap by comparison. A parked head (an unanswered `ask_human` or any
      # other open tool_use) is skipped for that same reason: there is nothing
      # to have read yet, so the pin falls back to the last turn that answered.
      #
      # Pinning a `tool_use` or `tool_result` turn also pins its {Counterpart}:
      # a lone half left unprotected strands its neighbour to whatever
      # compaction does with ordinary content, which is exactly the split-pair
      # defect a pin exists to prevent. Both digests are RECORDED, not merely
      # derived at render time, so a `--resume` replays the same pair rather
      # than re-deriving it from a chain that may since have changed shape.
      #
      # A digest already inside a range a held compaction cut collapsed
      # ({Compacted}) refuses the ordinary claim: pinning it now would not
      # bring it back, and saying "compaction keeps this turn" over that would
      # be a promise the next render breaks.
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

          # The newest ANSWERED assistant turn. A parked head -- an
          # `ask_human` or any other tool_use nothing has answered yet -- is
          # never what a bare `/pin` means: an operator reads the answer, not
          # the open question, so a pin lands on the turn that gave it.
          # {Event.pending_tool_use?} only ever answers true of the live head
          # here, because every OLDER assistant turn was necessarily settled
          # before anything could commit past it -- so this skips at most one
          # candidate, never a real assistant turn buried in history.
          def last_assistant
            parked = Event.pending_tool_use?(@timeline.head)
            turn = @timeline.ancestors.find do |candidate|
              candidate.role == "assistant" && !(parked && candidate.digest == @timeline.head_digest)
            end
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

        # The OTHER half of a `tool_use`/`tool_result` pair, so pinning either
        # one drags the other along and neither can strand its neighbour --
        # RECORDED, so replay stays explicit and `/unpin` finds both without
        # re-deriving anything. Read straight off the live chain's parent/child
        # edges: a turn's raw `.content` carries the same tool_use/tool_result
        # blocks a render would, so this needs nothing {Compaction::Source}
        # projects.
        #
        # A parked `tool_use` -- the live head, its answer not yet landed --
        # drags nothing HERE, because there is nothing to drag: no turn
        # answers it yet. That pin still protects the turn once the answer
        # does land, through {Context::PinnedMessages} closing over the
        # counterpart at RENDER time rather than only at pin time; this
        # object's own job is the explicit, replayable half of the pair, not
        # the only one.
        #
        # Shared by /pin and /unpin, so a drag and its release can never name
        # different turns for the same pair.
        class Counterpart
          def initialize(timeline:)
            @timeline = timeline
            freeze
          end

          # @return [String, nil] the paired turn's digest -- nil for an
          #   ordinary turn, and nil for a tool_use turn parked with no answer
          #   committed yet
          def of(digest)
            turn = @timeline.store.fetch(digest)
            return @timeline.ancestors.find { |candidate| candidate.parent == digest }&.digest if tool_use?(turn)

            turn.parent if tool_result?(turn)
          end

          private

          def tool_use?(turn) = turn.role == "assistant" && blocks?(turn, "tool_use")

          def tool_result?(turn) = blocks?(turn, "tool_result")

          def blocks?(turn, type) = turn.content.any? { |block| block.is_a?(Hash) && block["type"] == type }
        end

        # Whether a digest already sits inside a range a compaction cut THIS
        # chain still holds -- pinning it would change nothing the next render
        # sends, so /pin says so rather than the ordinary claim.
        #
        # Reads {Session#compaction_cuts} rather than reaching for
        # {Compaction::Source::HeldCut}'s own arm/boundary rules: this command
        # has no construction-time reach into the live Source, and neither
        # rule can ever DEMOTE a cut this simple check would still call held --
        # a live chat runs one arm for its whole life ({Telemetry::CompactionCut}
        # only stops holding across an arm it was never committed under), and
        # `--compact-keep` is fixed for the run. The one rule that DOES retire
        # a cut mid-session -- a rewind moving the chain off its commit head --
        # is exactly what {Timeline#include?} answers.
        class Compacted
          def initialize(session:, timeline:)
            @session = session
            @timeline = timeline
            freeze
          end

          def cover?(digest)
            order = @timeline.to_a.each_with_index.to_h { |turn, index| [turn.digest, index] }
            held(order).any? { |range| range.cover?(order.fetch(digest)) }
          end

          private

          def held(order)
            @session.compaction_cuts.select { |cut| @timeline.include?(cut.head) }
                                    .flat_map(&:spans).filter_map { |first, last| span(order, first, last) }
          end

          # A span whose endpoints are not on THIS timeline names no range
          # here rather than raising: under this codebase's invariant, a
          # cut's spans are always ancestors of its own already-checked
          # `head`, so this cannot fire on a cut this chain actually
          # committed -- but nothing states that invariant at this call
          # site, and a cut from different provenance (a bench replay's,
          # say) earns a clean "does not cover" instead of a raw `KeyError`.
          def span(order, first, last)
            return nil unless order.key?(first) && order.key?(last)

            order.fetch(first)..order.fetch(last)
          end
        end

        def initialize = freeze

        def name = "pin"

        def usage = "/pin [digest] -- keep a turn out of compaction (default: the last assistant turn)"

        def call(args, env)
          timeline = env.timeline
          session = env.agent.session
          digest = Target.new(timeline:, verb: name).resolve(args.to_s.strip)
          return compacted_reply(digest) if Compacted.new(session:, timeline:).cover?(digest)

          companion = Counterpart.new(timeline:).of(digest)
          session.record_pin(digest)
          session.record_pin(companion) if companion
          pinned_reply(digest, companion)
        end

        private

        def compacted_reply(digest)
          "#{digest[0, 19]}... is already compacted: a held cut collapsed it, so pinning it now would not " \
            "bring it back"
        end

        def pinned_reply(digest, companion)
          return "pinned #{digest[0, 19]}... -- compaction keeps this turn (/unpin to release it)" if companion.nil?

          "pinned #{digest[0, 19]}... and its tool counterpart #{companion[0, 19]}... -- compaction keeps both " \
            "(/unpin either to release them)"
        end
      end
    end
  end
end
