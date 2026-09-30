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
  # {Isolation}, {Sensitivity::Rules}, {Shell::Exclusions}, {TestLayout} -- so
  # a wrong-shaped value inside one is loud instead of silently defaulting or
  # crashing three call frames deep.
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
      new(epics: built.epics, approval: built.approval, isolation: built.isolation)
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
    # @return [TestLayout] {TestLayout::None} when neither says what the layout is
    # @raise [Project::Trust::Untrusted] as {.load}
    # @raise [Refusal] as {.load}
    def self.test_layout(root:, framework: nil) = built(root).test_layout(framework:)

    # A catalog whose own file is absent reads nothing else, the posture
    # {DslCatalog.load} takes, so an untrusted sibling cannot refuse a project
    # that has no config.
    #
    # A path that exists but is not a regular file refuses: reading it as
    # absent would drop the restricting tables in silence.
    def self.built(root)
      project_dir = ProjectDir.new(root:)
      path = project_dir.config
      return Builder.new(path).built unless File.exist?(path)

      trust = Project::Trust.for(project_dir:)
      source = trust.sources[path]
      raise Project::Trust::Unreadable, Project::Trust.legible(format(NOT_A_FILE, path:)) if source.nil?

      trust.require!
      outcome = evaluated(path, source)
      raise outcome if outcome.is_a?(Refusal)

      outcome
    end

    # A refusal is memoised like a value, so a failing file runs once too.
    def self.evaluated(path, source)
      @lock.synchronize do
        @built.fetch([path, source]) do
          @built[[path, source]] = begin
            Builder.evaluate(source, path:)
          rescue Refusal => e
            e
          end
        end
      end
    end
    private_class_method :built, :evaluated

    NOT_A_FILE = "%<path>s is not a regular file, so this project's config cannot be read"
    private_constant :NOT_A_FILE

    # @return [Config] every field at its default -- the value an absent file yields.
    def self.empty
      EMPTY
    end

    attr_reader :epics, :approval, :isolation

    def initialize(epics:, approval: Answers.empty, isolation: Isolation.empty)
      @epics = epics
      @approval = Answers.coerce(approval)
      @isolation = Isolation.coerce(isolation)
      freeze
    end

    def epics_home = epics.home

    # @param stage [#to_s] an {Epic::Stage} or its name
    # @return [String] the gate policy that stage runs under, "interactive"
    #   unless `[epics.gates]` says otherwise
    def gate_policy_for(stage) = epics.gates.policy_for(stage)

    # `instance_of?`, not `is_a?`: equality must be symmetric, and a subclass
    # `is_a?` its parent while a parent is never `is_a?` its subclass. `#hash`
    # mixes in `self.class` for the same reason -- two values a Hash should
    # treat as distinct keys must not collide.
    def ==(other)
      other.instance_of?(self.class) && epics == other.epics && approval == other.approval &&
        isolation == other.isolation
    end
    alias eql? ==

    def hash
      [self.class, epics, approval, isolation].hash
    end

    # The default `gates` table must stay EMPTY. {Epics::Gates.check!} reads
    # `Epic::STAGES` and {Approval::Gate::Policies}, so a non-empty default
    # here would reach two unrelated units while this file loads -- reaching
    # config would then reach the epic tier and the approval gate with it.
    # `gates_spec.rb` boots a child without the eager load and asks exactly
    # that.
    EMPTY = new(epics: Epics.new(home: :xdg)).freeze
    private_constant :EMPTY
  end
end
