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
        # @option options [Boolean] :yolo start approving everything, with no
        #   queue -- read by {Switchboard.for}, never here
        # @return [Switchboard]
        def for(chronicle:, options:, model:, toolset:, project:, notice: nil, paths: Paths.new)
          Switchboard.for(chronicle:, options:, model:, toolset:,
                          rules: Project::Consent.for(project:, notice:).rules,
                          sensitivity: policy(project:, paths:, notice:))
        end

        # The run's path boundary, wrapped in the policy both gates read through
        # -- {Effect::Handler::Sensitivity} for what may not be touched at all,
        # {Effect::Handler::Gate} for what is merely worth asking about.
        #
        # T23: until this existed nothing anywhere called {Lain::Sensitivity.new}
        # and nothing called {Lain::Sensitivity::Rules.from}, so every real chat
        # ran on {Lain::Sensitivity::Policy::Null} -- `gates?` false for every
        # path there is -- and the `[sensitivity]` table was parsed by nobody.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param notice [#call, nil] told when the config file could not be read
        # @return [Lain::Sensitivity::Policy]
        def policy(project:, paths:, notice: nil)
          Lain::Sensitivity::Policy.new(sensitivity: classifier(project:, paths:, notice:))
        end

        # `home:` and `cwd:` are supplied because {Lain::Sensitivity} requires
        # them and takes no `Dir.pwd` default: a relative path resolved against
        # whatever directory the process happens to sit in is exactly the
        # divergence the resolved {Lain::Project} exists to remove. The cwd is
        # the PROJECT's, the same one {Wiring#chat_env} sends the tools.
        #
        # @param project [Lain::Project]
        # @param paths [Paths]
        # @param notice [#call, nil] told when the config file could not be read
        # @return [Lain::Sensitivity]
        def classifier(project:, paths:, notice: nil)
          Lain::Sensitivity.new(home: paths.home, cwd: project.cwd, rules: rules(project:, notice:))
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
      end
    end
  end
end
