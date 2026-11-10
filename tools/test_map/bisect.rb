# frozen_string_literal: true

require "English"
require "fileutils"
require "json"
require "rbconfig"
require_relative "git"

module TestMap
  # Finds the commit that turned a full run red, in a scratch worktree, while the working tree stays free.
  class Bisect
    Verdict = Data.define(:kind, :commit, :summary)

    STEP_VARIABLE = "LAIN_BISECT_STEP"
    SKIP = 125
    USAGE = "usage: bin/test-map bisect --good SHA --head SHA --staged TREE --specs FILE..."
    FLAGS = %i[good head staged specs].freeze
    # Variables of the caller's own bundle or ruby that would point the step's tools at the wrong tree.
    SCRUBBED = (Git::SCRUB + %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE]).freeze
    NOTIFY = lambda do |text|
      system("notify-send", "lain bisect", text, out: File::NULL, err: File::NULL)
    end

    # @param argv [Array<String>] --good SHA, --head SHA, --staged TREE, --specs FILE...
    # @param repo [String] any directory inside the repository
    # @raise [ArgumentError] on a missing --head or --staged, an unknown flag or a stray word
    def self.for(argv, repo: Dir.pwd)
      options = parse(argv)
      raise ArgumentError, USAGE unless options[:head] && options[:staged]

      new(repo: Git.run("rev-parse", "--show-toplevel", repo:).strip, good: options[:good],
          head: options[:head], staged: options[:staged], specs: options[:specs])
    end

    # @param argv [Array<String>]
    # @return [Hash]
    def self.parse(argv)
      key = nil
      argv.each_with_object({ specs: [] }) do |word, options|
        key = flag(word) || key
        word.start_with?("--") || add(options, key, word)
      end
    end
    private_class_method :parse

    def self.flag(word)
      return nil unless word.start_with?("--")

      name = word.delete_prefix("--").to_sym
      FLAGS.include?(name) ? name : raise(ArgumentError, USAGE)
    end
    private_class_method :flag

    # @param options [Hash] collected so far
    # @param key [Symbol, nil] the flag the word follows
    # @param word [String]
    # @option options [Array<String>] :specs the failed spec files
    def self.add(options, key, word)
      raise ArgumentError, USAGE if key.nil? || (key != :specs && options.key?(key))

      key == :specs ? options[:specs] << word : options[key] = word
    end
    private_class_method :add

    # The file Lain's suite lock holds, computed without loading lain; a spec keeps the two equal.
    # @param env [#[]]
    # @return [String]
    def self.suite_lock_path(env = ENV)
      absolute = ->(value) { value if value.to_s.start_with?("/") }
      home = absolute.call(env["HOME"]) || Dir.home
      state = absolute.call(env["XDG_STATE_HOME"]) || File.join(home, ".local", "state")
      File.join(state, "lain", "locks", "suite.lock")
    end

    # Runs inside each bisect step, in the step's worktree: skips specs the commit does not have.
    # @return [Integer] the exit status git bisect reads
    def self.run_step(specs, env: ENV)
      present = specs.select { |path| File.exist?(path) }
      return 0 if present.empty?

      command = env[STEP_VARIABLE]
      command ? exit_status(*JSON.parse(command), *present) : default_step(present, env)
    end

    # A step that cannot say pass or fail is a skip, never a fail that would blame an innocent commit.
    def self.exit_status(*command)
      started = system(*command)
      started.nil? ? SKIP : ($CHILD_STATUS.exitstatus || SKIP)
    end

    def self.main(argv)
      run_step(argv)
    rescue StandardError, ScriptError => e
      warn "bisect step could not run: #{e.message}"
      SKIP
    end

    # The suite lock is held per step, not across the bisect, so a commit hook is never starved for hours.
    def self.default_step(specs, env)
      holding_suite_lock(env) do
        compiled = system("bundle", "exec", "rake", "compile")
        compiled ? exit_status({ "LAIN_SLOW" => "1" }, "bundle", "exec", "rspec", *specs) : SKIP
      end
    end
    private_class_method :default_step

    def self.holding_suite_lock(env, &block)
      return yield if env["LAIN_SUITE_LOCK_HELD"] == "1"

      path = suite_lock_path(env)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        warn "waiting on the suite lock (#{path})" unless file.flock(File::LOCK_EX | File::LOCK_NB)
        file.flock(File::LOCK_EX)
        yield
      end
    end
    private_class_method :holding_suite_lock

    # @param step [Array<String>, nil] a command given the specs present at the commit; nil is compile then rspec
    # @param repo [String] the repository's top level
    # @param good [String, nil] the last known green commit
    # @param head [String] the red commit
    # @param staged [String] the staged tree id
    # @param specs [Array<String>] the failed spec files
    # @param notify [#call] told the verdict's summary
    def initialize(repo:, good:, head:, staged:, specs:, step: nil, notify: NOTIFY)
      @repo = repo
      @good = good
      @head = head
      @staged = staged
      @specs = specs
      @step = step
      @notify = notify
    end

    # @return [Integer] 0 once a verdict is written or another bisect holds the lock; 1 when the bisect itself failed
    def call
      unless @good
        return deliver(Verdict.new(:impossible, nil,
                                   "no bisect is possible: no earlier commit had a green run"))
      end

      FileUtils.mkdir_p(File.dirname(lock_path))
      status = 0
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        status = deliver(attempt) if lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
      status
    end

    def lock_path = File.join(common_dir, "lain", "test-map", "bisect-#{short}.lock")

    private

    def attempt
      find
    rescue StandardError => e
      Verdict.new(:failed, nil, "bisect failed: #{e.message}")
    end

    def find
      with_worktree { |worktree| with_step_env(worktree) { judge(worktree) } }
    end

    def judge(worktree)
      if green?(worktree, staged_commit)
        Verdict.new(:flake, nil, "flake: the staged tree passed when run again")
      elsif green?(worktree, @head)
        Verdict.new(:staged, nil, "the staged change is the first bad change")
      else
        first_bad(worktree)
      end
    end

    def first_bad(worktree)
      git("bisect", "start", @head, @good, repo: worktree)
      git("bisect", "run", *runner, repo: worktree)
      commit = git("rev-parse", "refs/bisect/bad", repo: worktree).strip
      git("bisect", "reset", repo: worktree)
      Verdict.new(:commit, commit, "first bad commit #{commit}: #{git("log", "-1", "--format=%s", commit).strip}")
    end

    def green?(worktree, commit)
      git("checkout", "-q", "--detach", commit, repo: worktree)
      system(*runner, chdir: worktree, out: [log_path, "a"], err: %i[child out])
      status = $CHILD_STATUS&.exitstatus
      raise "the step could not run at #{commit}" if status.nil? || status == SKIP

      status.zero?
    end

    # The commit object is left unreferenced; gc collects it.
    def staged_commit
      git("-c", "user.name=bisect", "-c", "user.email=bisect@localhost",
          "commit-tree", @staged, "-p", @head, "-m", "staged tree").strip
    end

    def runner = [RbConfig.ruby, File.expand_path(__FILE__), "--step", *@specs]

    # git bisect run inherits this process's environment, so it is set here rather than passed.
    def with_step_env(worktree)
      env = SCRUBBED.to_h { |key| [key, nil] }.merge(
        "CARGO_TARGET_DIR" => File.join(@repo, "tmp", "test-map-bisect-target"),
        "BUNDLE_GEMFILE" => File.join(worktree, "Gemfile")
      )
      env[STEP_VARIABLE] = JSON.generate(@step) if @step
      saved = env.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      ENV.update(env)
      yield
    ensure
      ENV.update(saved)
    end

    def with_worktree
      path = File.join(@repo, "tmp", "worktrees", "bisect-#{short}")
      FileUtils.mkdir_p(File.dirname(path))
      remove_worktree(path)
      git("worktree", "add", "-q", "--detach", path, @head)
      yield path
    ensure
      remove_worktree(path)
    end

    def remove_worktree(path)
      FileUtils.rm_rf(path)
      git("worktree", "prune")
    end

    # @return [Integer] 1 for a failed bisect, else 0
    def deliver(verdict)
      FileUtils.mkdir_p(File.dirname(log_path))
      File.open(log_path, "a") { |log| log.puts(verdict.summary) }
      @notify.call(verdict.summary)
      verdict.kind == :failed ? 1 : 0
    end

    def git(*, repo: @repo) = Git.run(*, repo:)

    def short = @short ||= git("rev-parse", "--short", @head).strip

    def common_dir = git("rev-parse", "--path-format=absolute", "--git-common-dir").strip

    def log_path = File.join(common_dir, "lain", "test-map", "bisect-#{short}.log")
  end
end

exit(TestMap::Bisect.main(ARGV.drop(1))) if $PROGRAM_NAME == __FILE__
