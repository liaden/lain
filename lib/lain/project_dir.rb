# frozen_string_literal: true

module Lain
  # Where a project's own files live, on both sides of one line.
  #
  # **The `.lain/` directory is a project artifact, like `.git/`.** Config,
  # summarizers, slots, skills and repo-mode epics are things a user WRITES,
  # reads back and may well commit, so they belong beside the code.
  #
  # **The state feed is the opposite, and that is the defect this closed.**
  # {StatusFeed} rewrites it every turn, nothing in `lib/` writes a `.gitignore`,
  # and lain's own repository gitignores the file -- so the people who hit it
  # fixed it only for themselves: every session left permanent `git status`
  # noise in a user's repository, and `git add -A` committed the file. Machine
  # state that changes every turn is what `$XDG_STATE_HOME` is for, so
  # {#state_path} resolves to the `<state_home>/<kind>/<project_hash>` shape
  # {Epic::Home.container} and {Paths#sessions_dir} already use.
  #
  # **The answer is always ABSOLUTE, or there is no answer** -- a relative state
  # path resolves against the process's cwd, which is the project, so it is the
  # same defect wearing an XDG-shaped hat. {Paths#home} refuses a non-absolute
  # `$HOME` ({Paths::NonAbsoluteHome}) rather than degrading to it.
  #
  # The class/instance split mirrors {Paths}: class methods are pure NAMING (no
  # filesystem, no `Dir.pwd`), so a load-time constant can use them; an instance
  # RESOLVES against one directory. Resolution creates nothing --
  # {StatusFeed::Publication} mkdir_p's the container on its first publish -- so
  # a renderer may resolve a path just to name it in a message.
  #
  # **Why a hash and not the directory's own name.** `sha256(realpath(dir))[0, 12]`
  # ({Paths#project_hash}) is already this harness's project identifier: the
  # nvim socket, {Paths#sessions_dir} and the epic container all key on it, and
  # one identifier is what lets the editor, the status bar and the session store
  # agree without talking to each other. Taking it of the REALPATH is what makes
  # the renderers agree, since {CLI::Up} passes an `File.expand_path`'d PATH
  # argument that may run through a symlink while the others take `Dir.pwd`,
  # which the kernel has already resolved.
  #
  # The cost: the file is no longer where a human would `ls` for it, and
  # identity is the directory a session STARTED in rather than a walked-to
  # project root, so a second session started in a subdirectory publishes a
  # second file -- unchanged behaviour, and `lain up` pins both panes to one cwd
  # (`tmux -c`) so the cockpit never hits it.
  #
  # {#state_path} is the ONE resolver for the state feed, and
  # `spec/lain/project_dir_spec.rb` parses every file in `lib/` and fails on any
  # expression that composes the path again, in any spelling. This class does
  # not yet own every `.lain/` name (`config.toml`, `SLOTS_DIR`, `USER_DIR`,
  # `prompt.toml` and `epics` each still compose their own), and it stands on
  # both sides of the line it draws -- {#dir} resolves `@root` lexically while
  # {#state_path} uses it only as a hash input. The honest shape is a
  # `StatusFeed::Location`, deferred because extracting it has to move three
  # renderers' defaults with it.
  #
  # The shipped plugins hold the convention in their own languages. `plugin/nvim`
  # recomputes the recipe (`vim.fn.sha256(cwd):sub(1, 12)` is byte-for-byte
  # {Paths#project_hash}, cross-pinned by a spec).
  # `plugin/tmux/scripts/lain-status` is POSIX `sh` with no sha256 or realpath
  # to call, so it is TOLD the path -- by {CLI::Up}, which resolves once into a
  # session-scoped `status-right`, or by `plugin/tmux/lain.tmux`, the tpm entry
  # point, which renders with no `lain` process anywhere and so must recompute
  # the recipe in bash per pane on every redraw, because tmux expands the pane's
  # path only then.
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
