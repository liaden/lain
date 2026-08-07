# frozen_string_literal: true

require "pathname"

module Lain
  class Project
    # Where does an edit belong, when the root is a home directory?
    #
    # A home root is not a checkout. The two conventions people actually use put
    # the file the agent is asked to edit somewhere other than where it appears:
    # a BARE repository (`~/.cfg`) tracks a scattered handful of paths in a home
    # directory that is otherwise not versioned at all, and a STOW tree keeps the
    # real file at `~/dotfiles/<pkg>/.zshrc` with a symlink standing in for it.
    # An edit that follows neither lands in an untracked copy -- through the link
    # for stow, or outside the tracked set for bare -- and is silently lost the
    # next time the user re-stows or checks out.
    #
    # So this answers one question -- `editable_surface` -- and nothing else.
    # {Plain} is the Null Object: no special surface, the root alone, no caller
    # anywhere writing `if flavour`.
    #
    # == It is a CONVENIENCE, and that ordering is the requirement
    #
    # Nothing here widens anything. {Sensitivity} classifies a path and the
    # handler refuses a denied one whatever this says, so a wrong flavour costs
    # an edit landing in the wrong place -- never a read that should not have
    # happened. That is why every arm here fails CLOSED: a repository that does
    # not answer, a `git` that is not installed, a link that dangles, a home that
    # cannot be listed all reduce the surface rather than fall back to `$HOME`,
    # which is the one answer that would turn a detection miss into an
    # everything-is-editable claim.
    #
    # == Only one level of $HOME is ever walked
    #
    # Finding stow links by hunting for symlinks under `$HOME` would stat every
    # file in `~/.cache`, `~/.local/share` and whatever else has accumulated
    # there -- an unbounded walk to answer a convenience. The candidates are one
    # level of `$HOME` plus {Stow::KNOWN_LINKS}, the handful of conventional
    # paths a package owns that sit deeper. A link buried anywhere else is simply
    # not seen.
    module Dotfiles
      # The git-context env that redirects where git finds its repository, index
      # and config. A lain launched from a pre-commit hook inherits all of them.
      #
      # THREE of these reach this answer, measured rather than assumed, and they
      # are what the scrub is for:
      #
      # - `GIT_INDEX_FILE` makes `ls-files` report ANOTHER repository's tracked
      #   set as this home's editable surface.
      # - `GIT_COMMON_DIR` and `GIT_WORK_TREE` each make
      #   `rev-parse --is-bare-repository` answer **false** for the very
      #   repository the command line named, so a real dotfiles home reports
      #   `:plain` and its whole surface disappears.
      #
      # THE OTHER EIGHT REACH NOTHING, and they stay anyway. Every call here
      # names `--git-dir`, `--work-tree`, `--local` and `-z` explicitly, and an
      # explicit option beats the environment -- so `GIT_DIR` is defeated by the
      # command line rather than by this Hash, and `GIT_CONFIG_COUNT` and
      # `GIT_CONFIG_PARAMETERS` by `--local`. Deleting each one individually
      # changes no answer, which means no example holds them and none pretends
      # to (one that appeared to was removed rather than left to imply coverage
      # it did not have; the `GIT_DIR` example that remains holds the COMMAND
      # LINE, which is a different claim).
      #
      # Scrubbing the whole inheritance class rather than the measured subset is
      # the policy, because the measurement is of TODAY's call sites: the next
      # call added here is one `git` invocation away from making any of the eight
      # live, and it would do so silently.
      #
      # `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` are deliberately absent, the
      # same exclusion {Workspace::Snapshot::Scope::ShadowGit} reasons about:
      # honouring the user's real config is the point of not scrubbing them.
      # Unlike ShadowGit's case they DO reach an answer here, because a
      # `core.worktree` in someone's `~/.gitconfig` is legal -- so the
      # work-tree read is confined with `--local` instead.
      #
      # Its own constant rather than {Isolation::Worktree::GIT_CONTEXT_SCRUB},
      # which is the precedent for the shape: that set predates
      # `GIT_CEILING_DIRECTORIES` and reaching across subtrees for a value we
      # would have to extend anyway buys nothing. `nil` deletes the variable in
      # the child -- the {WorkerEnv} scrub semantics both `Shell::Out` and
      # `Mixlib::ShellOut` honour.
      GIT_CONTEXT_SCRUB = {
        "GIT_DIR" => nil, "GIT_INDEX_FILE" => nil, "GIT_WORK_TREE" => nil,
        "GIT_PREFIX" => nil, "GIT_COMMON_DIR" => nil, "GIT_NAMESPACE" => nil,
        "GIT_OBJECT_DIRECTORY" => nil, "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil,
        "GIT_CEILING_DIRECTORIES" => nil,
        "GIT_CONFIG_COUNT" => nil, "GIT_CONFIG_PARAMETERS" => nil
      }.freeze

      # Seconds a detection may spend inside one `git`. Well under
      # {Shell::Out::DEFAULT_TIMEOUT}, deliberately: this runs while a session is
      # starting, and a convenience that hangs a startup on a wedged filesystem
      # has cost more than it is worth. A child that outlives it reads as "no
      # repository", per the fail-closed rule above.
      GIT_TIMEOUT = 10

      # What Ruby's own path APIs label a path with. Fixed at process start from
      # the locale, so it is `US-ASCII` under `LC_ALL=C` and `UTF-8` under a
      # normal desktop one.
      FILESYSTEM = Encoding.find("filesystem")

      # PATHS ARE BYTES HERE, AND EVERY COMPARISON IS MADE ON THEM. Three
      # spellings of one path meet in this module -- `ASCII-8BIT` out of a
      # subprocess, {FILESYSTEM} out of `Dir.children` and `File.realpath`, and
      # whatever a caller happens to hold -- and Ruby decides the encoding of a
      # `File.join` by which side is ASCII-only, so a home called `maisón`
      # compared unequal to itself and a `covers?` handed a subprocess's own
      # bytes raised `Encoding::CompatibilityError`. That is not a `Lain::Error`,
      # so it escapes `exe/lain`'s rescue and prints a backtrace at somebody who
      # asked for a session. Bytes decide; the label is applied once, at the end,
      # so a surface entry reads back the way `Dir.children` would have spelled
      # it.
      #
      # @param parts [Array<String>] joined in bytes, whatever they are labelled
      # @return [String] labelled {FILESYSTEM}
      def self.join(*parts) = File.join(*parts.map { |part| part.to_s.b }).force_encoding(FILESYSTEM)

      # Lexically normalised BYTES, `..` folded exactly as {Sensitivity} folds
      # it. `nil` cleans to `"."`, which is in nobody's surface -- a question
      # about nothing answers false rather than raising.
      #
      # @param path [String, Pathname, nil]
      # @return [String] `ASCII-8BIT`, for comparison only, never for display
      def self.clean(path) = Pathname.new(path.to_s.b).cleanpath.to_s

      # Does an edit to this path land in the surface? Defined ONCE, in terms of
      # {#editable_surface}, and mixed into all three flavours -- the join is the
      # whole reason the surface exists, and leaving every consumer to re-derive
      # it is how a prefix test goes wrong. It has gone wrong here before:
      # {Project}'s own `cwd_under_root` built `"//"` at the filesystem root and
      # refused every cwd under it, which is why the comparison anchors on
      # `File.join(entry, "")` rather than on `"#{entry}/"`.
      #
      # LEXICAL, like {Sensitivity}: no `realpath`, no `stat`, so a path that
      # does not exist yet still answers, and `..` is folded rather than walked.
      # The surface is resolved (see {Stow#packages}), so hand it a resolved
      # path -- {Project} resolves root and cwd for exactly this reason.
      module Surface
        # @param path [String, Pathname, nil]
        def covers?(path)
          target = Dotfiles.clean(path)
          editable_surface.any? { |entry| within?(Dotfiles.clean(entry), target) }
        end

        private

        # Both arguments are already cleaned bytes. {Bare} narrows this to the
        # equality arm alone -- its entries are files.
        def within?(entry, path) = path == entry || path.start_with?(File.join(entry, ""))
      end

      # A bare repository whose work tree is the home directory it sits in --
      # `git init --bare ~/.cfg` plus an alias, the arrangement the widely-copied
      # dotfiles tutorial produces.
      #
      # The editable surface is the TRACKED FILE SET, not the home directory and
      # not the repository. That distinction is the whole point: a bare dotfiles
      # home is mostly NOT its own repository's business, so naming the directory
      # would claim every downloaded file in it. It also makes a wrong detection
      # harmless -- a {Bare} pointed at a directory holding no repository reports
      # an EMPTY surface, because git names no files, and empty is the safe end
      # of that mistake.
      class Bare
        include Surface

        # `~/.cfg` is the tutorial's name; the rest are what people rename it to.
        # A closed list rather than a scan, so a `git init --bare` somewhere in
        # `$HOME` for an unrelated reason is never mistaken for the dotfiles one.
        NAMES = %w[.cfg .cfg.git .dotfiles .dotfiles.git .dotfiles-bare].freeze

        # @return [Bare, nil] the first candidate that is really a bare
        #   repository tracking this home; nil leaves {Dotfiles.detect} to try
        #   the next flavour
        def self.detect(home:, shell_out_factory: Shell::Out.public_method(:new))
          NAMES.lazy
               .map { |name| new(home:, repository: Dotfiles.join(home, name), shell_out_factory:) }
               .find(&:tracks_home?)
        end

        # @return [String] the home directory this repository's work tree is
        attr_reader :home

        # @return [String] the bare repository's git directory
        attr_reader :repository

        # @param home [String] the work tree, injected
        # @param repository [String] the git directory this claims to be
        # @param shell_out_factory [#call] builds the subprocess runner, injected
        #   as a factory exactly as {Isolation::Worktree} does. {Shell::Out}
        #   rather than `Mixlib::ShellOut` because mixlib forks and this runs in
        #   the process holding a Store and a Timeline.
        def initialize(home:, repository:, shell_out_factory: Shell::Out.public_method(:new))
          @home = home
          @repository = repository
          @shell_out_factory = shell_out_factory
        end

        def flavour = :bare

        # A bare repository AND one whose work tree is this home. The second half
        # is what keeps a bare mirror clone somebody parked at `~/.dotfiles.git`
        # from being read as the thing an edit should land in.
        def tracks_home? = bare_repository? && work_tree_home?

        # @return [Array<String>] every tracked file, absolute. Empty when the
        #   repository does not answer -- see the class comment.
        def editable_surface = @editable_surface ||= tracked.map { |path| Dotfiles.join(@home, path) }

        def to_s = "bare:#{@repository}"

        private

        # A tracked FILE has no children, so only the equality arm may fire: the
        # inherited prefix arm would claim `~/.zshrc/anything`, which cannot
        # exist and is not this repository's to offer.
        def within?(entry, path) = path == entry

        def bare_repository?
          File.directory?(@repository) &&
            git("--git-dir", @repository, "rev-parse", "--is-bare-repository").strip == "true"
        end

        # An UNSET `core.worktree` is the tutorial's own arrangement -- the work
        # tree lives in the alias, not in the config -- so the convention
        # supplies it: this repository sits directly in `home` under a name from
        # {NAMES}. A SET one has to agree, which is how a repository declaring
        # some other tree is refused. git exits non-zero for an unset key, and
        # {#git} reports that as the same empty string an empty value would give;
        # both mean "the config does not object".
        #
        # `--local` confines the read to THIS repository. A bare `--get` also
        # consults global and system config, which the scrub deliberately leaves
        # alone -- so a `core.worktree` in the user's own `~/.gitconfig` would
        # answer for a repository that declares none, and detection would be
        # silently lost for every dotfiles home on that machine.
        # The comparison is {Dotfiles.clean}'s, not `File.expand_path`'s, and
        # that is two fixes in one. git's answer arrives as ASCII-8BIT while
        # `@home` carries the filesystem encoding, so a home named `maisón`
        # compared unequal to the `core.worktree` naming it, and the card's
        # headline arrangement silently stopped being detected. And a RELATIVE
        # `core.worktree` is resolved by git against the git directory, never
        # against our process directory -- so expanding it here answered a
        # question about `Dir.pwd` that nobody asked.
        def work_tree_home?
          declared = git("--git-dir", @repository, "config", "--local", "--get", "core.worktree").strip
          declared.empty? || Dotfiles.clean(declared) == Dotfiles.clean(@home)
        end

        # `-C @home` is not optional. `git ls-files` reports the subtree below the
        # CURRENT directory, and lain's process directory is routinely inside the
        # home it is asked about: run from `~/sub` the same repository answers
        # `deep.txt` instead of `sub/deep.txt`, which is both a truncated surface
        # and a set of paths that join back to the wrong file.
        #
        # `-z` because git QUOTES an unusual name otherwise -- `.café.conf` comes
        # back as the literal 18-character `".caf\303\251.conf"` under
        # `core.quotePath`, and a newline in a name splits a line-delimited
        # reading into two paths that name nothing.
        #
        # The bytes are relabelled by {Dotfiles.join} at the one place they are
        # joined to the home -- see that method for why the label is applied
        # once, at the end, rather than to each half.
        def tracked
          git("-C", @home, "--git-dir", @repository, "--work-tree", @home, "ls-files", "-z")
            .split("\0").reject(&:empty?)
        end

        # Raw stdout on success, and the empty string for every way git can fail
        # to answer -- non-zero, killed by a signal (`exitstatus` is nil), timed
        # out, or not installed at all. Callers read empty as "no repository",
        # which is the fail-closed direction the class comment argues for.
        def git(*argv)
          shell = @shell_out_factory.call("git", *argv, environment: GIT_CONTEXT_SCRUB, timeout: GIT_TIMEOUT)
          shell.run_command
          shell.exitstatus&.zero? ? shell.stdout : ""
        rescue Shell::Out::Timeout, SystemCallError
          ""
        end
      end

      # `~/dotfiles/<pkg>/.zshrc` symlinked to `~/.zshrc` -- GNU stow's layout,
      # and by hand the most common dotfiles arrangement there is.
      #
      # Resolving a link yields the PACKAGE directory, and both it and the tree
      # holding it join the editable surface, so an edit lands in the repository
      # rather than through the link into a copy nothing tracks. The home root
      # stays in the surface too: a stow home is a real home, and the files that
      # are not linked are still ordinarily editable.
      class Stow
        include Surface

        # Where a stow tree conventionally lives, relative to home.
        ROOTS = %w[dotfiles .dotfiles .files].freeze

        # Paths BELOW the first level that a package conventionally owns. The
        # rest of the search is exactly one level of `$HOME` -- see the module
        # comment on why there is no walk.
        KNOWN_LINKS = %w[
          .config/nvim .config/git .config/zsh .config/tmux .config/fish
          .config/kitty .config/alacritty .config/i3 .local/bin
        ].freeze

        # @return [Stow, nil] nil when no link reaches a package, leaving
        #   {Dotfiles.detect} to fall through to {Plain}
        def self.detect(home:, **)
          new(home:).then { |stow| stow if stow.linked? }
        end

        # @return [String] the home directory the links live in
        attr_reader :home

        def initialize(home:)
          @home = home
        end

        def flavour = :stow

        def linked? = packages.any?

        # @return [Array<String>] the package directories a link actually
        #   reached, deduplicated and ordered by candidate name
        def packages = @packages ||= links.filter_map { |link| package_for(link) }.uniq

        # @return [Array<String>] the trees those packages live in
        def trees = packages.map { |package| File.dirname(package) }.uniq

        # @return [Array<String>] the home root, every tree reached, and every
        #   package inside it
        def editable_surface = [@home, *trees, *packages]

        def to_s = "stow:#{trees.join(",")}"

        private

        # Sorted so two runs against one home answer identically --
        # `Dir.children` order is the filesystem's, not a promise.
        #
        # A home that cannot be LISTED is a real state (a mode-000 directory, a
        # stale automount) and `Dir.children` raises for it rather than
        # answering. Failing closed here is what makes the module comment's
        # promise true: an unrescued `SystemCallError` would escape `exe/lain`'s
        # `rescue Lain::Error` and print a backtrace at a user who asked for a
        # session -- the failure {Project::Unresolvable} was written to prevent.
        def candidates
          entries = Dir.children(@home).sort
          (entries + KNOWN_LINKS).map { |name| Dotfiles.join(@home, name) }
        rescue SystemCallError
          KNOWN_LINKS.map { |name| Dotfiles.join(@home, name) }
        end

        def links = candidates.select { |path| File.symlink?(path) }

        # A tree that IS home, or that CONTAINS it, is refused however it got
        # there. `~/dotfiles -> /` plus one link into `/etc` otherwise puts `/`
        # and `/etc` in the surface and makes {Surface#covers?} a constant
        # `true` -- two symlinks the running user can create, and the agent can
        # create them through an ordinary write. The card's requirement is that
        # a wrong flavour never widens access, so a tree has to lie BESIDE or
        # BELOW home, never above it. `~/dotfiles -> /mnt/nas/dots` is untouched,
        # which is the arrangement worth keeping. `/` needs no special case: it
        # is an ancestor of every home there is.
        def trees_present
          ROOTS.map { |name| Dotfiles.join(@home, name) }
               .select { |dir| File.directory?(dir) && !contains_home?(dir) }
        end

        # BOTH sides are resolved, and the home side is the one that was missed.
        # {Dotfiles.detect} builds `@home` with `File.expand_path`, never
        # `realpath` -- deliberately, because resolving there would make a home
        # that does not exist RAISE rather than answer -- so a home handed over
        # by a symlinked spelling compared its link path against the tree's
        # resolved one, found no ancestry, and admitted the real home's own
        # parent. The identical tree spelled by its realpath was refused, which
        # is the tell: a guard whose answer depends on how the caller spelled its
        # argument is not a guard.
        #
        # A tree that cannot be resolved at all is REFUSED, not admitted --
        # `File.directory?` said yes a moment ago, so a raise here means the
        # ground moved, and this is the one place in the file where the
        # fail-closed direction is `true`.
        #
        # That arm is deliberately UNHELD, and it is worth saying so rather than
        # leaving it to look tested. `File.directory?` follows symlinks and
        # screens every path `File.realpath` would raise on -- a loop answers
        # false, an unreadable ancestor answers false -- so the only way here is
        # for the filesystem to change BETWEEN the two calls, and an example
        # would have to win that race to prove anything. It stays because
        # without it a `SystemCallError` escapes {Dotfiles.detect} into
        # `exe/lain`, which is the failure the rescue in {#candidates} exists to
        # prevent one method away.
        def contains_home?(tree)
          real = Dotfiles.clean(File.realpath(tree))
          home = Dotfiles.clean(File.realpath(@home))
          home == real || home.start_with?(File.join(real, ""))
        rescue SystemCallError
          true
        end

        # A dangling link resolves to nothing, which is not an error worth
        # raising out of a convenience -- it is simply not evidence.
        def package_for(link)
          target = File.realpath(link)
          trees_present.filter_map { |tree| package_in(tree, target) }.first
        rescue SystemCallError
          nil
        end

        # The package is the FIRST segment under the tree, and there has to be
        # something under it: a link straight at `~/dotfiles` names the tree, not
        # a package, and answering the tree there would put the whole repository
        # in the surface on the strength of one link.
        #
        # The RESOLVED tree is what gets returned, not the spelling under home.
        # `~/dotfiles` being a symlink to the repository's real location is a
        # common arrangement, and a surface holding the unresolved join would not
        # contain the resolved path of the file an edit targets -- {Project}
        # resolves root and cwd for precisely this reason, so that a prefix
        # comparison means one thing.
        #
        # `File.join(real, "")` rather than `"#{real}/"` -- the same guard
        # {Project}'s own `cwd_under_root` carries, so a sibling that merely
        # shares a prefix (`dotfiles-old`) is not read as being inside.
        def package_in(tree, target)
          real = File.realpath(tree)
          prefix = File.join(real, "").b
          segments = target.b.delete_prefix(prefix).split(File::SEPARATOR)
          Dotfiles.join(real, segments.first) if target.b.start_with?(prefix) && segments.size > 1
        end
      end

      # No convention detected: the root is the surface, exactly as it would be
      # for a project. The Null Object of the trio -- it answers the same three
      # messages as {Bare} and {Stow}, so nothing downstream tests for a flavour
      # before asking where an edit belongs.
      class Plain
        include Surface

        # @return [String] the root, which is the whole answer
        attr_reader :home

        def initialize(home:)
          @home = home
        end

        def flavour = :plain

        def editable_surface = [@home]

        def to_s = "plain:#{@home}"
      end

      # Strongest evidence first: {Bare} asks git and gets a yes or no, while
      # {Stow} infers from where links point. Both present is a real (if odd)
      # arrangement, and the order is what makes the answer the same every run.
      FLAVOURS = [Bare, Stow].freeze

      # Expanded first, and that is not a formality: `git --git-dir` resolves a
      # relative path against the PROCESS directory while `git -C d` resolves it
      # against `d`, so a relative home read two different directories and
      # answered `:bare` with an empty surface -- the shape of a detection that
      # half worked.
      #
      # @param home [String] the home root, INJECTED -- nothing here reads `ENV`,
      #   so a spec never needs a real `$HOME` and can never write to one
      # @param shell_out_factory [#call] builds the subprocess runner {Bare}
      #   shells git through; {Stow} and {Plain} never spawn anything
      # @return [Bare, Stow, Plain]
      def self.detect(home:, shell_out_factory: Shell::Out.public_method(:new))
        root = File.expand_path(home)
        FLAVOURS.lazy.filter_map { |flavour| flavour.detect(home: root, shell_out_factory:) }.first ||
          Plain.new(home: root)
      end

      # A project root has no dotfiles flavour to find, whatever happens to sit
      # in it: the conventions here are about a HOME being edited through a
      # repository elsewhere, and a checkout already knows where its files are.
      #
      # @param project [Project]
      # @param shell_out_factory [#call] passed straight through to {.detect}
      # @return [Bare, Stow, Plain]
      def self.for(project, shell_out_factory: Shell::Out.public_method(:new))
        return Plain.new(home: project.root) unless project.kind == :home

        detect(home: project.root, shell_out_factory:)
      end
    end
  end
end
