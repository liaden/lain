# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What the run's {Switchboard} is BUILT FROM, lifted out of {Wiring} the
      # way {AgentBuild} and {ToolsetBuild} were, and for the reason that class's
      # own comment gives: it sat exactly at its {Metrics/ClassLength} ceiling,
      # so the rule is extract, never loosen.
      #
      # There is a real responsibility here and not merely moved lines: BOTH
      # halves turn the resolved {Lain::Project} into an authority the board
      # holds, and neither is the board's own question. {Project::Consent} says
      # which remembered answers this root may contribute; the path boundary
      # below says which paths it gates and which it refuses outright.
      #
      # == They are two vocabularies, and the resemblance is a trap
      #
      # Consent's `rules` are APPROVAL rules -- call SHAPES a consented root
      # pre-approves, which GRANT. The `[sensitivity]` table's rules are PATH
      # rules, which restrict and grant nothing. Both arrive at {Switchboard.for}
      # as keywords, `rules:` and `sensitivity:`, and one silently accepted where
      # the other belongs would be a config file's denials read as permissions.
      # They are assembled in one place precisely so a reader sees both names at
      # once rather than meeting them a hundred lines apart.
      module BoardBuild
        # The startup-notice seam's null, matching {CLI::EpicMount::SILENT} and
        # {Project::Consent::SILENT}.
        SILENT = ->(_message) {}

        # Said when the config file cannot be parsed at all, so the project's
        # own additions are lost. It names what is still standing, because
        # "not in force" alone reads as "you have no boundary" -- and the
        # built-in credential rules never lived in that file.
        UNREADABLE = "this project's [sensitivity] rules are not in force (the built-in credential rules still " \
                     "apply): %<reason>s"

        module_function

        # @param chronicle [CLI::Chronicle] resolves the journal the switches record onto
        # @param options [Hash] the CLI's parsed surface flags
        # @param model [String] the model in force until the first /model
        # @param toolset [Lain::Toolset] the run's BASE capability set
        # @param project [Lain::Project] the run's resolved root and cwd
        # @param notice [#call, nil] the startup-notice seam an ignored
        #   `[approval]` table reports through
        # @param paths [Paths] supplies the HOME the classifier anchors its
        #   home-relative rules against
        # @option options [Boolean] :non_interactive no human is at this
        #   session's terminal -- read by {Switchboard.for}, never here
        # @return [Switchboard]
        def for(chronicle:, options:, model:, toolset:, project:, notice: nil, paths: Paths.new)
          # Compiled ONCE and handed to both readers. {.rules} parses the config
          # file and, when it cannot, SAYS so through `notice` -- so calling it
          # a second time for the triage factory would parse the same file twice
          # and tell the operator the same thing twice for one broken config.
          table = rules(project:, notice:)
          Switchboard.for(chronicle:, options:, model:, toolset:,
                          rules: Project::Consent.for(project:, notice:).rules,
                          sensitivity: policy(project:, paths:, table:),
                          classifiers: classifiers(project:, paths:, table:))
        end

        # The run's path boundary, wrapped in the policy both gates read through
        # -- {Effect::Handler::Sensitivity} for what may not be touched at all,
        # {Effect::Handler::Gate} for what is merely worth asking about.
        #
        # Until this existed nothing anywhere called {Lain::Sensitivity.new}
        # and nothing called {Lain::Sensitivity::Rules.from}, so every real chat
        # ran on {Lain::Sensitivity::Policy::Null} -- `gates?` false for every
        # path there is -- and the `[sensitivity]` table was parsed by nobody.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param table [Lain::Sensitivity::Rules] the compiled `[sensitivity]`
        #   table. REQUIRED, and it is {.for} that compiles it: three readers
        #   need the same table, and {.rules} both parses the file and reports
        #   an unreadable one, so a second call here would parse twice and say
        #   the same thing to the operator twice.
        # @return [Lain::Sensitivity::Policy]
        def policy(project:, paths:, table:)
          Lain::Sensitivity::Policy.new(sensitivity: classifier(project:, paths:, table:))
        end

        # `home:` and `cwd:` are supplied because {Lain::Sensitivity} requires
        # them and takes no `Dir.pwd` default: a relative path resolved against
        # whatever directory the process happens to sit in is exactly the
        # divergence the resolved {Lain::Project} exists to remove. The cwd is
        # the PROJECT's, the same one {Wiring#chat_env} sends the tools.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param table [Lain::Sensitivity::Rules] as on {.policy}
        # @return [Lain::Sensitivity]
        def classifier(project:, paths:, table:)
          Lain::Sensitivity.new(home: paths.home, cwd: project.cwd, rules: table)
        end

        # A THIRD reader of the same table, and the one the approval ladder gets:
        # a factory rather than a classifier, because a bash call names its own
        # working directory and the rung has to anchor the argv it reads on THAT
        # one. {.classifier} above answers the read boundary's question, which is
        # about a path a tool already resolved; this answers the triage rung's,
        # which is about a word the model wrote.
        #
        # @param project [Lain::Project] supplies the cwd a relative one resolves
        #   against -- the session's, exactly as {Wiring#chat_env} sends the tools
        # @param paths [Paths]
        # @param table [Lain::Sensitivity::Rules] as on {.policy}
        # @return [Classifiers]
        def classifiers(project:, paths:, table:)
          Classifiers.new(home: paths.home, cwd: project.cwd, rules: table)
        end

        # Two failures, two postures, and the line between them is what the
        # table SAYS versus whether the file can be read at all.
        #
        # A malformed `[sensitivity]` table RAISES, and is deliberately not
        # rescued the way {Project::Consent} rescues a broken `[approval]`
        # table. The asymmetry is that class's own, one axis over: its table
        # GRANTS, so dropping it fails closed and costs a rung. This one
        # RESTRICTS, so dropping it fails OPEN -- a session that quietly ran
        # with a project's denials un-parsed would be the worst outcome
        # available. {Config.sensitivity} kept the path, so the refusal names
        # the file.
        #
        # A file that will not PARSE is the other case, and it is rescued: the
        # typo is as likely in `[epics]` as here, nothing in it is this
        # boundary's to interpret, and taking `lain chat` down over an unrelated
        # syntax error is a regression a user meets mid-task. It costs the
        # project its ADDITIONS and nothing else -- the built-in credential
        # tables never lived in that file -- and it is SAID, because a boundary
        # narrowing in silence is the failure this whole card is about.
        #
        # @param project [Lain::Project]
        # @param notice [#call, nil]
        # @return [Lain::Sensitivity::Rules]
        def rules(project:, notice: nil)
          Config.sensitivity(root: project.root)
        rescue Config::Malformed => e
          (notice || SILENT).call(format(UNREADABLE, reason: e.message))
          Lain::Sensitivity::Rules.empty
        end

        # The `cwd -> #classify` factory {Approval::Escalation::Triage} takes,
        # and the object that finally makes its argv check fire: until this was
        # wired, `cat ~/.ssh/id_rsa` reached a human as an ORDINARY approval.
        #
        # One classifier per gated call, anchored on the cwd THAT call named --
        # resolved against the session's the way {Lain::WorkerEnv#resolve}
        # resolves it before the command runs, so the rung and {Tools::Bash}
        # cannot disagree about where a relative word lands. A classifier built
        # once at wiring time would anchor every call under whatever directory
        # the agent started in, and could then refuse a project file for a name
        # it happens to share with a browser profile.
        #
        # == TOTAL over the MODEL's half, loud about the WIRING's
        #
        # The split is the whole design, and getting it wrong disarms the rung
        # this class exists to arm.
        #
        # `cwd` is MODEL-CONTROLLED (`bash.rb:50`) and `Sensitivity.new` refuses
        # one that is not absolute, so `#call` may never raise: a raise is a
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
        # an ABSOLUTE path: throwing the classifier away over a bad cwd discards
        # the answer to a question the cwd was never part of. So `#call` falls
        # back to the SESSION's own classifier -- anchored on `home` and the
        # project cwd, both from the wiring -- which is just as total and costs
        # the model the bypass. Only the relative-word anchoring is lost, which
        # is the only thing the bad cwd could have informed.
        #
        # That session classifier is therefore built EAGERLY, and a `home` or
        # `cwd` it cannot anchor on RAISES here. Both come from the wiring, so a
        # bad one is a startup bug and belongs at startup: built lazily it made
        # the rung inert for a whole session in silence, and the only thing
        # making it loud was that {.for} happens to evaluate `sensitivity:`
        # before `classifiers:`. A security boundary must not rest on Ruby's
        # keyword evaluation order.
        #
        # The {WorkerEnv} is hoisted here for the same reason: `@cwd` is the
        # wiring's, so its construction cannot fail on model input, and building
        # one per gated call meant a `Ractor.make_shareable` walk to reach one
        # pure function. Only `#resolve` -- the part that touches the model's
        # string -- stays inside the rescue.
        class Classifiers
          # @param home [String] the HOME the home-anchored rules resolve against
          # @param cwd [String] the session's working directory, which a
          #   call's own relative `cwd` resolves against
          # @param rules [Lain::Sensitivity::Rules] the compiled `[sensitivity]` table
          # @raise [ArgumentError] from {Lain::Sensitivity}, when `home` or `cwd`
          #   is not something a classifier can be anchored on
          def initialize(home:, cwd:, rules: Lain::Sensitivity::Rules.empty)
            @home = home
            @rules = rules
            @worker_env = Lain::WorkerEnv.new(cwd:, env: {})
            @session = Lain::Sensitivity.new(home:, cwd:, rules:)
            freeze
          end

          # @param cwd [String, nil] as the CALL wrote it -- relative, absolute,
          #   nil when it named none, and anything else JSON permits
          # @return [#classify] never nil, and never raising
          def call(cwd)
            Lain::Sensitivity.new(home: @home, cwd: @worker_env.resolve(cwd), rules: @rules)
          rescue StandardError
            @session
          end
        end
      end
    end
  end
end
