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
  # {.keys}, {.theme}, {.attention} and {.github}, under its own trust, and may declare
  # nothing but middleware, keys, theme, attention and github.
  class Config
    # The evaluated file, memoised on its path and trusted bytes: a `lain chat`
    # startup asks the readers below for one file, and an edit is new
    # bytes, so it is evaluated afresh once trusted. Nothing is evicted; the
    # entries are bounded by the roots one process resolves and the edits made
    # while it runs. The cop cannot see that the mutex below guards the table.
    @built = {} # rubocop:disable ThreadSafety/MutableClassInstanceVariable
    @lock = Mutex.new

    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [Config]
    # @raise [Project::Trust::Untrusted] when the file's bytes are not trusted
    # @raise [Refusal] naming the file and line of whatever it got wrong
    def self.load(paths:, root: Dir.pwd)
      built = built(root, paths:)
      new(epics: built.epics, approval: built.approval, isolation: built.isolation, env_pass: built.env_pass,
          todos: built.todos, approval_timeout: built.approval_timeout, approval_silence: built.approval_silence,
          judge_timeout: built.judge_timeout, judge_memo: built.judge_memo, review: built.review, budget: built.budget)
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
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [Sensitivity::Rules] empty when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.sensitivity(root:, paths:) = built(root, paths:).sensitivity

    # The programs this project has ruled out of every shell command, whatever
    # else the command says. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [Shell::Exclusions] empty -- restricting nothing -- when the file
    #   or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.shell_exclusions(root:, paths:) = built(root, paths:).shell

    # How long an unanswered parked call or epic gate waits before it denies.
    # `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [Numeric] seconds, above 0; {Approval::Parked::Queue::DEFAULT_TIMEOUT} when unset
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.approval_timeout(root:, paths:) = built(root, paths:).approval_timeout

    # The reasoning level a project asks its chats to send, when the model accepts it.
    # `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [String, nil] nil when the file or the key is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.think(root:, paths:) = built(root, paths:).think

    # The model a project reviews documents with. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [Review] naming no model when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.review(root:, paths:) = built(root, paths:).review

    # How many iterations an ask may run, by skill and role. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [Budget::Table] the defaults, with any row the file's `budget` verb replaces
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.budget(root:, paths:) = built(root, paths:).budget

    # What a project searches beyond the files git shows, and how much one
    # walk may cost. `root:` is REQUIRED, as {.sensitivity}'s is.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @return [SearchRules] empty when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.search(root:, paths:) = built(root, paths:).search

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
    def self.middleware(root:, paths:) = user(paths).middleware + built(root, paths:).middleware

    # The phone's approval surface: where the relay listens and the topic a waiting item is announced on.
    # Only the user's config.rb may declare it, since one phone listener serves the whole machine.
    #
    # @param paths [Paths] where the user's config.rb lives
    # @return [Hash{Symbol => String, nil}] `relay:` and `ntfy:`, each nil when not set
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the user's file and line
    def self.remote(paths:)
      built = user(paths)
      { relay: built.remote_relay, ntfy: built.remote_ntfy }
    end

    # Whether the user's config.rb has a `github` verb that sets any key, even to its default.
    # A bare `github` with no keys reads the same as no verb.
    #
    # @param paths [Paths] where the user's config.rb lives
    # @return [Boolean]
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the user's file and line
    def self.user_github?(paths:) = user(paths).github != Github.empty

    # Whether the project's own config.rb has a `github` verb that sets any key, even to the value the
    # user's file gives it.
    #
    # @param root [String] a project root
    # @param paths [Paths] where the user's config.rb lives
    # @return [Boolean]
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the project's file and line
    def self.project_github?(root:, paths:) = built(root, paths:).github != Github.empty

    # The keys the user's config.rb rebinds. Only that file may declare them.
    #
    # @param paths [Paths] where the user's config.rb lives
    # @return [Keys] every key at its default when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the user's file and line
    def self.keys(paths:) = user(paths).keys

    # The styles the user's config.rb gives tokens. Only that file may declare them.
    #
    # @param paths [Paths] where the user's config.rb lives
    # @return [Theme] every token at its default when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the user's file and line
    def self.theme(paths:) = user(paths).theme

    # How long a blocked or finished chat waits before it asks for the person. Only the user's config.rb may declare it.
    #
    # @param paths [Paths] where the user's config.rb lives
    # @return [Attention] a 30 second delay when the file or the table is absent
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] naming the user's file and line
    def self.attention(paths:) = user(paths).attention

    # The GitHub account and review-request filters: the environment, then the
    # project's file, then the user's, field by field. `root: nil` is a caller
    # outside any project, and reads the user's file and the environment only.
    #
    # @param root [String, nil] a project root, or nil outside a project
    # @param paths [Paths] where the user's config.rb lives
    # @param env [Hash{String=>String}] read for `LAIN_GH_ACCOUNT`
    # @return [Github] every field resolved, the account nil for gh's own
    # @raise [Project::Trust::Untrusted] as {.load}, for either file
    # @raise [Refusal] as {.load}, for either file
    def self.github(root:, paths:, env: ENV)
      project = root ? built(root, paths:).github : Github.empty
      Github.resolve(project:, user: user(paths).github, env:)
    end

    # Where this project keeps its tests, which the layout guard holds a test
    # file's path to. With no table the layout falls back to the preset of a
    # framework the caller passes; detection is the caller's, because the test
    # harness that knows how loads long after this file does.
    #
    # @param root [String] a project root; `.lain/config.rb` is resolved under it
    # @param paths [Paths] the state home the project's trust is kept in
    # @param framework [String, nil] a detected test framework. A caller that
    #   enforces the layout never passes one, so enforcement is opt-in: a
    #   detected preset imposes level roots the project never declared, and
    #   would refuse its existing flat specs as strays.
    # @param vouched_by [Project::Trust, nil] a trusted project whose exact bytes `root` holds, so a
    #   copy the caller made of it needs no mark of its own
    # @return [TestLayout] {TestLayout::None} when neither says what the layout is
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.test_layout(root:, paths:, framework: nil, vouched_by: nil)
      built(root, paths:, vouched_by:).test_layout(framework:)
    end

    # A catalog whose own file is absent reads nothing else, the posture
    # {DslCatalog.load} takes, so an untrusted sibling cannot refuse a project
    # that has no config.
    #
    # A path that exists but is not a regular file refuses: reading it as
    # absent would drop the restricting tables in silence.
    def self.built(root, paths:, vouched_by: nil)
      project_dir = ProjectDir.new(root:, paths:)
      path = project_dir.config
      return Builder.new(path).built unless File.exist?(path)

      judged(path, Project::Trust.for(project_dir:, paths:), Builder::VERBS, "this project's", "project",
             user_config: paths.user_config, vouched_by:)
    end

    def self.user(paths)
      path = paths.user_config
      return Builder.new(path).built unless File.exist?(path)

      judged(path, Project::Trust.for_user(paths:), Builder::USER_VERBS, "the user's", "user")
    end

    # The digest is stamped after the memo, which is keyed on config.rb alone
    # while the trust covers every `.lain/*.rb`.
    def self.judged(path, trust, verbs, whose, side, user_config: nil, vouched_by: nil)
      source = trust.sources[path]
      raise Project::Trust::Unreadable, Project::Trust.legible(format(NOT_A_FILE, path:, whose:)) if source.nil?

      trust.require!(vouched_by:)
      outcome = evaluated(path, source, verbs, user_config)
      raise outcome if outcome.is_a?(Refusal)

      outcome.with(middleware: outcome.middleware.trusted_by(side, trust.digest))
    end

    # A refusal is memoised like a value, so a failing file runs once too.
    def self.evaluated(path, source, verbs, user_config)
      @lock.synchronize do
        @built.fetch([path, source, user_config]) do
          @built[[path, source, user_config]] = begin
            Builder.evaluate(source, path:, verbs:, user_config:)
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

    # Whether the `auto` judge's approvals settle an exact repeat, when the approval table does not say.
    DEFAULT_JUDGE_MEMO = true

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

    # @return [Boolean] whether the `auto` approval judge's approvals settle an exact repeat this session
    attr_reader :judge_memo

    # @return [Review] the model a document review runs under
    attr_reader :review

    # @return [Budget::Table] how many iterations an ask may run, by skill and role
    attr_reader :budget

    def initialize(epics:, approval: Answers.empty, isolation: Isolation.empty, env_pass: [], todos: Todos.empty,
                   approval_timeout: DEFAULT_APPROVAL_TIMEOUT, approval_silence: DEFAULT_APPROVAL_SILENCE,
                   judge_timeout: DEFAULT_JUDGE_TIMEOUT, judge_memo: DEFAULT_JUDGE_MEMO, review: Review.empty,
                   budget: Budget::Table.new)
      @epics = epics
      @approval = Answers.coerce(approval)
      @isolation = Isolation.coerce(isolation)
      @env_pass = env_pass.map(&:-@).freeze
      @todos = todos
      @approval_timeout = approval_timeout
      @approval_silence = approval_silence
      @judge_timeout = judge_timeout
      @judge_memo = judge_memo
      @review = review
      @budget = budget
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
      [epics, approval, isolation, env_pass, todos, approval_timeout, approval_silence, judge_timeout, judge_memo,
       review, budget]
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
