# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/rewind [N|digest]`: move the live session backward with zero model
      # turns, through the already-public {Agent#rewind}. The move lands in the
      # session record as an additive `rewound` record, so the file's fold
      # follows the checkout and the session stays loadable. Every refusal
      # happens BEFORE anything moves or lands: a bad target changes nothing --
      # not the machine, not the file.
      #
      # The digest form resolves a prefix against THIS session's own render
      # chain, under the ForkPoint rules: hex-only below a full "blake3:" scheme
      # (a partial scheme spelling would match every digest through the scheme
      # string), unique or refuse. It cannot reuse {ForkPoint} itself, which
      # resolves against a FILE's recorded turns -- here the authority is the
      # live Timeline.
      class Rewind
        class Refusal < Error; end

        def initialize = freeze

        def name = "rewind"

        def usage = "/rewind [N|digest] -- move this session back N turns (default 1), or to a recorded turn"

        # Every refusal restates the command as the human typed it: a digest
        # stays a digest, because a count they never typed reads as a different
        # command.
        def call(args, env)
          typed = ["/rewind", args.to_s.strip].reject(&:empty?).join(" ")
          exclusively(env, typed) do
            from = env.timeline
            count = count_for(args.to_s.strip, from)
            settled_target!(count, from, typed)
            moved(env, count, from:)
          end
        end

        private

        # Refusals all happened above, so from here the move is committed. Catch
        # up FIRST, then journal BEFORE the machine moves: {Timeline#rewind} on a
        # validated count cannot fail, and {Agent#rewind}'s in-flight refusal
        # cannot fire because {#exclusively} holds the dispatch lock it asks
        # for, so nothing can raise between the record landing and the machine
        # moving -- a chronicle failure here leaves the machine unmoved, never a
        # machine-at-A/record-at-H wedge every later catch_up would report as
        # Diverged, far from the actual bug.
        #
        # `env.chronicle.catch_up(from)`, deliberately not {Env#checkpoint}:
        # `from` is THIS rewind's pre-move head, captured once in {#call}, while
        # `#checkpoint` re-reads `agent.timeline` live. This command's whole job
        # is to change what "current" means, so a live re-read here is one
        # statement-reorder away from catching up on the ALREADY-SHORTENED chain
        # instead of the one being moved away from.
        def moved(env, count, from:)
          env.chronicle.catch_up(from)
          to = from.rewind(count)
          env.chronicle.rewound(to: to.head_digest)
          env.agent.rewind(count)
          rendered(count, from:, to:)
        end

        # A run in flight settles onto the Timeline it captured and hands that
        # back, so a head moved now is committed over the moment the parked
        # call is answered. {InFlight.dispatching?} is the predicate, shared
        # with `/undo` (and, off its wider {InFlight.mid_tool?}, with `/fork`
        # and `/btw`) so the four commands cannot disagree about what "in
        # flight" means; it refuses even a caller already holding the lock.
        # The lock is then HELD from resolution through the record and the
        # move, because a check that is only read lets a run start between the
        # record landing and the move.
        def exclusively(env, typed)
          lock = env.agent.dispatch_lock
          raise Refusal, in_flight(typed, env.timeline) if InFlight.dispatching?(env) || !lock.try_enter

          begin
            yield
          ensure
            lock.exit
          end
        end

        def in_flight(typed, timeline)
          "#{typed} refused: #{parked(timeline)} is still in flight, and settling it would commit " \
            "its turns over a rewound head. Nothing moved -- answer or stop it, then rewind."
        end

        def parked(timeline)
          head = timeline.head
          return "a run" unless Event.pending_tool_use?(head)

          calls = head.content.grep(Hash).select { |block| block["type"] == "tool_use" }
          "the parked #{calls.map { |use| "#{use["name"]} (#{use["id"]})" }.join(", ")} call"
        end

        # The signed match is deliberate: "-1" must reach the RANGE refusal, not
        # fall through to the digest path and refuse as an unmatched prefix.
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
        # must not become the head, because its results -- which exist, above
        # it -- would be rewound past and the next request would dangle the call.
        #
        # A LOADED session now repairs that shape instead of refusing it. This
        # command is unaffected because it moves a LIVE head and projects
        # nothing: the torn turn would simply BE the head, with no load to answer
        # it -- and a live head is where the shape stops being one fact, since a
        # call may still be in flight ({CLI::Command::InFlight.mid_tool?} is how
        # `/fork` reads that), which is why the live doors are the
        # conservative ones. Both forms funnel through the count, so both meet
        # the guard.
        def settled_target!(count, timeline, typed)
          heads = timeline.ancestors.to_a
          return unless Event.pending_tool_use?(heads[count])

          raise Refusal, "#{typed} lands on an assistant tool_use turn; its tool results would be rewound " \
                         "past, and the next request would dangle the call (nearest valid targets: " \
                         "#{nearest_valid(count, heads).join(", ")})"
        end

        # The valid counts adjacent to the refused one. Never empty: distance
        # `length` is the empty session, which no tool_use can occupy, and
        # `heads[heads.length]` is nil -- exactly what
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
