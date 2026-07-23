# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/rewind [N|digest]` (T15): move the live session backward with zero
      # model turns. The machine moves in place through the already-public
      # {Agent#rewind}; the move lands in the session record as an additive
      # `rewound` record ({Chronicle#rewound} -> {SessionRecord::Scribe#rewound}),
      # so the file's fold follows the checkout and the session stays loadable.
      # Every refusal happens BEFORE anything moves or lands: a bad target
      # changes nothing -- not the machine, not the file.
      #
      # The digest form resolves a prefix against THIS session's own render
      # chain, under T3's ForkPoint rules: hex-only below a full "blake3:"
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
          from = env.agent.timeline
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

        # Mirrors {CLI::Resume#refuse_mid_tool!}: a target that is an
        # assistant tool_use turn still awaiting its results must not become
        # the head -- the next ask would render a dangling tool_use (the real
        # API rejects it), and the journaled file would then refuse to resume
        # through the very guard this command would have skipped. Both forms
        # funnel through the count, so both meet the guard.
        def settled_target!(count, timeline)
          heads = timeline.ancestors.to_a
          return unless pending_tool_use?(heads[count])

          raise Refusal, "/rewind #{count} lands on an assistant tool_use turn still awaiting its tool " \
                         "results; the next request would dangle it (nearest valid targets: " \
                         "#{nearest_valid(count, heads).join(", ")})"
        end

        def pending_tool_use?(head)
          !head.nil? && head.role == "assistant" &&
            head.content.any? { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
        end

        # The valid counts adjacent to the refused one -- consistent with the
        # range message's shape. Never empty: distance `length` is the empty
        # session, which no tool_use can occupy.
        def nearest_valid(count, heads)
          valid = (1..heads.length).reject { |candidate| pending_tool_use?(heads[candidate]) }
          [valid.select { |candidate| candidate < count }.last, valid.find { |candidate| candidate > count }].compact
        end

        # T3's ForkPoint rule, restated over the live chain: hex-only below a
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
