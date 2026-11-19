# frozen_string_literal: true

require "find"
require "open3"
require "pathname"

module Lain
  module Approval
    # Approves `git commit` with a message in the clone lease lain cut for this
    # chat, after any `git add` of literal paths inside it joined by `&&`, so a
    # drained chore can commit its work with nobody at the terminal.
    # It is the one rule that approves a write: the write lands in a lease
    # nothing else reads, and reaches the project only through a landing.
    #
    # The boundary is the workspace sandbox, which contains whatever git runs:
    # the rule is built only where that sandbox was built to hold the call
    # ({CLI::Wiring::BoardBuild.approving}). The upstream hooks a commit runs
    # still run tracked files the chat may have edited, inside that sandbox.
    #
    # The checks are defence in depth. They refuse the steering this lineage is
    # known to plant: a hook, config, filter driver or env it could have
    # written, a repository other than the lease's own, and options nobody
    # listed. Only a file this lineage could not have planted is trusted, and
    # every `GIT_*` survivor in the child env abstains but the user config pair
    # and the editorless pair lain lends its own workers, since a list of the
    # dangerous ones would be only as good as its author. Git is asked what it
    # reads rather than its files matched as text. A leased worker rooted at
    # its own clone commits by this rule too.
    class LeaseCommit < Rule
      TOOL = "bash"
      GIT = "git"
      COMMIT = "commit"
      ADD = "add"
      # An option, a pathspec magic or a glob widens an add past the words it names.
      WIDENING = /\A[-:]|[*?\[\\]/
      MESSAGE = %w[-m --message].freeze
      ATTACHED_MESSAGE = "--message="
      SWITCHES = %w[-a --all -q --quiet].freeze
      OWN_GIT_DIR = ".git"
      OWN_CONFIG = File.join(OWN_GIT_DIR, "config")
      STORE = %w[HEAD objects packed-refs index].freeze
      REFS = "refs"
      GIT_ENV = /\AGIT_/
      USER_CONFIG_ENV = %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].freeze
      CONFIG_ASKS = %w[config --global --includes --list --show-origin -z].freeze
      FILTER_ASKS = ["-c", "core.fsmonitor=false", "config", "--get-regexp",
                     '^filter\..*\.(clean|smudge|process)$'].freeze
      # What `git config --get-regexp` exits with when no key matched.
      NO_MATCH = 1
      ENV_SHEBANG = %r{\A#!\s*(?:\S*/)?env\b}
      SHEBANG_BYTES = 256
      # The clone's own fsmonitor is lain's, but listing the index is no reason to run it.
      INDEX_ASKS = %w[-c core.fsmonitor=false ls-files --stage -z].freeze
      GITLINK = "160000 "
      ORIGIN = "file:"
      APPROVED = "a commit inside the clone lease lain cut for this chat, running only hooks this lineage " \
                 "did not write"

      # @param sensitivity [#confinement, #executables, #environment, #run_file] the `cwd -> #classify`
      #   factory, on {ComposedTerm}'s terms; its confinement says where the call runs, its executables what
      #   git runs, its environment what the call is lent and its run file how a file git reads is classed
      # @param child_env [Lain::Exec::ChildEnv] what a bash child inherits; lain's own git asks are lent nothing
      # @param leases [#enclosing, #tampered] which clone lain cut a directory lies in, and what was planted there
      def initialize(sensitivity:, child_env: Exec::ChildEnv::DEFAULT, leases: Isolation::Clone::Guard)
        super()
        @sensitivity = sensitivity
        @child_env = child_env.unlent
        @leases = leases
        freeze
      end

      # @param call [Rule::Call]
      # @return [Rule::Decision, nil] an allow, or nil for every other call
      def decide(call)
        commit = commit_of(call)
        commit && failed_check(*commit).nil? ? allow(call, because: APPROVED) : nil
      end

      # @param call [Rule::Call] a call this rule abstained on
      # @return [String, nil] the check a commit failed, and nil for a call that is no commit
      def why_not(call)
        commit = commit_of(call)
        failed = failed_check(*commit) if commit
        "lease_commit: the #{failed} check failed" if failed
      end

      private

      def commit_of(call)
        term, cwd = read(call) if call.tool_name == TOOL && mentions_commit?(call.input)
        [term, cwd] if term && commit?(term)
      end

      # The name of the first check that failed, nil when every one holds.
      def failed_check(term, cwd) = shape_failure(term) || placed_failure(term, cwd)

      def shape_failure(term)
        *adds, commit = term.stages.map(&:argv)
        return "admitted" unless admitted?(commit.drop(2))

        adds.find { !add?(_1) } && "widening"
      end

      def placed_failure(term, cwd)
        clone, landing = own_lease(cwd)
        return "own_lease" unless clone

        added_inside?(term, clone, landing) ? untouched_failure(clone, landing, cwd, term) : "added_inside"
      end

      # Every bash call reaches this rule, and a commit names both words, so the rest pay nothing more.
      def mentions_commit?(input) = [GIT, COMMIT].all? { input.command.to_s.include?(_1) }

      # The verdict abstains on every git command, since git runs what its options name, so an abstention is
      # read as {ComposedTerm} reads one, and a deny is never read again.
      def read(call)
        return unless call.tool.respond_to?(:decision_for)

        decision = call.tool.decision_for(call.input)
        return [decision.term, call.input.cwd] if decision.allow?

        Shell::Reading.from(decision.parse, call.input.cwd) if decision.abstain? && only_ands?(decision.parse)
      end

      # A {Shell::Reading} reads `;` as it reads `&&`, and a commit after `;` runs whether the add failed or not.
      def only_ands?(parse) = parse.separators.all? { _1.text == Shell::Reading::AND }

      def commit?(term) = term.stages.last&.argv&.first(2) == [GIT, COMMIT]

      def add?(argv) = argv.first(2) == [GIT, ADD] && argv.size > 2 && argv.drop(2).none? { _1.match?(WIDENING) }

      # git reads a pathspec's `..` as text, so a lexical expansion is where the add lands. The lease root itself
      # stages the whole clone, as `-A` does, so it waits for a human.
      def added_inside?(term, clone, landing)
        own = File.join(clone, OWN_GIT_DIR)
        term.stages[...-1].flat_map { _1.argv.drop(2) }.all? do |path|
          added = File.expand_path(path, landing)
          below?(added, clone) && added != own && !below?(added, own)
        end
      end

      def below?(path, dir) = path.start_with?("#{dir}/")

      def admitted?(words, messaged: false)
        return messaged if words.empty?

        word, value = words
        return admitted?(words.drop(2), messaged: true) if MESSAGE.include?(word) && value
        return admitted?(words.drop(1), messaged: true) if word.start_with?(ATTACHED_MESSAGE)

        SWITCHES.include?(word) && admitted?(words.drop(1), messaged:)
      end

      # The chat's root is the clone itself: one rooted above it is not running in its own lease.
      def own_lease(cwd)
        confinement = @sensitivity.confinement(cwd)
        landing = confinement.real_landing
        clone = @leases.enclosing(landing)
        [clone, landing] if clone && confinement.contains?(clone) && !confinement.contains?(File.dirname(clone))
      end

      # The commit's stands for every stage: only `git add` and `git commit` with no option before the subcommand
      # are read, so each resolves the same git with the same run files.
      def untouched_failure(clone, landing, cwd, term)
        env = git_env
        git = @sensitivity.executables(term, cwd).last
        checks = {
          "own_repository" => -> { own_repository?(clone, landing) }, "git_env_free" => -> { git_env_free?(env) },
          "trusted_git" => -> { trusted_git?(clone, git) }, "nothing_nested" => -> { nothing_nested?(clone, git, env) },
          "user_configs_held" => -> { user_configs_held?(git, env, landing, cwd) },
          "no_filter" => -> { no_filter?(git, env, landing) }
        }
        checks.find { |_, held| !held.call }&.first
      end

      def nothing_nested?(clone, git, env) = no_git_below?(clone) && no_gitlink?(clone, git, env)

      # `commit -a` may consult a repository anywhere in the work tree, and `add` stages one as a gitlink. The
      # clone's own git dir is pruned, and Find never follows a link out of the clone.
      def no_git_below?(clone)
        own = File.join(clone, OWN_GIT_DIR)
        entries = Enumerator.new { |found| Find.find(clone) { _1 == own ? Find.prune : found << _1 } }
        entries.none? { File.basename(_1) == OWN_GIT_DIR }
      end

      # A gitlink needs no repository beneath it to be one `commit -a` stages.
      def no_gitlink?(clone, git, env)
        options = { chdir: clone, unsetenv_others: true, err: File::NULL }
        out, status = Open3.capture2(asking(env), git.resolved, *INDEX_ASKS, **options)
        status.success? && out.split("\0").none? { _1.start_with?(GITLINK) }
      rescue SystemCallError
        false
      end

      def own_repository?(clone, landing)
        present?(File.join(clone, OWN_GIT_DIR), &:directory?) && @leases.tampered(clone).empty? &&
          unlinked_store?(File.join(clone, OWN_GIT_DIR)) && nothing_nearer?(clone, landing)
      end

      # A link in the store would move the branch or the objects a commit writes to another repository.
      def unlinked_store?(git_dir)
        refs = File.join(git_dir, REFS)
        inside = Dir.glob("**/*", File::FNM_DOTMATCH, base: refs).map { File.join(refs, _1) }
        [*STORE.map { File.join(git_dir, _1) }, refs, *inside].none? { File.symlink?(_1) }
      end

      # git looks for its repository from the cwd upward, so any `.git` below the lease is the one it would use.
      def nothing_nearer?(clone, landing)
        Pathname(landing).ascend.take_while { _1.to_s != clone }.none? { present?(_1.join(OWN_GIT_DIR).to_s) }
      end

      def git_env
        lent = @sensitivity.environment
        @child_env.environment.merge(@child_env.call(lent)).compact
      end

      # Set only on lain's own asks, after the env lent to the commit was judged free of `GIT_*`.
      def asking(env) = env.merge(Isolation::Worktree::NO_LAZY_FETCH)

      def git_env_free?(env)
        env.none? do |name, value|
          name.match?(GIT_ENV) && !USER_CONFIG_ENV.include?(name) && Isolation::SelfSync::EDITORLESS[name] != value
        end
      end

      def trusted_git?(clone, git)
        trusted?(git) && git.run_files.all? { (trusted_file?(_1) || own_config?(clone, _1)) && !env_shebang?(_1.path) }
      end

      # A trusted hook that finds its interpreter on PATH runs whatever PATH names first.
      def env_shebang?(path)
        File.open(path, "rb") { _1.read(SHEBANG_BYTES) }.to_s.match?(ENV_SHEBANG)
      rescue SystemCallError
        true
      end

      # A driver runs over every file an attribute selects, and attributes are tracked files the chat can write.
      def no_filter?(git, env, landing)
        options = { chdir: landing, unsetenv_others: true, err: File::NULL }
        _out, status = Open3.capture2(asking(env), git.resolved, *FILTER_ASKS, **options)
        status.exitstatus == NO_MATCH
      rescue SystemCallError
        false
      end

      # A user config is held as git's run files are, by the same allowlist, and one that reads another file
      # hands git a file nothing here classed.
      def user_configs_held?(git, env, landing, cwd)
        home = env["HOME"]
        return false if home.nil?

        configs = user_configs(env, home).map { File.expand_path(_1, landing) }
        configs.all? { !present?(_1) || trusted_file?(@sensitivity.run_file(_1, cwd)) } &&
          reads_only?(git, env, landing, configs)
      end

      # Every file git could read as the user's own config, whichever one the env makes it read.
      def user_configs(env, home)
        xdg = env["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : env["XDG_CONFIG_HOME"]
        [File.join(home, ".gitconfig"), File.join(xdg, "git", "config"), env["GIT_CONFIG_GLOBAL"]].compact
      end

      # git fails when it has no global config to read, which is no include either.
      def reads_only?(git, env, landing, configs)
        return true if configs.none? { File.exist?(_1) }

        options = { chdir: landing, unsetenv_others: true, err: File::NULL }
        out, status = Open3.capture2(asking(env), git.resolved, *CONFIG_ASKS, **options)
        status.success? && origins(out, landing).all? { configs.include?(_1) }
      rescue SystemCallError
        false
      end

      def origins(out, landing)
        out.split("\0").each_slice(2).map(&:first).uniq.map do |origin|
          origin.start_with?(ORIGIN) ? File.expand_path(origin.delete_prefix(ORIGIN), landing) : origin
        end
      end

      def trusted?(stage)
        trusted_file?(stage) && stage.anomalies.empty? && stage.wrappers.empty? && stage.shadowed.empty?
      end

      def trusted_file?(file) = Shell::Executable.trusted_class?(file.klass, file.fresh)

      def own_config?(clone, file) = !file.fresh && real(file.path) == real(File.join(clone, OWN_CONFIG))

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def present?(path)
        stat = File.lstat(path)
        block_given? ? yield(stat) : true
      rescue SystemCallError
        false
      end
    end
  end
end
