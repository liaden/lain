# frozen_string_literal: true

require "shellwords"

module Lain
  module CLI
    module Command
      # `/btw <question>` (T17): an ephemeral side-question in a tmux popup.
      # Composes `lain chat --btw --fork <this-session>@<head> --prompt
      # <question>` -- T3's ephemeral lifecycle end to end: the child journals
      # to a `.btw.ndjson` twin reaped on its own clean exit unless /keep
      # promotes it -- and opens it through {TmuxSurface#popup}, whose
      # Placement names the degrade (window instead of popup) under control
      # mode or an old tmux, so the answer can say why.
      #
      # The head is journaled durably BEFORE the popup opens ({Chronicle#
      # catch_up}, the same belt {Repl#deliver} wears): the child forks a
      # RECORDED turn, never a head only this process's memory knows.
      class Btw
        WIDTH = "80%"
        HEIGHT = "70%"

        # T2's Placement reasons, rendered as sentences; an unknown reason
        # (a later TmuxSurface) falls through verbatim rather than lying.
        DEGRADE_REASONS = {
          "control_mode" => "the attached tmux client is in control mode (-CC), where a popup never renders",
          "old_tmux" => "this tmux predates display-popup (3.2)"
        }.freeze

        NESTED = "already inside an ephemeral /btw session -- /keep this side-question first to make it " \
                 "durable, then /btw from the kept session"

        def initialize = freeze

        def name = "btw"

        def usage = "/btw <question> -- ask an ephemeral side-question in a tmux popup (/keep inside it to keep it)"

        # The popup runs {Up.pane_command}'s recipe, never the printable line: a
        # tmux pane sources no interactive chruby (see CLAUDE.md's toolchain
        # note), so a bare `lain chat` would exec the wrong ruby -- while the
        # PRINTED fallback (no usable tmux) runs in the user's own shell and
        # stays the bare `lain chat` line. `cwd: Dir.pwd` pins the parent's
        # project root so the child's session dir resolves the SAME project,
        # exactly as /fork pins its window. The rescue is scoped to this method
        # (mirroring /fork's F5) so it never reads a local that a raise skipped.
        def call(args, env)
          question = args.strip
          raise Error, "usage: #{usage}" if question.empty?

          selector = anchored_selector(env)
          rendered(env.tmux_surface.popup(command: Up.pane_command("chat", "--btw", "--fork", selector,
                                                                   "--prompt", question),
                                          cwd: Dir.pwd, title: "btw", width: WIDTH, height: HEIGHT))
        rescue TmuxSurface::TmuxUnavailable => e
          "btw: no usable tmux (#{e.message}); run it yourself:\n  #{printable(selector, question)}"
        end

        private

        # Refuse BEFORE {Chronicle#catch_up} touches the record: an ephemeral
        # forking an ephemeral builds a lineage whose parent is doomed to reap,
        # and tmux won't nest a popup inside a popup anyway (probed --
        # display-popup from inside a popup modifies the existing one). Then
        # journal the head durably and compose the selector the child forks.
        def anchored_selector(env)
          path = session_path(env)
          raise Error, NESTED if Paths.ephemeral?(path)

          digest = head(env)
          env.chronicle.catch_up(env.agent.timeline)
          "#{File.basename(path)}@#{digest}"
        end

        def head(env)
          env.agent.timeline.head_digest or
            raise Error, "nothing to fork yet -- no turn is committed; ask something first, then /btw"
        end

        def session_path(env)
          env.chronicle.journal_path or
            raise Error, "no session record to fork from (--no-journal); /btw needs a journaled session"
        end

        # The bare, hand-runnable form for the no-tmux fallback -- shell-escaped
        # because it lands in the user's own shell, unlike the popup's
        # pane_command recipe tmux hands to ITS OWN `$SHELL -c`.
        def printable(selector, question)
          "lain chat --btw --fork #{Shellwords.escape(selector)} --prompt #{Shellwords.escape(question)}"
        end

        def rendered(placement)
          return "btw: asked in a popup -- an ephemeral fork of this head (/keep inside it to keep it)" unless
            placement.degraded

          "btw: opened a window instead of a popup -- #{DEGRADE_REASONS.fetch(placement.reason, placement.reason.to_s)}"
        end
      end
    end
  end
end
