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
  # {Paths#container} composes for every durable per-project artifact.
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
  # This class owns every `.lain/` name, and {#container} is the one door onto
  # {Paths#container} for a caller holding a project ROOT rather than a key --
  # the recipe itself lives beside its ingredients, one layer down.
  # `spec/lain/project_dir_spec.rb` parses every file in `lib/` and fails on any
  # expression that composes one of those paths again, in any spelling -- they
  # were composed sixteen ways before that guard grew to cover them, the
  # config file three independent ways alone.
  #
  # It still stands on both sides of the line it draws -- {#dir} resolves
  # `@root` lexically while {#state_path} uses it only as a hash input. The
  # honest shape is a `StatusFeed::Location`, deferred because extracting it has
  # to move three renderers' defaults with it.
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

    # Every artifact name under it, in one list because having one place that
    # spells them is the whole point: the config file's name was once written
    # three independent ways, and a fourth was one line of code away.
    CONFIG_FILE = "config.rb"
    PROMPT_FILE = "prompt.toml"
    EPICS_DIR = "epics"
    SLOTS_DIR = "slots"
    SKILLS_DIR = "skills"
    META_DIR = "meta"
    SERVICES_FILE = "services.rb"

    # Where a QA pass leaves its report. What the file is NAMED is
    # {CLI::Command::QA}'s own decision and documented there, so this constant
    # does not carry a second copy of it to keep in sync.
    QA_DIR = "qa"

    # The file {Summarizer::Catalog} loads, and the directory `/meta` writes
    # reviewable declarations into. Ruby's own `foo.rb`-plus-`foo/` convention
    # reads a pair like this as one unit and these deliberately are not --
    # NOTHING loads the directory -- so they sit side by side here, which is the
    # one place a reader meets both names at once.
    SUMMARIZERS_FILE = "summarizers.rb"
    SUMMARIZER_DRAFTS_DIR = "summarizers"

    # {StatusFeed::Publication}'s atomically-replaced state struct.
    STATE_FILE = "state.json"

    # The kind segment under `$XDG_STATE_HOME/lain`, the sibling of `sessions`
    # ({Paths#sessions_dir}) and `epics` ({Epic::Home.container}). Named for
    # the feed's writer rather than for the file, so a second status artifact
    # would land beside this one instead of needing a second kind.
    STATE_KIND = "status"

    class << self
      # A root-RELATIVE name under the project directory, so a class body can
      # compute a constant without reading `Dir.pwd` at require time (see
      # {Summarizer::Catalog::DSL_PATH}).
      def join(*names) = File.join(DIR, *names)

      # The naming half of the class/instance split, and only the names a class
      # BODY asks for -- a DSL path, a `/meta` destination, a filename a message
      # quotes -- all of them resolved before any root exists. Every one has a
      # root-resolving twin among the instance readers below.
      def config = join(CONFIG_FILE)
      def meta = join(META_DIR)
      def summarizers = join(SUMMARIZERS_FILE)
      def summarizer_drafts = join(SUMMARIZER_DRAFTS_DIR)
      def services = join(SERVICES_FILE)
    end

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

    def config = under(CONFIG_FILE)
    def prompt = under(PROMPT_FILE)
    def epics = under(EPICS_DIR)
    def slots = under(SLOTS_DIR)
    def skills = under(SKILLS_DIR)
    def meta = under(META_DIR)
    def summarizers = under(SUMMARIZERS_FILE)
    def summarizer_drafts = under(SUMMARIZER_DRAFTS_DIR)
    def services = under(SERVICES_FILE)
    def qa = under(QA_DIR)

    def state_path = File.join(state_dir, STATE_FILE)

    # A durable state container for THIS project: {Paths#container} composes the
    # recipe, and what this adds is the key, which is the project.
    #
    # The key is defaulted rather than fixed because a caller may legitimately
    # key on something else, and that is better read at the call:
    # {CLI::GcSchedule} names a file in the container rather than a directory
    # under it.
    #
    # @param kind [String] the segment under `$XDG_STATE_HOME/lain`
    # @param key [String] what distinguishes this project inside that segment
    # @return [String] an absolute path, creating nothing
    def container(kind, key: @paths.project_hash(@root)) = @paths.container(kind, key:)

    private

    def under(name) = File.join(dir, name)

    def state_dir = container(STATE_KIND)
  end
end
