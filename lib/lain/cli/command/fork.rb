# frozen_string_literal: true

require "shellwords"

module Lain
  module CLI
    module Command
      # `/fork`: a persistent fork of THIS session at its head -- a sibling
      # `lain chat --fork <session>@<head>` opened in a new tmux window,
      # inheriting exactly the head's lineage and nothing after it.
      #
      # Order is the invariant: the head is durably journaled FIRST, then the
      # selector is proven against the file through the SAME {ForkPoint} the
      # child's `--fork` will resolve with -- so a window never opens onto a
      # selector that dies on arrival. Outside tmux (or with tmux broken) it
      # degrades to printing the exact child command line: the fork the human
      # runs by hand is the same fork.
      #
      # Orchestrator-head-only by design: a subagent's chain rides the
      # orchestrator's journal as lineage telemetry, never as its own on-disk
      # session, so `/fork <actor>` refuses honestly rather than composing a
      # selector no file can back.
      class Fork
        NO_JOURNAL = "cannot fork: this session has no durable journal (--no-journal), " \
                     "so there is no record on disk for a child to fork from"
        NO_TURNS = "cannot fork: no turns are recorded yet, so there is no head to fork -- " \
                   "ask something first, then /fork"

        # Why this door refuses a shape `lain chat --fork` REPAIRS (see
        # {#anchor!}), written in the child's vocabulary because it is the same
        # shape. It says "may still be making", and the hedge is the point: what
        # the door sees is a parked question, not a running tool. An earlier
        # draft asserted the call WAS still being made -- a fact this door does
        # not have, and a refusal claiming what it cannot see is the defect this
        # command exists to remove.
        MID_TOOL = "this session's head is an assistant tool_use turn still awaiting tool results, " \
                   "and a question is parked for you right now -- so this session may still be " \
                   "making that call, and a fork opened here could tell its model the call was " \
                   "cancelled while it was not"

        # The digest-prefix length the window name carries, hex-only -- long
        # enough to tell forks apart at a glance, short enough for a tab.
        NAME_HEX = 12

        # @param environment [#[]] where the tmux-attachment fact is read
        #   (`ENV` in production; a Hash in specs) -- tmux exports TMUX into
        #   every pane, so its absence means no window of ours can open here
        def initialize(environment: ENV)
          @environment = environment
          freeze
        end

        def name = "fork"

        def usage = "/fork -- fork this session at its head into a new tmux window (persistent sibling chat)"

        def call(args, env)
          target = args.to_s.strip
          return target_refusal(target, env) unless target.empty?
          return NO_JOURNAL if env.journal_path.nil?
          return NO_TURNS if env.head_digest.nil?

          anchor!(env)
          open_fork(env)
        end

        private

        # Durability first, even ahead of the refusal: catch_up re-journals
        # through the scribe's idempotent, fsync'd braces, so the head is on disk
        # before anything reads for it. Then the mid-tool gate, in the child's
        # own words against the same now-durable record, beating a window that
        # flashes and dies.
        #
        # The gate is narrow because the child REPAIRS a torn head, so refusing
        # every torn head would refuse forks the child would open happily. But a
        # live head is not a recorded one: on disk an unanswered `tool_use` is
        # stranded and nothing will ever answer it, while live it may be a call
        # still in flight. `/fork` is typeable at the `human> ` prompt a parked
        # `ask_human` opens, and there the head's `tool_use` IS that ask_human.
        #
        # {InFlight.mid_tool?} is the door `/rewind` and `/undo` already share,
        # off the agent's own dispatch lock rather than a proxy for it: the
        # lock is held for the whole life of a run, a parked approval or a
        # parked `ask_human` prompt included, and released the moment nothing
        # is running. It fails safe in one direction only: a subagent's own
        # question, asked while the human sits idle at `you> `, still runs
        # under the orchestrator's own dispatch (the spawn tool's call is what
        # is running), so it over-refuses a fork that would have been fine.
        # Over-refusing costs a message; under-refusing opens a child told its
        # call was cancelled while the parent was still making it.
        def anchor!(env)
          env.checkpoint
          return unless InFlight.mid_tool?(env)

          raise Resume::Door.new(verb: "fork", path: env.journal_path)
                            .refuse("#{MID_TOOL}. #{remedy(File.basename(env.journal_path))}")
        end

        # Reachable from where the human is standing: they have a live session,
        # so an earlier settled digest forks clean today, and answering the
        # parked question costs no command at all.
        def remedy(file)
          "Fork an earlier, settled turn instead: lain chat --fork #{file}@<digest-prefix> -- " \
            "or answer the question and /fork once this turn has settled"
        end

        # Journal, prove, place -- and degrade to the printed command when no
        # window can open: the selector is already durable and proven by then, so
        # the printed line is runnable as-is.
        def open_fork(env)
          selector = anchored_selector(env)
          printable = "lain chat --fork #{Shellwords.escape(selector)}"
          inside_tmux? ? place_window(env, selector, printable) : outside_tmux(printable)
        end

        # The WINDOW command is {PaneCommand.call}'s recipe, not the printable
        # line: a tmux pane sources no interactive chruby, so a bare `lain chat`
        # would exec the wrong ruby -- while the PRINTED line runs in the user's
        # own shell and stays bare. `cwd:` pins the parent's project root so the
        # child's session dir resolves the SAME project. The rescue is scoped to
        # this method so it can never read a local the raise skipped.
        def place_window(env, selector, printable)
          placement = env.tmux_surface.window(command: PaneCommand.call("chat", "--fork", selector),
                                              name: window_name(selector), cwd: Dir.pwd)
          placed(placement, printable)
        rescue TmuxSurface::TmuxUnavailable => e
          "#{e.message}\nrun the fork yourself: #{printable}"
        end

        # The ForkPoint resolve is the proof -- resolution only READS, and its
        # {Resume::Refusal} propagates loudly instead of opening a doomed window.
        # Runs after {#anchor!}, so the head it proves is already durable.
        def anchored_selector(env)
          selector = "#{File.basename(env.journal_path)}@#{env.head_digest}"
          env.fork_point.call(selector)
          selector
        end

        def inside_tmux? = !@environment["TMUX"].to_s.empty?

        def outside_tmux(command)
          "not inside tmux, so no window can open here; run the fork yourself:\n  #{command}"
        end

        def placed(placement, command)
          "forked into tmux #{placement.kind} #{placement.target}: #{command}"
        end

        def window_name(selector)
          digest = selector.split("@", 2).last
          "fork-#{digest.delete_prefix("blake3:")[0, NAME_HEX]}"
        end

        # A named target is refused either way; the registered-actor case earns
        # the honest WHY.
        def target_refusal(target, env)
          return subagent_refusal(target) if registered?(target, env)

          "cannot fork #{target.inspect}: it names no registered actor, and only the " \
            "orchestrator's own head can fork -- type bare /fork"
        end

        def registered?(target, env)
          env.supervisor.any? { |registration| registration.role == target }
        end

        def subagent_refusal(target)
          "cannot fork #{target}: a subagent's chain is not on disk yet -- it rides the " \
            "orchestrator's journal as lineage, not as its own session file, so there is " \
            "nothing for `lain chat --fork` to load. Fork the orchestrator instead: bare " \
            "/fork forks this session at its head."
        end
      end
    end
  end
end
