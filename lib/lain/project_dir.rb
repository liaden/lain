# frozen_string_literal: true

module Lain
  # The project-scoped `.lain/` tree: a project artifact that lives beside the
  # code, like `.git/`, and therefore NOT an XDG concern. That is why it is a
  # class of its own rather than a corner of {Paths} -- {Paths}'s own comment
  # puts `.lain/` out of scope, and {StatusFeed}'s says in as many words that it
  # declines XDG resolution for this file.
  #
  # The class/instance split mirrors {Paths}: class methods are pure NAMING
  # (root-relative, no filesystem, no `Dir.pwd`), so a load-time constant can
  # use them; an instance RESOLVES those names against one project root, read at
  # construction.
  #
  # **Scope, precisely.** {#state_path} is the ONE resolver for the published
  # state feed, and {DIR} is available to whoever wants it -- but this class does
  # not yet own every `.lain/` name. Seven others still compose their own:
  # `config.rb` (`config.toml`), `prompt/slots.rb` (`SLOTS_DIR`),
  # `skill/catalog.rb` (`USER_DIR`), `frontend/prompt_composer.rb`
  # (`prompt.toml`), `epic/home.rb` (`epics`), and `cli/command/meta.rb` (twice).
  # Folding those in is a named follow-up, deliberately out of T29's scope.
  #
  # What T29 settled is the state feed. Three Ruby renderers default to it
  # independently -- {StatusFeed} writes it, {CLI::Up}'s HUD and
  # {Frontend::TTY}'s prompt read it -- and each used to join `Dir.pwd`, the
  # directory name and the file name into its own literal.
  # `spec/lain/project_dir_spec.rb` parses every file in `lib/` and fails on any
  # expression that composes those again, in any spelling. The shipped plugins
  # hold the same convention in their own languages and are the deliberate
  # remaining consumers, changed in lockstep with these constants:
  # `plugin/tmux/scripts/lain-status` (`state="$dir/.lain/state.json"`) and
  # `plugin/nvim/lua/lain/config.lua` (`state_path = ".lain/state.json"`, also
  # documented in `plugin/nvim/doc/lain.txt`).
  class ProjectDir
    # The directory itself, relative to a project root.
    DIR = ".lain"

    # {StatusFeed::Publication}'s atomically-replaced state struct.
    STATE_FILE = "state.json"

    # A root-RELATIVE name under the project directory, so a class body can
    # compute a constant without reading `Dir.pwd` at require time (see
    # {Summarizer::Catalog::DSL_PATH}).
    def self.join(*names) = File.join(DIR, *names)

    def initialize(root: Dir.pwd)
      @root = root
    end

    attr_reader :root

    def dir = File.join(@root, DIR)

    def state_path = File.join(dir, STATE_FILE)
  end
end
