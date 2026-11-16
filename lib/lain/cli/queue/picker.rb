# frozen_string_literal: true

require "shellwords"
require "tempfile"

module Lain
  module CLI
    # Puts a queue's rows in front of fzf and opens the one chosen. fzf is not
    # run through {Shell::Out}: that runner is bounded by a timeout and
    # captures every stream, while a picker waits on a human and must inherit
    # the terminal so fzf owns its foreground process group.
    class Queue::Picker
      class NoFzf < ::Lain::Error; end

      NOTHING = 1
      CANCELLED = 130
      private_constant :NOTHING, :CANCELLED

      # @param rows [String] `<id>\t<reason>\t<summary>` lines, already plain text
      # @param source [String] `here`, `local` or `prs`; only `prs` rows have toggles
      # @param lain [Array<String>] the command that runs `lain`, for reload and preview
      # @param opener [#call] called with the chosen id and `critique:` (a focus, or nil)
      # @param out [#puts] where the rows go when there is no fzf
      # @param env [Hash] read for PATH
      def initialize(rows:, source:, lain:, opener:, out:, env: ENV)
        @rows = rows
        @source = source
        @lain = lain
        @opener = opener
        @out = out
        @env = env
      end

      # @return [Symbol] :opened, :nothing (no match) or :cancelled (Escape)
      # @raise [NoFzf] after printing the rows
      # @raise [::Lain::Error] when fzf fails or names no row
      def call
        fzf = Shell::Path.find("fzf", path: @env.fetch("PATH", "")) or return no_fzf
        output, status = run(fzf)
        case status
        when 0 then open_choice(output)
        when NOTHING then :nothing
        when CANCELLED then :cancelled
        else raise ::Lain::Error, "fzf exited #{status}"
        end
      end

      private

      def no_fzf
        @out.puts(@rows)
        raise NoFzf, "lain queue pick needs fzf, which is not on PATH"
      end

      # The rows go in through a file: a pipe fed from this process could
      # fill while fzf is already answering.
      def run(fzf)
        Tempfile.create("lain-queue-rows") do |file|
          file.write(@rows)
          file.flush
          reader, stdout = IO.pipe
          pid = Process.spawn(fzf, *arguments, in: file.path, out: stdout)
          stdout.close
          await(pid, reader)
        end
      end

      # An interrupt while reading must not leave fzf running behind us.
      def await(pid, reader)
        output = reader.read
        status = Process.wait2(pid).last.exitstatus
        [output, status]
      ensure
        reader.close
        reap(pid) unless status
      end

      def reap(pid)
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def arguments
        ["--delimiter", "\t", "--with-nth", "2..", "--expect", "alt-enter",
         "--preview", "#{command} queue show {1}", *toggles]
      end

      # The scope and matches state lives in fzf's prompt, so a reload needs
      # no state of ours: each key reads the prompt, flips one half, and
      # rewrites both the prompt and the rows.
      def toggles
        return [] unless @source == "prs"

        scope = toggle('[ "$scope" = all ] && scope=mine || scope=all')
        matches = toggle('[ "$matches" = 1 ] && matches=0 || matches=1')
        ["--prompt", "prs mine> ", "--bind", "ctrl-t:transform:#{scope}", "--bind", "ctrl-k:transform:#{matches}"]
      end

      def toggle(flip)
        <<~SH.lines.map(&:strip).join("; ")
          lain=#{Shellwords.escape(command)}
          scope=mine; case "$FZF_PROMPT" in *" all"*) scope=all;; esac
          matches=0; case "$FZF_PROMPT" in *"+matches"*) matches=1;; esac
          #{flip}
          flags=""; [ "$scope" = all ] && flags="$flags --all"; [ "$matches" = 1 ] && flags="$flags --matches"
          prompt="prs $scope"; [ "$matches" = 1 ] && prompt="$prompt +matches"
          echo "change-prompt($prompt> )+reload($lain queue prs$flags)"
        SH
      end

      def command = Shellwords.join(@lain)

      def open_choice(output)
        key, row = output.lines(chomp: true)
        id, reason = row.to_s.split("\t")
        raise ::Lain::Error, "fzf returned no row" if id.to_s.empty?

        @opener.call(id, critique: key == "alt-enter" ? reason : nil)
        :opened
      end
    end
  end
end
