# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # Nine built-ins at or under 30 code lines, one file: each was its own
      # file for `Metrics/ClassLength`'s OLD 110-line budget, and at today's
      # 300 none of them is within an order of magnitude of tripping it. What
      # stays split is a command with a real second responsibility
      # (`Registry`'s collision/currying policy, `Help`'s live-registry read) or
      # one this card leaves alone by scope -- everything else that was ONE
      # class plus `module`/`class` scaffolding plus a `require_relative` comes
      # home. `Env` -- the value these commands read their collaborators
      # through, not a command itself -- stays its own file; see the hand-back.

      # `/quit`: hands the Repl its :quit action, so the conversation winds
      # down through the SAME exit a bare "quit" farewell takes -- converse's
      # loop condition fails and run's ensures fire; no second shutdown path.
      class Quit
        def initialize = freeze

        def name = "quit"

        def usage = "/quit -- end the session (same as bare quit)"

        def call(_args, _env) = :quit
      end

      # `/sessions`: Command::Env's `sessions` reader IS
      # {Lain::CLI::Sessions}, whose `#listing(all:)` answers -- this command
      # adds nothing but the argument parse, rendering that answer verbatim.
      class Sessions
        ALL_FLAGS = %w[--all all].freeze

        def initialize = freeze

        def name = "sessions"

        def usage = "/sessions [--all] -- list recorded sessions, newest first (--all includes ephemeral .btw ones)"

        def call(args, env) = env.sessions.listing(all: ALL_FLAGS.include?(args.to_s.strip))
      end

      # `/inbox` reuses {HumanReplies}'s OWN drain object at `you>` --
      # `#drain_at_prompt`, the same TTY drain UX and the same ask_human
      # resolution `/inbox` at `human>` already uses (`read_drained_answer`).
      # Never a second listing, never a second reply path.
      class Inbox
        def initialize = freeze

        def name = "inbox"

        def usage = "/inbox -- list and answer pending human questions (same drain as human>)"

        # THIS command reads the human's answer itself, so no second reply
        # surface may be opened around the line that invokes it
        # ({Repl::LineScope#serve} asks through {Registry#serves_replies?}). A
        # loop started around it would race the drain for one stdin, and the
        # answer would land on whichever fiber won the dequeue -- against
        # `Pending#oldest`, which by then is the loop's own item rather than the
        # one the human just read.
        def serves_replies? = true

        # Nil, always: `#drain_at_prompt` already delivers everything a human
        # needs to see through the SAME TTY calls `human>`'s drain uses, so text
        # here would render a second, redundant confirmation over the one the
        # drain already printed. `nil` is the Repl's documented "already
        # delivered" outcome, not a missing-response bug.
        def call(_args, env)
          env.replies.drain_at_prompt
          nil
        end
      end

      # `/unpin [digest]`: the retraction half of {Pin}, resolving its
      # argument through the very same {Pin::Target} so the two commands cannot
      # disagree about what a prefix names. It refuses an unresolvable target
      # rather than quietly unpinning nothing -- an operator who mistyped a
      # digest must not read silence as success.
      #
      # Unpinning a turn that was never pinned is NOT a refusal: {Session}'s
      # pin-set is a set, and "make sure this is not pinned" is a legitimate
      # thing to ask of a session whose pins you cannot see. It is not a
      # SUCCESS either -- claiming "unpinned" over a session with no pins is
      # the same silence-read-as-success this command's refusals exist to
      # avoid, one step further in. So the no-op says it was not pinned, and
      # journals nothing: there is no transition, and a retraction record for a
      # pin that never happened would only be noise in the replay log.
      class Unpin
        def initialize = freeze

        def name = "unpin"

        def usage = "/unpin [digest] -- release a pin (default: the last assistant turn)"

        def call(args, env)
          digest = Pin::Target.new(timeline: env.timeline, verb: name).resolve(args.to_s.strip)
          session = env.agent.session
          return "#{digest[0, 19]}... was not pinned -- nothing to release" unless session.pinned?(digest)

          session.record_unpin(digest)
          "unpinned #{digest[0, 19]}... -- compaction may elide this turn again"
        end
      end

      # `/model <id>`: writes the {Context::ModelSwitch} slot the session's
      # Context reads at render time, so the NEXT Request carries the new
      # model -- Agent's @context stays construction-fixed, the slot is the
      # seam. The id is passed VERBATIM: an unknown provider/model fails
      # loudly at dispatch (the provider's own refusal), never a silent
      # fallback here. The switch journals the change attributed to this
      # surface. Bare `/model` reports the model in force.
      class Model
        SURFACE = "tty"

        def initialize = freeze

        def name = "model"

        def usage = "/model [id] -- show the model in force, or switch the next turn's model"

        def call(args, env)
          id = args.strip
          return "model: #{env.model_switch.current}" if id.empty?

          from = env.model_switch.current
          env.model_switch.switch(id, surface: SURFACE)
          "model: #{from} -> #{id} (next turn; an unknown id fails at dispatch)"
        end
      end

      # `/approve`: drains the parked approval queue inline -- each undecided
      # {Approval::Queue::Pending} is rendered for y/N in turn through the
      # injected prompt ({Frontend::ApprovalPolicy}, the SAME prompt loop the
      # watch surface uses, so decisions are signed "tty" and fail closed on
      # anything but an explicit yes). The prompt collaborator owns the
      # terminal question (its reader routes through the conductor); this
      # command only walks the queue and RETURNS the outcome as text.
      class Approve
        # @param prompt [#decide] answers one pending y/N; injected so the
        #   wiring's conductor-routed reader -- not a bare gets -- owns stdin
        def initialize(prompt:)
          @prompt = prompt
          freeze
        end

        def name = "approve"

        def usage = "/approve -- answer each pending tool approval y/N"

        def call(_args, env)
          undecided = env.approvals.each.reject(&:decided?)
          return "no pending approvals" if undecided.empty?

          undecided.each { |pending| @prompt.decide(pending) }
          undecided.map { |pending| outcome_line(pending) }.join("\n")
        end

        private

        # A surface other than ours can win a pending mid-drain (first answer
        # wins is the queue's own doctrine); the line then NAMES the deciding
        # surface, so a "denied (timeout)" never reads as the human's no.
        def outcome_line(pending)
          verdict = pending.approved? ? "approved" : "denied"
          surface = Frontend::ApprovalPolicy::SURFACE
          "#{pending.tool}: #{verdict}#{" (#{pending.surface})" unless pending.surface == surface}"
        end
      end

      # `/help`: one rendered String -- the registered commands (one usage line
      # each) above the skill catalog -- returned to the Repl's boundary
      # renderer (commands return text, never print). Holds the LIVE registry
      # it is registered in, so a command a later card registers appears with
      # no edit here; the catalog is the SAME snapshot SkillDispatch dispatches
      # over (Wiring threads one load into both), so the listing and the
      # dispatch can never drift.
      class Help
        def initialize(registry:, catalog:)
          @registry = registry
          @catalog = catalog
          freeze
        end

        def name = "help"

        def usage = "/help -- list commands and skills"

        # A {Lain::Renderable}, not a String -- the same words, with each
        # section HEADER naming a token so the listing beneath it reads as
        # content rather than as one flat colour.
        def call(_args, _env)
          section("commands:", command_lines).plain("\n\n") + section("skills:", skill_lines)
        end

        private

        # A header and its lines: the header names `:label`, every entry is the
        # renderable's own plain token, and the newlines belong to the entries
        # so no style ever wraps a line ending.
        def section(header, lines)
          lines.inject(Lain::Renderable.new.with(:label, header)) do |rendered, line|
            rendered.plain("\n#{line}")
          end
        end

        def command_lines = @registry.map { |command| "  #{command.usage}" }

        # An empty catalog renders honestly rather than as a bare header.
        def skill_lines
          return ["  (none)"] if @catalog.all.empty?

          @catalog.all.map { |skill| "  /#{skill.name} -- #{skill.description}" }
        end
      end

      # `/implement-epic` at `you>`: work the mounted epic's approved issues to
      # its working branch, and report what landed and what is still waiting.
      #
      # The driving is {EpicDriver::Run}'s and the collaborators are
      # {EpicDriver::Factory}'s; this command is the door onto them, the way
      # {Goal} is the write surface over {GoalDriver}. What it owns is the
      # words: how a width is spelled, and what a human reads back.
      #
      # It is registered in EVERY chat, in an epic or not, and refuses by name
      # where there is nothing to drive -- a command that exists in some
      # sessions and not others is one a human cannot learn.
      class ImplementEpic
        USAGE = "/implement-epic [--width N] -- work the mounted epic's approved issues to its working branch"

        # `--width` is the one knob worth typing: a human watching a run may
        # want the issues taken one at a time, and editing a config file to say
        # so is not something anybody does mid-chat. The budget stays a
        # construction seam -- it is a bench's question, not a prompt's.
        WIDTH = /\A--width[= ]\s*(?<width>\S+)\z/

        def name = "implement-epic"

        def usage = USAGE

        # @param args [String] the line after the verb
        # @param env [Env] the run's collaborators
        # @return [String] what the run came to
        # @raise [EpicDriver::NoEpicMounted] when this chat is in no epic
        # @raise [Lain::Error] when the width is not a positive whole number
        def call(args, env)
          env.epic_driver.run(**width(args.strip)).to_s
        end

        private

        # Refused rather than defaulted: a human who typed a width meant it, and
        # driving the epic at some other number because the word was misspelled
        # is the kind of quiet substitution that is found three issues later.
        def width(args)
          return {} if args.empty?

          matched = WIDTH.match(args)
          raise Error, "#{name} takes only --width N -- #{USAGE}" if matched.nil?

          { width: positive!(matched[:width]) }
        end

        def positive!(value)
          width = Integer(value, exception: false)
          raise Error, "--width takes a whole number of issues above zero, not #{value.inspect}" unless
            width&.positive?

          width
        end
      end

      # `/keep`: promote this ephemeral (--btw) session in place --
      # {Chronicle#promote!} renames journal+WAL off the `.btw` mark, so the
      # clean-exit reap skips it and it survives as an ordinary chained fork
      # (`lain sessions` lists it).
      #
      # WHEN it may run is the load-bearing half (a binding panel ruling):
      # {Chronicle::RelocatableSpool#relocate} is unsynchronized with the
      # ResponseWal monitor, so promote! must run strictly BETWEEN round
      # trips. Command dispatch IS between the MAIN agent's asks by
      # construction -- {Repl#converse} dispatches synchronously and an ask
      # completes inside the dispatch that started it ({Repl#respond}'s Sync)
      # -- so the one way a round trip can be mid-flight here is an adopted
      # fleet actor, whose initial turn runs under the supervisor's reactor
      # ACROSS asks. A `:running` registration cannot be told apart from a
      # parked-and-quiescent one from outside the actor, so /keep refuses
      # conservatively while any is running.
      class Keep
        def initialize = freeze

        def name = "keep"

        def usage = "/keep -- keep this ephemeral (--btw) session: promote it into a durable one"

        def call(_args, env)
          refuse_mid_flight!(env.supervisor)
          promoted = promotable(env).promote!
          "kept: #{File.basename(promoted)} -- now a durable chained fork (lain sessions lists it)"
        end

        private

        def refuse_mid_flight!(supervisor)
          roles = supervisor.select { |registration| registration.state == :running }.map(&:role)
          return if roles.empty?

          # Name the concrete unblocking action: a PARKED fleet actor reads
          # :running forever (its initial turn is spooling under the
          # supervisor's reactor across asks), so "wait" alone could leave
          # /keep refusing with no way out -- stopping the actors is the exit.
          raise Error, "wait for the turn to settle: actors still running (#{roles.join(", ")}) -- promotion " \
                       "is safe only between round trips; stop the actors (or let them finish), then /keep again"
        end

        # The named refusals fire before promote! so a /keep outside its
        # domain reads as policy, never as a wrapped ArgumentError from the
        # rename machinery.
        def promotable(env)
          path = env.journal_path
          raise Error, "no session record to promote (--no-journal)" if path.nil?
          raise Error, "#{File.basename(path)} is not ephemeral; only a --btw session needs /keep" unless
            Paths.ephemeral?(path)

          env.chronicle
        end
      end
    end
  end
end
