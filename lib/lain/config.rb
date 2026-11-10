# frozen_string_literal: true

module Lain
  # Reads `<root>/.lain/config.rb`, evaluated by {Builder}. Absence is not an
  # error -- {.load} on a root with no file returns the same value {.empty}
  # does, so a caller never writes an `if File.exist?` guard of its own (Null
  # Object).
  #
  # The file is Ruby, so it runs only once {Project::Trust} says its bytes are
  # trusted, and what runs is the bytes the trust was judged on. It is
  # evaluated whole, so a refusal anywhere in it refuses every reader: there is
  # no reading one table past a typo in another.
  #
  # Each table is one small class's whole surface -- {Epics}, {Answers},
  # {Isolation}, {Sensitivity::Rules}, {Shell::Exclusions}, {SearchRules},
  # {TestLayout} -- so a wrong-shaped value inside one is loud instead of silently defaulting or
  # crashing three call frames deep.
  #
  # The user's `$XDG_CONFIG_HOME/lain/config.rb` is read by {.middleware},
  # {.keys} and {.theme}, under its own trust, and may declare nothing but
  # middleware, keys and theme.
  class Config
    # The evaluated file, memoised on its path and trusted bytes: a `lain chat`
    # startup asks the four readers below for one file, and an edit is new
    # bytes, so it is evaluated afresh once trusted. Nothing is evicted; the
    # entries are bounded by the roots one process resolves and the edits made
    # while it runs. The cop cannot see that the mutex below guards the table.
    @built = {} # rubocop:disable ThreadSafety/MutableClassInstanceVariable
    @lock = Mutex.new

    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [Config]
    # @raise [Project::Trust::Untrusted] when the file's bytes are not trusted
    # @raise [Refusal] naming the file and line of whatever it got wrong
    def self.load(root: Dir.pwd)
      built = built(root)
      new(epics: built.epics, approval: built.approval, isolation: built.isolation, env_pass: built.env_pass,
          todos: built.todos, approval_timeout: built.approval_timeout, approval_silence: built.approval_silence,
          judge_timeout: built.judge_timeout, review: built.review, budget: built.budget,
          remote_relay: built.remote_relay, remote_ntfy: built.remote_ntfy)
    end

    # What a project adds to the path classifier's built-in tables, and the
    # one thing it may take away.
    #
    # `root:` is REQUIRED where {.load}'s is defaulted: the one production
    # caller holds a resolved {Project}, and a working-directory default is the
    # divergence {Sensitivity.new} refuses for the same reason.
    # `spec/lain/project/root_defaults_spec.rb` is the guard.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [Sensitivity::Rules] empty when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.sensitivity(root:) = built(root).sensitivity

    # The programs this project has ruled out of every shell command, whatever
    # else the command says. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [Shell::Exclusions] empty -- restricting nothing -- when the file
    #   or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.shell_exclusions(root:) = built(root).shell

    # How long an unanswered parked call or epic gate waits before it denies.
    # `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [Numeric] seconds, above 0; {Approval::Parked::Queue::DEFAULT_TIMEOUT} when unset
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.approval_timeout(root:) = built(root).approval_timeout

    # The reasoning level a project asks its chats to send, when the model accepts it.
    # `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [String, nil] nil when the file or the key is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.think(root:) = built(root).think

    # The model a project reviews documents with. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [Review] naming no model when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.review(root:) = built(root).review

    # How many iterations an ask may run, by skill and role. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [Budget::Table] the defaults, with any row the file's `budget` verb replaces
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.budget(root:) = built(root).budget

    # What a project searches beyond the files git shows, and how much one
    # walk may cost. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @return [SearchRules] empty when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.search(root:) = built(root).search

    # The middleware the user's config.rb and then this project's ask to run in
    # each phase. The only reader of the user's file: it runs in every project,
    # so it may add middleware and never loosen a project's own tables.
    # `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the user's config.rb and the state home both marks live in
    # @return [Middleware] empty when neither file declares the table
    # @raise [Project::Trust::Untrusted] as {.load}, for either file
    # @raise [Project::Trust::Unreadable] when either file's path is not a regular file
    # @raise [Refusal] as {.load}, for either file
    def self.middleware(root:, paths: Paths.new) = user(paths).middleware + built(root, paths:).middleware

    # The keys the user's config.rb rebinds. Only that file may declare them.
    #
    # @param paths [Paths] where the user's config.rb lives
    # @return [Keys] every key at its default when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the user's file and line
    def self.keys(paths: Paths.new) = user(paths).keys

    # The styles the user's config.rb gives tokens. Only that file may declare them.
    #
    # @param paths [Paths] where the user's config.rb lives
    # @return [Theme] every token at its default when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the user's file and line
    def self.theme(paths: Paths.new) = user(paths).theme

    # Where this project keeps its tests, which the layout guard holds a test
    # file's path to. With no table the layout falls back to the preset of a
    # framework the caller passes; detection is the caller's, because the test
    # harness that knows how loads long after this file does.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param framework [String, nil] a detected test framework. A caller that
    #   enforces the layout never passes one, so enforcement is opt-in: a
    #   detected preset imposes level roots the project never declared, and
    #   would refuse its existing flat specs as strays.
    # @param vouched_by [Project::Trust, nil] a trusted project whose exact bytes `root` holds, so a
    #   copy the caller made of it needs no mark of its own
    # @return [TestLayout] {TestLayout::None} when neither says what the layout is
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.test_layout(root:, framework: nil, vouched_by: nil) = built(root, vouched_by:).test_layout(framework:)

    # A catalog whose own file is absent reads nothing else, the posture
    # {DslCatalog.load} takes, so an untrusted sibling cannot refuse a project
    # that has no config.
    #
    # A path that exists but is not a regular file refuses: reading it as
    # absent would drop the restricting tables in silence.
    def self.built(root, paths: Paths.new, vouched_by: nil)
      project_dir = ProjectDir.new(root:, paths:)
      path = project_dir.config
      return Builder.new(path).built unless File.exist?(path)

      judged(path, Project::Trust.for(project_dir:, paths:), Builder::VERBS, "this project's", "project", vouched_by:)
    end

    def self.user(paths)
      path = paths.user_config
      return Builder.new(path).built unless File.exist?(path)

      judged(path, Project::Trust.for_user(paths:), Builder::USER_VERBS, "the user's", "user")
    end

    # The digest is stamped after the memo, which is keyed on config.rb alone
    # while the trust covers every `.lain/*.rb`.
    def self.judged(path, trust, verbs, whose, side, vouched_by: nil)
      source = trust.sources[path]
      raise Project::Trust::Unreadable, Project::Trust.legible(format(NOT_A_FILE, path:, whose:)) if source.nil?

      trust.require!(vouched_by:)
      outcome = evaluated(path, source, verbs)
      raise outcome if outcome.is_a?(Refusal)

      outcome.with(middleware: outcome.middleware.trusted_by(side, trust.digest))
    end

    # A refusal is memoised like a value, so a failing file runs once too.
    def self.evaluated(path, source, verbs)
      @lock.synchronize do
        @built.fetch([path, source]) do
          @built[[path, source]] = begin
            Builder.evaluate(source, path:, verbs:)
          rescue Refusal => e
            e
          end
        end
      end
    end
    private_class_method :built, :user, :judged, :evaluated

    # Drops every memoised evaluation, for a forked child whose cwd and environment are not
    # the ones the memo was built in. A lock another thread held at the fork is abandoned by
    # Ruby in the child, so this cannot wait on it.
    #
    # @return [nil]
    def self.forget!
      @lock.synchronize { @built.clear }
      nil
    end

    NOT_A_FILE = "%<path>s is not a regular file, so %<whose>s config cannot be read"
    private_constant :NOT_A_FILE

    # @return [Config] every field at its default -- the value an absent file yields.
    def self.empty
      EMPTY
    end

    # A literal, not {Approval::Parked::Queue::DEFAULT_TIMEOUT}: naming that constant
    # here would load the approval unit when this file loads (see {EMPTY}).
    DEFAULT_APPROVAL_TIMEOUT = 300

    # Spelled as a literal for the same reason; a spec pins it to {Approval::Judge::TIMEOUT}.
    DEFAULT_JUDGE_TIMEOUT = 30

    # A Symbol rather than {Approval::Silence::HOLD}, for {DEFAULT_APPROVAL_TIMEOUT}'s reason.
    DEFAULT_APPROVAL_SILENCE = :hold

    attr_reader :epics, :approval, :isolation

    # @return [Array<String>] the variables `env pass:` hands every child,
    #   beyond what {Exec::ChildEnv::KEEP} keeps
    attr_reader :env_pass

    # @return [Todos] which file in the project root holds the chores
    attr_reader :todos

    # @return [Numeric] seconds an unanswered parked call or epic gate waits before {#approval_silence} settles it
    attr_reader :approval_timeout

    # @return [Symbol] what an unanswered parked call or epic gate settles as, :hold or :deny;
    #   {Approval::Silence.from} reads it
    attr_reader :approval_silence

    # @return [Numeric] seconds the `auto` approval judge may take before its call goes to a human
    attr_reader :judge_timeout

    # @return [Review] the model a document review runs under
    attr_reader :review

    # @return [Budget::Table] how many iterations an ask may run, by skill and role
    attr_reader :budget

    # @return [String, nil] the address the phone relay listens on, `ip:port`; nil leaves the phone surface off
    attr_reader :remote_relay

    # @return [String, nil] the ntfy topic URL a waiting item is announced on
    attr_reader :remote_ntfy

    def initialize(epics:, approval: Answers.empty, isolation: Isolation.empty, env_pass: [], todos: Todos.empty,
                   approval_timeout: DEFAULT_APPROVAL_TIMEOUT, approval_silence: DEFAULT_APPROVAL_SILENCE,
                   judge_timeout: DEFAULT_JUDGE_TIMEOUT, review: Review.empty, budget: Budget::Table.new,
                   remote_relay: nil, remote_ntfy: nil)
      @epics = epics
      @approval = Answers.coerce(approval)
      @isolation = Isolation.coerce(isolation)
      @env_pass = env_pass.map(&:-@).freeze
      @todos = todos
      @approval_timeout = approval_timeout
      @approval_silence = approval_silence
      @judge_timeout = judge_timeout
      @review = review
      @budget = budget
      @remote_relay = remote_relay
      @remote_ntfy = remote_ntfy
      freeze
    end

    def epics_home = epics.home

    # @param stage [#to_s] an {Epic::Stage} or its name
    # @return [String] the gate policy that stage runs under, "interactive"
    #   unless `epics` gates says otherwise
    def gate_policy_for(stage) = epics.gates.policy_for(stage)

    # `instance_of?`, not `is_a?`: equality must be symmetric, and a subclass
    # `is_a?` its parent while a parent is never `is_a?` its subclass. `#hash`
    # mixes in `self.class` for the same reason -- two values a Hash should
    # treat as distinct keys must not collide.
    def ==(other) = other.instance_of?(self.class) && state == other.state
    alias eql? ==

    def hash = [self.class, *state].hash

    protected

    def state
      [epics, approval, isolation, env_pass, todos, approval_timeout, approval_silence, judge_timeout, review,
       budget, remote_relay, remote_ntfy]
    end

    # The default `gates` table must stay EMPTY. {Epics::Gates.check!} reads
    # `Epic::STAGES` and {Epic::Gate::Policies}, so a non-empty default
    # here would reach two unrelated units while this file loads -- reaching
    # config would then reach the epic tier and the approval gate with it.
    # `gates_spec.rb` boots a child without the eager load and asks exactly
    # that.
    EMPTY = new(epics: Epics.new(home: :xdg)).freeze
    private_constant :EMPTY
  end
end
