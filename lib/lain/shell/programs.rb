# frozen_string_literal: true

module Lain
  module Shell
    # The programs that run what their arguments, options or stdin name, in
    # families. {Verdict} abstains on all of them; {Named} reads some families
    # as opaque, because a path such a program opens is not one its argv names.
    module Programs
      # THE GENERATING RULE for the six families below: a name belongs here when
      # something the MODEL writes -- an argument, a flag, or the stdin it pipes
      # in -- can name the program that ends up executing. The Design's first
      # non-negotiable is that there is no string for the model to control, and
      # each of these hands one back.
      #
      # It follows that SYNONYMS are not optional. `sh` without `dash`, or `sudo`
      # without `doas`, is not a check; both are on `PATH` here.
      #
      # The list is HAND-MAINTAINED and therefore incomplete -- `sudoers(5)` has
      # made exactly this point since the 1990s, and a comment claiming otherwise
      # would be the defect. Extend it by applying the rule, not by guessing.
      #
      # Known and deliberately absent: `make`, `cargo`, `rake`, `go`, `mvn`,
      # `gradle`, `dotnet`. What they run comes from a BUILD FILE this layer does
      # not model at all, so listing them would buy nothing while abstaining on
      # most of what a session legitimately runs. That is a judgement about where
      # the threat lives, not a proof they cannot execute: `make -f -` reads a
      # makefile from STDIN and `make --eval=` takes one inline, `mvn exec:exec`
      # names an executable in a property, `go run` takes a package path. Both
      # make exceptions ALLOW today; what stops them mattering is that a working
      # recipe needs a newline or quoting to carry its TAB-indented line, and both
      # of those abstain -- a fact about today's tiers, not a guarantee. `bundle`
      # is ON the list because `bundle exec <program>` names the program in the
      # ARGUMENT, which is the rule exactly.
      #
      # `make` is not the next `time`, and the difference is worth recording:
      # `time` was special because the PARSER hides its tail behind full coverage
      # and bland kinds, so nothing structural could see it. `make -f Makefile`
      # hides nothing and is exactly what it looks like.

      # A command handed over as an argument, now or on a timer.
      TAKES_A_COMMAND = %w[
        eval source . alias command builtin exec xargs parallel find watch
        strace ltrace script systemd-run gdb ssh docker podman kubectl
        npx npm bundle at batch crontab
      ].freeze

      # A shell: `-c`, or a program on stdin.
      SHELLS = %w[sh bash dash zsh ksh mksh ash csh tcsh fish rbash busybox].freeze

      # An interpreter: `-e`, or a program on stdin. `awk` and `sed` are here
      # rather than filed as utilities because that is what they are --
      # `awk 'BEGIN{system("id")}'`, `sed 'e id'`.
      INTERPRETERS = %w[
        perl python python2 python3 ruby irb node deno bun php lua tclsh java awk gawk mawk nawk sed
      ].freeze

      # The short option letters and long options that hand an interpreter its
      # code inline (or, for `python -m`, by module name rather than by path).
      # `awk` takes its program inline unless `-f` names a file, so it is read
      # separately.
      INLINE_CODE = {
        "ruby" => ["e", []], "perl" => ["eE", []], "python" => ["cm", []], "python2" => ["cm", []],
        "python3" => ["cm", []], "node" => ["ep", %w[--eval --print]], "bun" => ["e", %w[--eval --print]],
        "php" => ["r", []], "lua" => ["e", []]
      }.freeze

      # Wrappers whose whole job is to exec the program their arguments name.
      # `time` and `coproc` are here because tree-sitter-bash does not model them
      # as keywords, so `time { echo PWNED; }` and `time rm -rf /tmp/x` reach FULL
      # coverage as ordinary commands: neither the kind tier nor the byte backstop
      # says anything about them, and this list is the only thing that abstains.
      WRAPPERS = %w[
        env nice ionice taskset chrt setarch timeout nohup setsid stdbuf flock
        chroot unshare nsenter time coproc
      ].freeze

      # The same shape, with a privilege change on the way through.
      PRIVILEGE = %w[sudo su runuser doas pkexec setpriv].freeze

      # Interactive programs with a documented shell escape: `less` is the
      # motivating one, so its whole family is here with it.
      SHELL_ESCAPES = %w[less more most man info vi vim nvim ed emacs nano psql mysql sqlite3].freeze

      # Run a program named in their own options. `git` is here for a measured
      # reason -- `-c core.fsmonitor=id`, `-c include.path=...`,
      # `-c alias.<new-name>=!sh` all execute, and `git status --short` is
      # structurally indistinguishable from `ls -la`.
      OPTION_DIRECTED = %w[git tar rsync].freeze

      RUNNERS =
        (TAKES_A_COMMAND + SHELLS + INTERPRETERS + WRAPPERS + PRIVILEGE + SHELL_ESCAPES + OPTION_DIRECTED).freeze

      # The awk family, whose program is inline unless `-f` names a file.
      AWKS = %w[awk gawk mawk nawk].freeze

      # Other names an interpreter installs under, read as the interpreter.
      ALIASES = { "nodejs" => "node", "luajit" => "lua", "pypy" => "python" }.freeze

      VERSION = /[\d.]+\z/

      # `python3.14`, `ruby3.3` and `pypy3` are the interpreter their name
      # starts with; a version is stripped only when what remains is a shell or
      # an interpreter, so `sqlite3` stays `sqlite3`.
      #
      # @param name [String] a program's last path segment
      # @return [String] the shell or interpreter it names, else the name
      def self.canonical(name)
        stripped = name.sub(VERSION, "")
        stripped = ALIASES.fetch(stripped, stripped)
        (SHELLS + INTERPRETERS).include?(stripped) ? stripped : name
      end
    end
  end
end
