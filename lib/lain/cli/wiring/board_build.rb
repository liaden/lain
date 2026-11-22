# frozen_string_literal: true

require "pathname"

module Lain
  module CLI
    class Wiring
      # What the run's {Switchboard} is BUILT FROM. Every half turns the
      # resolved {Lain::Project} into an authority, and none is the board's own
      # question: the trusted config says which remembered answers this root
      # contributes, the path boundary below says which paths it gates and
      # which it refuses outright, and {.shell_verdict} says which programs it
      # refuses by name. {.approving} is where the path boundary comes back as
      # an authority of a different kind: the same classifier factory, handed to
      # the one rule that can APPROVE a command rather than refuse one.
      #
      # That last one is the odd member and is here anyway, because this is
      # where a project's config becomes an authority. It is the only one the
      # board SHARES with something outside itself -- {Lain::Tools::Bash} holds
      # the same instance -- so it is built here and handed back to {Wiring}
      # rather than kept.
      #
      # == They are two vocabularies, and the resemblance is a trap
      #
      # The remembered `rules` are APPROVAL rules -- call SHAPES a trusted
      # config pre-approves, which GRANT. The `sensitivity` table's rules are PATH
      # rules, which restrict and grant nothing. Both arrive at
      # {Switchboard.for} as keywords, and one silently accepted where the
      # other belongs would be a config file's denials read as permissions.
      # They are assembled in one place so a reader sees both names at once.
      module BoardBuild
        module_function

        # @param chronicle [CLI::Chronicle] resolves the journal the switches record onto
        # @param options [Hash] the CLI's parsed surface flags
        # @param model [String] the model in force until the first /model
        # @param toolset [Lain::Toolset] the run's BASE capability set
        # @param project [Lain::Project] the run's resolved root and cwd
        # @param paths [Paths] supplies the HOME the classifier anchors its
        #   home-relative rules against
        # @param verdict [#call] the session's ONE shell verdict, built by
        #   {.shell_verdict} and passed in rather than built here: the bash
        #   tool holds the same instance, and this module is called AFTER the
        #   toolset exists. A default built here could not be shared, so it is
        #   the permissive one and the production call site must pass the
        #   session's -- which is what this file's identity example pins.
        # @param middleware [Config::Middleware] what the launch read from
        #   config.rb; its tool members run ahead of every guard
        # @param config [Config] `.lain/config.rb`, whose remembered answers the board approves
        # @param judge [#call] what `auto` approval asks first, on {Switchboard#initialize}'s terms
        # @param display [#<<] where a call the judge approves is told to the human
        # @param arms [Lain::CLI::Arms] the bench arms the run was started with;
        #   any `confine` but off rules approvals by the resolved class, and any
        #   `judge_facts` but off tells the judge each stage's resolution
        # @param request [#call] `context -> Approval::Judge::Request or nil`, what a judged call
        #   was made for, on {Switchboard.for}'s terms
        # @param identity [Hash] `resolver:` and `worker_env:`, on {Classifiers#initialize}'s
        #   terms: the session's ONE resolver, the instance the bash tool holds,
        #   and the session's own env, whose PATH the main agent's stages resolve through
        # @param child_env [Lain::Exec::ChildEnv] the launch's, one half of the board's secrets source
        # @param stops [Lain::Tripwire::Stops, Lain::Tripwire::Stops::None] who the tripwire stopped
        # @param masks [Approval::Judgement::Masking, Approval::Judgement::Unmasked] the workspace sandbox a call
        #   the judge approves runs under, as {ToolsetBuild#board_inputs} answers; none by default
        # @param containment [Confine::Sandbox::Containment, Confine::Sandbox::Containment::Deferred]
        #   whether bash can run a call that reads secrets
        #   contained, as {ToolsetBuild#board_inputs} answers; unstated by default
        # @param fresh [Lain::Shell::Executable::Fresh, Lain::Shell::Executable::Fresh::Unmarked] the lineage the
        #   toolset's sandbox reads, whose unread command bars a build; none by default
        # @param human [Human] who answers this session, handed on to {Switchboard.for}
        # @option options [String] :approval the session's starting approval level,
        #   read by {Switchboard.for}, never here
        # @return [Switchboard]
        def for(chronicle:, options:, model:, toolset:, project:, judge:, human:,
                paths: Paths.new, verdict: Lain::Shell::Verdict.new, middleware: Config::Middleware.empty,
                config: Config.load(root: project.root, paths:), display: Channel::Null.instance,
                arms: Lain::CLI::Arms::OFF, request: Lain::Approval::Judge::Unrequested,
                child_env: Lain::Exec::ChildEnv::DEFAULT, stops: Lain::Tripwire::Stops::None,
                masks: Lain::Approval::Judgement::Unmasked, containment: Lain::Confine::Sandbox::Containment::NONE,
                fresh: Lain::Shell::Executable::Fresh::Unmarked, **identity)
          # Compiled once: the exemption check stats the disk.
          table = rules(project:, paths:)
          # The SAME factory reaches both the triage rung and the approving
          # rule, so the two rungs cannot disagree about where a relative word
          # in one command's argv lands.
          sensitivity = session_policy(project:, paths:, table:, config:)
          factory = classifiers(project:, paths:, table:, facts: sensitivity.file_facts,
                                reads: sensitivity.read_roots, **identity)
          Switchboard.for(chronicle:, options:, human:, model:, toolset:, verdict:,
                          rules: [Lain::Approval::Remembered.from(config)].reject(&:empty?),
                          approving: approving_under(arms, masks, child_env),
                          sensitivity:, spike: PlanSpike.new(project:, paths:),
                          classifiers: factory, middleware:, child_env:,
                          test_layout: test_layout(project:, paths:, file_facts: sensitivity.file_facts),
                          approval_timeout: Config.approval_timeout(root: project.root, paths:),
                          silence: Lain::Approval::Silence.from(config), judge:, display:, arms:,
                          request:, containment:, fresh:, granting: granting(masks, fresh:, project:, paths:),
                          secrets: secrets(project:, sensitivity:, child_env:, journal: chronicle.record_journal),
                          denied_tools: config.approval.deny_tools, stops:, masks:, memo: judge_memo(config))
        end

        # Masks are on exactly where the toolset wrapped bash in the workspace sandbox, the one sandbox that grants
        # a build its ports, so that is where a layer ahead of the gate may ask what it would grant.
        #
        # @param masks [Approval::Judgement::Masking, Approval::Judgement::Unmasked] as on {.for}
        # @param fresh [Lain::Shell::Executable::Fresh, Lain::Shell::Executable::Fresh::Unmarked] the sandbox's lineage
        # @param project [Project]
        # @param paths [Paths] whose home the sandbox reads the toolchains under
        # @return [Lain::Confine::Profiles::Granting, Lain::Confine::Profiles::Granting::NONE]
        def granting(masks, fresh:, project:, paths:)
          return Lain::Confine::Profiles::Granting::NONE unless masks.on?

          Lain::Confine::Profiles::Granting.over(fresh:, home: paths.home, root: project.root)
        end

        # One for the board, so every judged rung it builds, a leased worker's included, shares it.
        #
        # @param config [Config]
        # @return [Lain::Approval::JudgeMemo, Lain::Approval::JudgeMemo::Off] off when the project turned it off
        def judge_memo(config) = config.judge_memo ? Lain::Approval::JudgeMemo.new : Lain::Approval::JudgeMemo.off

        # What every agent of the session reads outside the project without
        # asking and never writes: where a spawner spills an oversized answer,
        # a Rust project's fetched crate sources, and the epic home when it
        # lives outside the repository. A config `related` directory masks a
        # flagged region silently, and a read root does not, so a secret here
        # still parks.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param epics [String, nil] see {.epic_home}
        # @param env [#[]] where CARGO_HOME is read, as cargo reads it
        # @return [Array<String>] absolute
        def read_roots(project:, paths:, epics:, env: ENV)
          [Lain::Tool::Spill.home(paths, project.root), *package_caches(project:, paths:, env:), *epics]
        end

        # Published sources, too many to list for masks, so they are read roots rather than related directories.
        CARGO_CACHES = ["registry/src", Lain::Confine::MaskList::CARGO_CHECKOUTS].freeze

        # A relative CARGO_HOME resolves against whatever directory cargo runs in, so it lends nothing.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param env [#[]]
        # @return [Array<String>] absolute; cargo's caches when the project has a Cargo.toml, else none
        def package_caches(project:, paths:, env: ENV)
          return [] unless File.file?(File.join(project.root, "Cargo.toml"))

          cargo_home = env["CARGO_HOME"].to_s.empty? ? File.join(paths.home, ".cargo") : env["CARGO_HOME"]
          cargo_home.start_with?(File::SEPARATOR) ? CARGO_CACHES.map { File.join(cargo_home, _1) } : []
        end

        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param table [Lain::Sensitivity::Rules]
        # @param config [Config] whose `epics` home says where the epics live
        # @return [Lain::Sensitivity::Policy] the session's, reading the epic home and never writing it
        def session_policy(project:, paths:, table:, config:)
          epics = epic_home(project:, paths:, config:)
          policy(project:, paths:, table:, epic_home: epics, read_roots: read_roots(project:, paths:, epics:))
        end

        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param config [Config] whose `epics` home says where the epics live
        # @return [String, nil] absolute; nil when the epics live in the repository
        def epic_home(project:, paths:, config:)
          config.epics_home == :xdg ? Lain::Epic::Home.container(config:, paths:, root: project.root) : nil
        end

        # Where `/mode plan` confines this project's session: a spike worktree
        # when the project is in a git repository, and a scratch directory when
        # it is not. Asked when plan scope is entered rather than at startup, so
        # a chat that never enters it never searches for a repository, and one
        # made a repository mid-session is cut a spike. The source a lease came
        # from is the one asked about it afterwards, whatever the disk says by
        # then.
        class PlanSpike
          # @param project [Lain::Project] whose root the repository is searched
          #   from, and whose cwd the spike mirrors
          # @param paths [Paths] the state home the fleet's worktree root is under
          def initialize(project:, paths:)
            @project = project
            @paths = paths
            @sources = {}.compare_by_identity
          end

          # @return [Lain::Isolation::Lease]
          def acquire
            from = source
            from.acquire.tap { |lease| @sources[lease] = from }
          end

          # @param lease [Lain::Isolation::Lease]
          # @return [String]
          def reminder(lease) = @sources.fetch(lease).reminder(lease)

          # @param lease [Lain::Isolation::Lease]
          # @param discard [Boolean] as on {Lain::Isolation::Spike#release}
          # @return [String]
          def release(lease, discard: false) = @sources.delete(lease).release(lease, discard:)

          private

          def source
            nearest = Lain::Project::Repository.nearest(@project.root, paths: @paths, home: @paths.home_or_nil)
            return Lain::Isolation::Scratch.new unless nearest.found?

            Lain::Isolation::Spike.new(repo_root: nearest.path, cwd: @project.cwd,
                                       root: IsolationBackend.worktree_root(nearest.path, paths: @paths))
          end
        end

        # The workspace sandbox counts only where the toolset built it: a box
        # lacking a layer runs bash unconfined whatever the arm says.
        #
        # @param arms [Lain::CLI::Arms] the bench arms the run was started with
        # @param masks [#on?] what {ToolsetBuild#board_inputs} says of the sandbox it built
        # @param child_env [Lain::Exec::ChildEnv] what a bash child inherits and is lent
        # @return [#call] `(remembered, factory) -> rules`, {.approving} as those arms build it
        def approving_under(arms, masks, child_env)
          classes = arms.classes?
          workspace = arms.workspace? && masks.on?
          ->(remembered, each) { approving(remembered, each, classes:, workspace:, child_env:) }
        end

        # The deterministic rung's chain: this root's remembered answers, and
        # then the rules that can approve a parsed term with no human.
        #
        # APPENDED, and the order is the precedence. {Approval::Ladder}
        # settles on the first rule with an opinion, so a human's remembered
        # `deny` still outranks anything the allowlist would have approved. Prepending would silently overturn an
        # answer a person gave.
        #
        # The chain is the trusted config's; this adds to it and does not own
        # it, which is why the remembered rules are threaded through rather than
        # rebuilt here. The board is handed this method rather than its answer,
        # because a leased worker's chain is composed again over that worker's
        # own factory.
        #
        # @param remembered [Array<Lain::Approval::Rule>] call shapes `.lain/config.rb` pre-approves, kept
        #   ahead of the composed term
        # @param factory [#call, #confinement, #content, #executables] the `cwd -> #classify` factory,
        #   on {Lain::Approval::ComposedTerm}'s terms
        # @param classes [Boolean] whether the composed term rules by the resolved class
        # @param workspace [Boolean] whether the workspace sandbox holds an automatic allow, the one place a
        #   commit's hooks, which run files the chat may have edited, are bounded; only then may a lease commit
        #   be approved by rule
        # @param child_env [Lain::Exec::ChildEnv] what a bash child inherits and is lent, which the lease commit
        #   rule judges git's env by
        # @return [Array<Lain::Approval::Rule>]
        def approving(remembered, factory, classes: false, workspace: false, child_env: Lain::Exec::ChildEnv::DEFAULT)
          [*remembered, *(Lain::Approval::LeaseCommit.new(sensitivity: factory, child_env:) if workspace),
           Lain::Approval::ComposedTerm.new(sensitivity: factory, classes:)].freeze
        end

        # The session's ONE {Lain::Shell::Verdict}, over the programs this
        # project has ruled out. Built here because this is where a project's
        # config becomes an authority, and handed BACK rather than kept: the
        # bash tool and the approval ladder's triage rung must hold the same
        # instance, and {Wiring} is the only object above both.
        #
        # `capability_set` is the third safety mechanism in this codebase that
        # was written, spec'd and never wired -- {Shell::Verdict::AnyProgram}
        # permits every program, and nothing in lib/ ever built another. This
        # method is what makes a `deny` reachable in a real session.
        #
        # A config that will not load refuses the launch, and so does a
        # malformed `shell` table: the table RESTRICTS, so dropping it fails
        # OPEN, and a session quietly running without a project's refusals is
        # the worst outcome available.
        #
        # A word-leading tilde expands to the HOME every bash child is lent:
        # {Wiring#chat_env} is the same snapshot, and {Lain::Exec::ChildEnv}
        # keeps it by name. Never `Dir.home`, whose passwd fallback would hand
        # a child with no HOME a home it does not have.
        #
        # @param project [Lain::Project]
        # @param paths [Paths] the state home the project's trust is read under
        # @param home [String, nil] the HOME the session's bash children run with
        # @return [Lain::Shell::Verdict]
        # @raise [Lain::Config::Refusal] when the file or the table is malformed
        def shell_verdict(project:, paths:, home: Lain::WorkerEnv.default.env["HOME"])
          Lain::Shell::Verdict.new(capability_set: Config.shell_exclusions(root: project.root, paths:), home:)
        end

        # The session's ONE layout guard, which the parent's tool phase and
        # every child's share.
        #
        # No `framework:` is passed, because enforcement is opt-in: a detected
        # preset would hold a project that declared nothing to level roots it
        # never chose, and refuse its existing flat specs as strays.
        #
        # @param project [Lain::Project]
        # @param paths [Paths] the state home the project's trust is read under
        # @param file_facts [Lain::FileFacts::Live, Lain::FileFacts::Recorded] what the run resolves a root through
        # @return [Lain::Middleware::GuardTestLayout::Run]
        # @raise [Lain::Config::Refusal] when the file or the table is malformed
        def test_layout(project:, paths:, file_facts: Lain::FileFacts::LIVE)
          layout_run(Config.test_layout(root: project.root, paths:), project, file_facts)
        end

        def layout_run(layout, project, file_facts)
          Lain::Middleware::GuardTestLayout::Run.new(layout:, root: project.root, file_facts:)
        end

        # The history is primed here, once, and the source carries it to the masker and the egress guard.
        #
        # @param project [Lain::Project]
        # @param sensitivity [Lain::Sensitivity::Policy] what the history walk reads the sensitive paths from
        # @param child_env [Lain::Exec::ChildEnv]
        # @param journal [#<<] where a credentials file that adds no known value says why
        # @return [Lain::Sensitivity::Secrets::Source]
        def secrets(project:, sensitivity:, child_env:, journal: Lain::Channel::Null.instance)
          history = Lain::Sensitivity::HistoryLiterals.new(root: project.root, policy: sensitivity,
                                                           report: credentials_report(journal)).prime
          Lain::Sensitivity::Secrets::Source.new(child_env:, history:)
        end

        def credentials_report(journal)
          lambda do |reason|
            journal << Lain::Telemetry::CapabilityDegraded.new(capability: :rails_credentials,
                                                               requirer: Lain::Sensitivity::RailsCredentials.name,
                                                               provider: reason)
          end
        end
        private_class_method :credentials_report

        # The run's path boundary, wrapped in the policy both gates read
        # through -- {Middleware::Sensitivity} for what may not be touched
        # at all, {Middleware::Gate} for what is merely worth asking about.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param table [Lain::Sensitivity::Rules] the compiled `sensitivity`
        #   table. REQUIRED, and it is {.for} that compiles it: three readers
        #   need the same one.
        # @param read_roots [Array<String>] absolute; see {.read_roots}
        # @param epic_home [String, nil] see {.epic_home}
        # @return [Lain::Sensitivity::Policy]
        def policy(project:, paths:, table:, read_roots: [], epic_home: nil)
          Lain::Sensitivity::Policy.new(sensitivity: classifier(project:, paths:, table:), home: paths.home,
                                        root: project.root, read_roots:, epic_home:)
        end

        # {Lain::Sensitivity} takes no `Dir.pwd` default: a relative path
        # resolved against whatever directory the process happens to sit in is
        # exactly the divergence the resolved {Lain::Project} exists to remove.
        # The cwd is the PROJECT's, the same one {Wiring#chat_env} sends the
        # tools.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param table [Lain::Sensitivity::Rules] as on {.policy}
        # @return [Lain::Sensitivity]
        def classifier(project:, paths:, table:)
          Lain::Sensitivity.new(home: paths.home, cwd: project.cwd, rules: table, root: project.root,
                                records: records(paths))
        end

        # A record or the user's config that lain cannot resolve, so its real
        # path cannot be gated. Refused at launch rather than left ungated.
        class UnreadableRecords < Lain::Error
          def initialize(path, reason)
            super("cannot resolve #{path}, so lain cannot gate where it really is: #{reason}")
          end
        end

        # Resolved here, where IO is allowed, since the classifier makes no
        # syscall: a symlinked state or config home is gated under its real path too.
        #
        # @param paths [Paths]
        # @return [Lain::Sensitivity::Records]
        # @raise [UnreadableRecords] when a record's real path cannot be resolved
        def records(paths)
          Lain::Sensitivity::Records.of(paths, states: real_containers(paths), files: [landing(paths.user_config)])
        end

        # Where each record lands, for a lain folder or a container that is itself a link.
        def real_containers(paths)
          Lain::Sensitivity::OWN_RECORDS.map do |kind|
            landing(paths.container(kind, key: Lain::Sensitivity::Records::EVERY_KEY))
          end
        end

        # Its deepest existing ancestor resolved, with the missing tail kept, so a
        # container lain creates later is gated where it will land.
        def landing(path)
          Lain::Landing.eventual(path, cwd: File::SEPARATOR).first
        rescue SystemCallError => e
          raise UnreadableRecords.new(path, Lain::Error.reason_of(e))
        rescue Lain::Landing::Dangling => e
          raise UnreadableRecords.new(path, e.message)
        end
        private_class_method :real_containers, :landing

        # A THIRD reader of the same table, and the one the approval ladder
        # gets: a factory rather than a classifier, because a bash call names
        # its own working directory and the rung has to anchor the argv it
        # reads on THAT one. {.classifier} above answers about a path a tool
        # already resolved; this answers about a word the model wrote.
        #
        # @param project [Lain::Project] supplies the cwd a relative one resolves
        #   against -- the session's, exactly as {Wiring#chat_env} sends the tools
        #   -- and the root the table's patterns are anchored on and an approved
        #   word must stay under
        # @param paths [Paths]
        # @param table [Lain::Sensitivity::Rules] as on {.policy}
        # @param facts [Lain::FileFacts::Live, Lain::FileFacts::Recorded] what the confinement resolves through
        # @param reads [Array<String>] absolute; the session's read roots, which an approved word may also name
        # @param identity [Hash] as on {.for}
        # @return [Classifiers]
        def classifiers(project:, paths:, table:, facts: Lain::FileFacts::LIVE, reads: [], **identity)
          Classifiers.new(home: paths.home, cwd: project.cwd, rules: table, root: project.root, paths:,
                          confinement: confinement(project:, paths:), facts:, reads:, **identity)
        end

        # The boundary an automatic approval reads inside. A root holding the
        # home directory is no boundary, since everything its user owns lies
        # under it -- whether the root IS home or sits above it -- and a root
        # nothing detected is only wherever the process started. Each confines
        # NOTHING, and nothing is approved without a human.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @return [Lain::Approval::Root, Lain::Approval::Root::Nowhere]
        def confinement(project:, paths:)
          return Lain::Approval::Root::NOWHERE if unconfined?(project, paths)

          Lain::Approval::Root.new(project.root)
        end

        # `kind` is the resolver's answer over home's real spellings; containment
        # covers a root above home and a HOME written with a trailing slash.
        def unconfined?(project, paths)
          project.detected_by == :none || project.kind == :home ||
            Lain::Approval::Root.new(project.root).contains?(paths.home)
        end

        # A config that will not load refuses the launch, and so does a
        # malformed `sensitivity` table. This table RESTRICTS, so dropping it
        # fails OPEN, and a session quietly running with a project's denials
        # un-parsed is the worst outcome available.
        #
        # An exemption naming a directory is refused here too, where the root
        # is on disk to ask: the table itself makes no syscall.
        #
        # @param project [Lain::Project]
        # @param paths [Paths] supplies the HOME a `related` entry expands against
        # @return [Lain::Sensitivity::Rules]
        # @raise [Lain::Config::Refusal] when the file or the table is malformed
        def rules(project:, paths:)
          root = project.root
          config = ProjectDir.new(root:, paths:).config
          not_a_directory = ->(dir) { File.exist?(dir) && !File.directory?(dir) }
          Config.sensitivity(root:, paths:)
                .exempting_files!(->(anchored) { File.directory?(File.join(root, anchored)) }, path: config)
                .relating_directories!(not_a_directory, home: paths.home, path: config)
        end

        # The `cwd -> #classify` factory {Approval::Escalation::Triage} takes,
        # and the object that finally makes its argv check fire: until this was
        # wired, `cat ~/.ssh/id_rsa` reached a human as an ORDINARY approval.
        #
        # One classifier per gated call, anchored on the cwd THAT call named,
        # resolved the way {Lain::WorkerEnv#resolve} resolves it before the
        # command runs, so the rung and {Tools::Bash} cannot disagree about
        # where a relative word lands. A classifier built once at wiring time
        # would anchor every call under whatever directory the agent started
        # in, and could then refuse a project file for a name it happens to
        # share with a browser profile.
        #
        # == TOTAL over the MODEL's half, loud about the WIRING's
        #
        # `cwd` is MODEL-CONTROLLED and `Sensitivity.new` refuses one that is
        # not absolute, so `#call` may never raise: a raise is an
        # {Escalation::RUNG_BROKE} fault, a fault turns the rung's deny into the
        # abstention it exists to replace, and a human -- whose allow is honoured
        # over a fault, by design -- then approves the read. `cwd: "bad\0dir"`
        # would be a one-field disarm of the deny.
        #
        # {Triage::AnyPath} is NOT the fallback, and that was measured: it
        # protects nothing, so it is the same disarm without the fault -- eight
        # hostile `cwd` values, every one of them JSON a model can emit, each
        # turning `cat ~/.ssh/id_rsa` back into an ordinary approval. It is also
        # over-broad, because the call's cwd contributes NOTHING to classifying
        # an ABSOLUTE path. So `#call` falls back to the SESSION's own
        # classifier -- anchored on `home` and the project cwd, both from the
        # wiring -- which is just as total and costs the model the bypass; only
        # the relative-word anchoring is lost.
        #
        # That session classifier is therefore built EAGERLY, and a `home` or
        # `cwd` it cannot anchor on RAISES here. Both come from the wiring, so a
        # bad one is a startup bug and belongs at startup: built lazily it made
        # the rung inert for a whole session in silence, and the only thing
        # making it loud was that {.for} happens to evaluate `sensitivity:`
        # before `classifiers:`. A security boundary must not rest on Ruby's
        # keyword evaluation order.
        #
        # The `WorkerEnv` is hoisted for the same reason -- `@cwd` is the
        # wiring's, so its construction cannot fail on model input, and building
        # one per gated call meant a `Ractor.make_shareable` walk to reach one
        # pure function. Only `#resolve`, the part that touches the model's
        # string, stays inside the rescue.
        #
        # == The root answer fails the OTHER way, and reads the disk
        #
        # {#confinement} resolves the same cwd for the rule that approves, and
        # there the session fallback would be fail-OPEN: the session's cwd is
        # under the root by construction, so an unresolvable call would be
        # placed inside the project. It confines nothing instead.
        #
        # It and {#content} are the one place in this boundary that asks the
        # filesystem. The classifier stays lexical by contract, but the approver
        # authorizes an exec that follows every symlink the path crosses -- a
        # link a clone can ship -- and prints whatever the file holds, so a word
        # must land under the root both as written and as the kernel will
        # resolve it, and its bytes must be ones a masked read would have sent.
        # Both can only REMOVE an approval.
        class Classifiers
          # A cwd-anchored question about the root, answered twice: lexically
          # from the directory the call named, and again where that path really
          # lands, under the root's own real path. Either answer failing, or
          # failing to resolve, is a no.
          class Confinement
            # Where the directory the command will run in itself lands.
            # {Classifiers#confinement} resolves it to answer the root question,
            # so this says the answer rather than making a caller ask again: a
            # rule that classifies one word at a time would otherwise resolve
            # the same cwd once per word, for the same value every time.
            #
            # @return [String]
            attr_reader :real_landing

            # @param root [#contains?] the root as the session spells it
            # @param cwd [String] the call's cwd, lexically resolved
            # @param landing [String] the directory the command will really run in:
            #   the call's cwd as {Lain::WorkerEnv#resolve} cleans it, the base a
            #   word's uncleaned path is joined to
            # @param real_root [#contains?] the root's own real path
            # @param real_landing [String] where `landing` lands, defaulting to
            #   the unresolved spelling for a confinement that contains nothing
            #   and will never be asked
            # @param facts [Lain::FileFacts::Live, Lain::FileFacts::Recorded] what a word is resolved through
            # @param reads [Array<Array(#contains?, #contains?)>] each read root
            #   as the session spells it and as its real path, which a word may
            #   name as it names the root
            def initialize(root, cwd, landing: cwd, real_root: root, real_landing: landing,
                           facts: Lain::FileFacts::LIVE, reads: [])
              @root = root
              @cwd = cwd.dup.freeze
              @landing = landing.dup.freeze
              @real_root = real_root
              @real_landing = real_landing.dup.freeze
              @facts = facts
              @reads = reads.freeze
              freeze
            end

            def contains?(path)
              [[@root, @real_root], *@reads].any? do |lexical, real|
                lexical.contains?(path, from: @cwd) && really?(real, path)
              end
            end

            # @param path [String] a word as the call wrote it
            # @return [String] the path the kernel will open for it
            # @raise [SystemCallError, ArgumentError] when no prefix resolves
            def landing_of(path) = Lain::Landing.of(path, cwd: @landing, facts: @facts).first

            private

            def really?(real, path)
              real.contains?(landing_of(path))
            rescue StandardError
              false
            end
          end

          # What a word's file holds, asked of the file itself. The classifier
          # judges a NAME, so a key under an ordinary one -- `deploy_key`, a
          # hardlink, a block pasted into notes -- reads as ordinary, and the
          # program the approver lets run prints it.
          #
          # A regular file is admitted only when its owner left it readable by
          # everyone, which the tools that write a credential decline to do, and
          # when its bytes carry no region `read_file` would have masked. What
          # its name says is the classifier's question, asked before this one. A word
          # naming nothing on disk, or a directory, has no bytes to ask about.
          # Only a word the confinement contains is ever opened, so no file
          # outside the root is read to answer, and anything else that exists --
          # a FIFO, a socket, a device -- is refused unopened, since opening or
          # reading one can block the ladder.
          class Content
            # Paid on every judged call, so bounded -- and a file larger than
            # this is refused rather than half-read: `tail` prints exactly the
            # bytes a prefix scan never saw, and what was not read is not vouched
            # for.
            SCAN_BOUND = 64 * 1024
            WORLD_READABLE = 0o004

            # The landing is already resolved, so a link at the open is a swap;
            # non-blocking, so a FIFO swapped in cannot hold the open.
            OPEN_FLAGS = File::RDONLY | File::NONBLOCK | File::NOFOLLOW

            # @param confinement [Confinement] the same call's root answer
            def initialize(confinement)
              @confinement = confinement
              freeze
            end

            def admits?(word) = @confinement.contains?(word) && releasable?(word)

            private

            def releasable?(word)
              path = @confinement.landing_of(word)
              return true if !File.exist?(path) || File.directory?(path)

              File.file?(path) && File.open(path, OPEN_FLAGS) { |file| unsealed?(file) }
            rescue StandardError
              false
            end

            # The descriptor is asked again, because the path can be swapped
            # between the check above and the open. One byte past the bound is
            # read rather than the size trusted, so a file growing after the stat
            # is still refused.
            def unsealed?(file)
              stat = file.stat
              return false unless stat.file? && stat.mode.anybits?(WORLD_READABLE)

              bytes = file.read(SCAN_BOUND + 1).to_s
              bytes.bytesize <= SCAN_BOUND && Lain::Sensitivity::Regions.detect(bytes).empty?
            end
          end

          # One classifier per root a `/`-anchored pattern is read from, asked
          # together: a path any of them denies is denied, and one any of them
          # gates is gated. An exempted word ranks above a plain one, because
          # the approving rule refuses what an exemption names.
          class Strictest
            # @param classifiers [Array<#classify>] at least one
            # @return [#classify] the only classifier when there is one
            def self.of(classifiers) = classifiers.one? ? classifiers.first : new(classifiers)

            def initialize(classifiers)
              @classifiers = classifiers.freeze
              freeze
            end

            # @param path [String, Pathname] as on {Lain::Sensitivity#classify}
            # @return [Lain::Sensitivity::Verdict]
            def classify(path) = @classifiers.map { |classifier| classifier.classify(path) }.inject(:|)

            def denied?(path) = classify(path).denied?
            def gated?(path) = classify(path).gated?
          end

          # @param home [String] the HOME the home-anchored rules resolve against
          # @param cwd [String] the session's working directory, which a
          #   call's own relative `cwd` resolves against
          # @param rules [Lain::Sensitivity::Rules] the compiled `sensitivity` table
          # @param root [String, nil] the project root its `/`-anchored patterns
          #   are read from, on {Lain::Sensitivity}'s terms. Apart from
          #   `confinement` because a root that confines nothing still anchors a
          #   denial.
          # @param also_rooted [Array<String>] further roots the same patterns
          #   are read from, each denying and gating as `root` does
          # @param confinement [#contains?] the root an approved word must stay
          #   under; confining nothing by default, so a factory built without
          #   one can never be what approves
          # @param resolver [#for] the session's resolver; by default every
          #   stage is unresolved, so a factory built without one cannot vouch
          # @param worker_env [Lain::WorkerEnv] the env the worker's commands
          #   run under, whose PATH {#executables} resolves through; its cwd is
          #   replaced by `cwd`, so the two cannot disagree
          # @param facts [Lain::FileFacts::Live, Lain::FileFacts::Recorded] what the
          #   confinement resolves the root and the cwd through
          # @param reads [Array<String>] absolute; the session's read roots, which
          #   an approved word may name as it names the root, though the call's
          #   cwd must still lie under the root
          # @param paths [Lain::Paths, nil] where lain keeps its own config and
          #   records, gated wherever the session's XDG homes put them; nil
          #   reads the defaults under `home`
          # @param records [Lain::Sensitivity::Records, nil] those rules already
          #   compiled, which a leased factory reuses rather than rebuilds
          # @raise [ArgumentError] from {Lain::Sensitivity}, when `home`, `cwd`
          #   or a root is not something a classifier can be anchored on
          def initialize(home:, cwd:, rules: Lain::Sensitivity::Rules.empty, root: nil, also_rooted: [],
                         confinement: Lain::Approval::Root::NOWHERE,
                         resolver: Lain::Shell::Executable::Resolver::NULL,
                         worker_env: Lain::WorkerEnv.new(cwd:, env: {}), facts: Lain::FileFacts::LIVE, reads: [],
                         paths: nil, records: paths && BoardBuild.records(paths))
            @home = home
            @records = records
            @facts = facts
            @reads = reads.map { Lain::Approval::Root.new(_1) }.freeze
            @rules = rules
            @roots = [root, *also_rooted].uniq.freeze
            @confinement = confinement
            @worker_env = worker_env.with(cwd:)
            @resolver = resolver
            @session = classifier(cwd)
            @nowhere = Confinement.new(Lain::Approval::Root::NOWHERE, @worker_env.cwd)
            freeze
          end

          # @param cwd [String, nil] as the CALL wrote it -- relative, absolute,
          #   nil when it named none, and anything else JSON permits
          # @return [#classify] never nil, and never raising
          def call(cwd)
            classifier(@worker_env.resolve(cwd))
          rescue StandardError
            @session
          end

          # The call's own cwd must itself lie under the root, lexically and
          # really, or nothing does: every word the call names resolves from
          # there. It is asked of the root BEFORE {Lain::WorkerEnv#resolve}
          # sees it, because the root refuses a leading `~` lexically where
          # `resolve` would hand it to getpwnam.
          #
          # @param cwd [String, nil] as on {#call}
          # @return [Confinement] never nil, and never raising
          def confinement(cwd)
            return @nowhere unless @confinement.contains?(cwd || @worker_env.cwd, from: @worker_env.cwd)

            # The cwd is judged CLEANED, unlike a word: the command is spawned in
            # exactly this string, so `inner/../h` runs in `h` whatever `inner`
            # links to, while a word's `..` is resolved by the kernel from there.
            landing = @worker_env.resolve(cwd)
            real_root = Lain::Approval::Root.new(@facts.realpath(@confinement))
            # The one resolution of the cwd, asked here and CARRIED: the root
            # question needs it, and so does every word a rule classifies
            # afterwards.
            real_landing = Lain::Landing.of(landing, cwd: landing, facts: @facts).first
            return @nowhere unless real_root.contains?(real_landing)

            Confinement.new(@confinement, landing, landing:, real_root:, real_landing:, facts: @facts,
                                                   reads: real_reads)
          rescue StandardError
            @nowhere
          end

          # Built over {#confinement} for the same cwd, so the file whose bytes
          # are asked about is the one the root answer placed, and a call that
          # confines nothing admits nothing.
          #
          # @param cwd [String, nil] as on {#call}
          # @return [Content] never nil, and never raising
          def content(cwd) = Content.new(confinement(cwd))

          # Classed where the command will run, as {#executables} classes a stage's run files.
          #
          # @param path [String] absolute
          # @param cwd [String, nil] as on {#call}
          # @return [Lain::Shell::Executable::RunFiles::Entry]
          # @raise [ArgumentError] when the cwd cannot be resolved
          def run_file(path, cwd) = @resolver.for(@worker_env.with(cwd: @worker_env.resolve(cwd))).run_file(path)

          # Read before the child env withholds anything, so a name it would
          # withhold still counts against an approval.
          #
          # @return [Hash{String=>String, nil}] what the worker's commands are lent
          def environment = @worker_env.env

          # Bound where the command will run, as the bash tool binds it.
          #
          # @param term [Lain::Shell::Term]
          # @param cwd [String, nil] as on {#call}
          # @return [Array<Lain::Shell::Executable>] one per stage, resolved
          #   through this worker's PATH
          # @raise [ArgumentError] when the cwd cannot be resolved
          def executables(term, cwd)
            @resolver.for(@worker_env.with(cwd: @worker_env.resolve(cwd))).call(term)
          end

          # The factory a worker's commands are judged by. A worker a lease cut a
          # checkout for runs them in that checkout, which sits outside the
          # project root, so judged over this factory every word it names would
          # land in a project the command never touches: a link to a key there
          # reads as a file that does not exist. Its factory resolves a call's
          # cwd from the worker's own, resolves its programs through the
          # worker's own PATH, and confines an approved word to the checkout.
          #
          # What it protects is widened, never moved: the checkout carries a
          # copy of the tracked tree and the project's own is one absolute word
          # away, so an anchored pattern denies and gates under every root this
          # factory already read it from as well as under the checkout.
          #
          # @param worker_env [Lain::WorkerEnv] the environment the worker runs in
          # @return [Classifiers] this one when no lease cut a checkout
          # @raise [ArgumentError] when the checkout cannot anchor a classifier
          def for(worker_env)
            checkout = worker_env.checkout
            return self if checkout.nil?

            Classifiers.new(home: @home, cwd: worker_env.cwd, rules: @rules, root: checkout, records: @records,
                            also_rooted: @roots.compact, confinement: leased_confinement(checkout),
                            resolver: @resolver, worker_env:, reads: @reads.map(&:to_path))
          end

          private

          # A read root that does not resolve is left out, so no word lands in it.
          def real_reads
            @reads.filter_map do |read|
              [read, Lain::Approval::Root.new(@facts.realpath(read))]
            rescue StandardError
              nil
            end
          end

          def classifier(cwd)
            Strictest.of(@roots.map do |root|
              Lain::Sensitivity.new(home: @home, cwd:, rules: @rules, root:, records: @records)
            end)
          end

          # A factory confining nothing -- a home root, a root nothing detected --
          # gives its workers nothing to be confined to, and a checkout holding
          # the home directory is no boundary, for {BoardBuild.confinement}'s
          # reason.
          def leased_confinement(checkout)
            root = Lain::Approval::Root.new(checkout)
            return Lain::Approval::Root::NOWHERE if @confinement.equal?(Lain::Approval::Root::NOWHERE)

            root.contains?(@home) ? Lain::Approval::Root::NOWHERE : root
          end
        end
      end
    end
  end
end
