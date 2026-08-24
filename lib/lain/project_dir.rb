# frozen_string_literal: true

module Lain
  # Where a project's own files live, on both sides of one line: the `.lain/`
  # tree that sits beside the code, and the published state feed, which used to
  # be in it and is not any more.
  #
  # **The `.lain/` directory is a project artifact, like `.git/`.** Config, summarizers,
  # slots, skills and repo-mode epics are things a user WRITES, reads back and
  # may well commit, so they belong beside the code and are not an XDG concern.
  #
  # **The state feed is the opposite, and that is F50.** {StatusFeed} rewrites
  # it on every turn -- `elapsed`, `idle` and `occupancy` all move -- nothing in
  # `lib/` writes a `.gitignore` (`Epic::GitIgnores` only READS one), and lain's
  # own repository gitignores this file. So the people who hit it fixed it for
  # themselves and not for the projects lain is pointed at: every session left
  # permanent `git status` noise in a user's repository, and a `git add -A`
  # committed the file. Machine state that changes every turn is durable
  # per-project state, which is what `$XDG_STATE_HOME` is for, so {#state_path}
  # resolves there -- the same `<state_home>/<kind>/<project_hash>` shape
  # {Epic::Home.container} and {Paths#sessions_dir} already use.
  #
  # **The answer is always ABSOLUTE, or there is no answer.** That is the whole
  # of the fix, not a detail of it: a relative state path resolves against the
  # process's cwd, which is the project, so a relative one is F50 wearing an
  # XDG-shaped hat. {Paths#home} refuses a `$HOME` that is not absolute rather
  # than degrading to it ({Paths::NonAbsoluteHome}), which is what closes the last
  # door back into the repository.
  #
  # The class/instance split mirrors {Paths}: class methods are pure NAMING
  # (root-relative, no filesystem, no `Dir.pwd`), so a load-time constant can
  # use them; an instance RESOLVES those names against one directory, read at
  # construction. Resolution creates nothing -- {StatusFeed::Publication}
  # mkdir_p's the container on its first publish, so a renderer may resolve a
  # path just to name it in a message.
  #
  # **Why a hash and not the directory's own name.** A project is identified by
  # `sha256(realpath(dir))[0, 12]` ({Paths#project_hash}) because that is
  # already this harness's project identifier -- the nvim socket
  # (`plugin/nvim/lua/lain/init.lua`), `Paths#sessions_dir` and the epic
  # container all key on it, and one identifier is what lets the editor, the
  # status bar and the session store agree without talking to each other. It is
  # taken of the REALPATH, which is what makes the three Ruby renderers agree:
  # {CLI::Up} hands over the PATH argument a user typed (`File.expand_path`'d,
  # possibly through a symlink), while {StatusFeed} and {Frontend::TTY} take the
  # bare default -- `Dir.pwd`, which the kernel has already resolved. Two
  # spellings, one project, one file.
  #
  # The cost of the move is that the file is no longer where a human would
  # `ls` for it, and the identity is now the directory a session was STARTED in
  # rather than the project root a resolver would walk to -- so a second session
  # started in a subdirectory publishes a second file, exactly as it used to
  # write a second `.lain/state.json`. That is unchanged behaviour, not a
  # regression, and the cockpit never hits it: `lain up` pins both panes to one
  # cwd (`tmux -c`), so the writer and every renderer read one directory.
  #
  # **Scope, precisely.** {#state_path} is the ONE resolver for the state feed,
  # and {DIR} is available to whoever wants it -- but this class does not yet
  # own every `.lain/` name. Seven others still compose their own:
  # `config.rb` (`config.toml`), `prompt/slots.rb` (`SLOTS_DIR`),
  # `skill/catalog.rb` (`USER_DIR`), `frontend/prompt_composer.rb`
  # (`prompt.toml`), `epic/home.rb` (`epics`), and `cli/command/meta.rb` (twice).
  # Folding those in is a named follow-up.
  #
  # And this class now stands on both sides of the line it draws, which is a
  # responsibility too many: {#dir} resolves `@root` lexically, while
  # {#state_path} uses it only as a hash input. The honest shape is a
  # `StatusFeed::Location` owning `state_home + STATE_KIND + project_hash +
  # STATE_FILE`, leaving this class the `.lain/` tree it is named for. Named as
  # a follow-up rather than done here: the extraction has to move the three
  # renderers' defaults with it, and this card had to keep them untouched.
  #
  # Three Ruby renderers default to the feed independently -- {StatusFeed}
  # writes it, {CLI::Up}'s HUD and {Frontend::TTY}'s prompt read it -- and each
  # used to join its own literal. `spec/lain/project_dir_spec.rb` parses every
  # file in `lib/` and fails on any expression that composes the path again, in
  # any spelling, the retired `.lain/` one included. The shipped plugins hold
  # the same convention in their own languages: `plugin/nvim` recomputes the
  # recipe (`vim.fn.sha256(cwd):sub(1, 12)` is byte-for-byte
  # {Paths#project_hash}, and a spec cross-pins the two), while
  # `plugin/tmux/scripts/lain-status` is POSIX `sh` with no sha256 or realpath
  # to call, so it is TOLD the path and never computes one. It has two tellers,
  # and they differ in WHEN they can answer: {CLI::Up} resolves once and writes
  # an absolute path into a session-scoped `status-right`, while
  # `plugin/tmux/lain.tmux` -- the tpm entry point, which renders with no `lain`
  # process anywhere -- has to resolve per pane on every redraw, because tmux
  # expands the pane's path only then. So the second one does recompute the
  # recipe, in bash, and a spec cross-pins it the same way.
  class ProjectDir
    # The directory itself, relative to a project root.
    DIR = ".lain"

    # {StatusFeed::Publication}'s atomically-replaced state struct.
    STATE_FILE = "state.json"

    # The kind segment under `$XDG_STATE_HOME/lain`, the sibling of `sessions`
    # ({Paths#sessions_dir}) and `epics` ({Epic::Home.container}). Named for
    # the feed's writer rather than for the file, so a second status artifact
    # would land beside this one instead of needing a second kind.
    STATE_KIND = "status"

    # A root-RELATIVE name under the project directory, so a class body can
    # compute a constant without reading `Dir.pwd` at require time (see
    # {Summarizer::Catalog::DSL_PATH}).
    def self.join(*names) = File.join(DIR, *names)

    # @param root [String] the project directory; the working directory by
    #   default, which is what the three renderers of the state feed pass
    # @param paths [Paths] the XDG bases and the project identifier. Defaulted,
    #   never required: three call sites take {#state_path}'s default and a
    #   required collaborator would have to be injected into all of them, which
    #   is the recomposition `spec/lain/project_dir_spec.rb` exists to refuse
    def initialize(root: Dir.pwd, paths: Paths.new)
      @root = root
      @paths = paths
    end

    attr_reader :root

    def dir = File.join(@root, DIR)

    def state_path = File.join(state_dir, STATE_FILE)

    private

    def state_dir = File.join(@paths.state_home, STATE_KIND, @paths.project_hash(@root))
  end
end
