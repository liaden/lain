# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/rewind [N|digest]`: move the live session backward with zero
      # model turns. The machine moves in place through the already-public
      # {Agent#rewind}; the move lands in the session record as an additive
      # `rewound` record ({Chronicle#rewound} -> {SessionRecord::Scribe#rewound}),
      # so the file's fold follows the checkout and the session stays loadable.
      # Every refusal happens BEFORE anything moves or lands: a bad target
      # changes nothing -- not the machine, not the file.
      #
      # The digest form resolves a prefix against THIS session's own render
      # chain, under the ForkPoint rules: hex-only below a full "blake3:"
      # scheme (a partial scheme spelling would match every digest through the
      # scheme string), unique or refuse. It cannot reuse {ForkPoint} itself,
      # which resolves against a FILE's recorded turns -- here the authority
      # is the live Timeline.
      class Rewind
        class Refusal < Error; end

        def initialize = freeze

        def name = "rewind"

        def usage = "/rewind [N|digest] -- move this session back N turns (default 1), or to a recorded turn"

        def call(args, env)
          from = env.timeline
          count = count_for(args.to_s.strip, from)
          settled_target!(count, from)
          moved(env, count, from:)
        end

        private

        # Refusals all happened above, so from here the move is committed.
        # Catch up FIRST (any turn the record has not seen yet lands before
        # the move is announced), then journal BEFORE the machine moves:
        # {Timeline#rewind} on a validated count cannot fail, so nothing can
        # raise between the record landing and the machine moving -- a
        # chronicle failure here leaves the machine unmoved, never a
        # machine-at-A/record-at-H wedge every later catch_up would report as
        # Diverged, far from the actual bug.
        #
        # `env.chronicle.catch_up(from)`, deliberately not {Env#checkpoint}:
        # `from` is THIS rewind's pre-move head, captured once in {#call}.
        # `#checkpoint` re-reads `agent.timeline` live on every call, which is
        # right where "the timeline to journal" and "the current timeline"
        # are the same fact -- but this command's whole job is to change what
        # "current" means, so a live re-read here is one statement-reorder
        # away from catching up on the ALREADY-SHORTENED chain instead of the
        # one being moved away from.
        def moved(env, count, from:)
          env.chronicle.catch_up(from)
          to = from.rewind(count)
          env.chronicle.rewound(to: to.head_digest)
          env.agent.rewind(count)
          rendered(count, from:, to:)
        end

        # The signed match is deliberate: "-1" must reach the RANGE refusal,
        # not fall through to the digest path and refuse as an unmatched
        # prefix (panel NIT).
        def count_for(argument, timeline)
          raise Refusal, "nothing to rewind: this session has no committed turns" if timeline.empty?
          return counted(argument, timeline) if argument.empty? || argument.match?(/\A-?\d+\z/)

          distance_to(argument, timeline)
        end

        def counted(argument, timeline)
          count = argument.empty? ? 1 : Integer(argument, 10)
          return count if (1..timeline.length).cover?(count)

          raise Refusal, "/rewind #{count} is out of range; this session holds #{timeline.length} " \
                         "committed turns (valid range: 1..#{timeline.length})"
        end

        # The resolved target's distance from the head -- {Timeline#rewind}'s
        # count -- so the machine moves through the one public seam either form
        # uses.
        def distance_to(prefix, timeline)
          digests = timeline.ancestor_digests
          index = digests.index(sole_match(digests, prefix, timeline))
          return index unless index.zero?

          raise Refusal, "#{prefix.inspect} is already the head; nothing to rewind"
        end

        def sole_match(digests, prefix, timeline)
          matches = digests.select { |digest| match?(digest, prefix) }
          return matches.first if matches.size == 1

          if matches.empty?
            raise Refusal, "no turn matching #{prefix.inspect} on this session's chain " \
                           "(valid range: 1..#{timeline.length}, or a recorded turn digest)"
          end

          raise Refusal, "#{prefix.inspect} is ambiguous on this session's chain: #{matches.join(", ")}"
        end

        # Shares {Event.pending_tool_use?} with the session-loading doors (see
        # {CLI::Resume::MidTool}): a target that is an assistant tool_use turn
        # still awaiting its results must not become the head -- the next ask
        # would render a dangling tool_use, which the real API rejects. That
        # reason stands on its own and is why this guard is here.
        #
        # What it no longer shares is the REMEDY, and the difference is not
        # drift. A loaded session now repairs this shape instead of
        # refusing it, so the older second reason given here -- that the
        # journaled file would refuse to resume through the very guard this
        # command skipped -- is no longer true; it would repair and resume.
        # This command is unaffected because it moves a LIVE head and projects
        # nothing: the torn turn would simply BE the head, with no load to
        # answer it. A live head is also where the shape stops being one fact
        # (a call may still be in flight -- the distinction
        # {CLI::Command::Fork#anchor!} reads off `env.replies.pending?`), which
        # is why the live doors are the conservative ones.
        #
        # Both forms funnel through the count, so both meet the guard.
        def settled_target!(count, timeline)
          heads = timeline.ancestors.to_a
          return unless Event.pending_tool_use?(heads[count])

          raise Refusal, "/rewind #{count} lands on an assistant tool_use turn still awaiting its tool " \
                         "results; the next request would dangle it (nearest valid targets: " \
                         "#{nearest_valid(count, heads).join(", ")})"
        end

        # The valid counts adjacent to the refused one -- consistent with the
        # range message's shape. Never empty: distance `length` is the empty
        # session, which no tool_use can occupy. `heads[heads.length]` is
        # nil (one past the end), which is exactly what
        # {Event.pending_tool_use?}'s nil guard exists for.
        def nearest_valid(count, heads)
          valid = (1..heads.length).reject { |candidate| Event.pending_tool_use?(heads[candidate]) }
          [valid.reverse.find { |candidate| candidate < count }, valid.find { |candidate| candidate > count }].compact
        end

        # The ForkPoint rule, restated over the live chain: hex-only below a
        # full "blake3:" prefix, so a partial scheme spelling ("b", "bla")
        # cannot match every digest through the scheme string.
        def match?(digest, prefix)
          return digest.start_with?(prefix) if prefix.start_with?("blake3:")

          digest.delete_prefix("blake3:").start_with?(prefix)
        end

        def rendered(count, from:, to:)
          "rewound #{count} #{count == 1 ? "turn" : "turns"}: #{name_of(from)} -> #{name_of(to)}"
        end

        def name_of(timeline)
          timeline.empty? ? "the empty session" : "#{timeline.head_digest[0, 19]}..."
        end
      end
    end
  end
end
