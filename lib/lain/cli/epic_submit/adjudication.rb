# frozen_string_literal: true

module Lain
  module CLI
    class EpicSubmit
      # The adjudication pair: the role spawn an `adjudicated` gate sends its
      # evidence spike and its verdict through, and the brief that tells the
      # spike where to look. Out of chat there is no chat seam to borrow, so
      # this builds its own over the same backend flags a chat reads -- the
      # precedent is {CLI::Improve.from_options}.
      #
      # Built ONLY when some stage is configured `adjudicated`. Every other
      # policy spends no tokens, so a session that adjudicates nothing never
      # constructs a provider and never needs a key, while one that does is
      # refused for a missing key at wiring -- the same moment
      # {Approval::Gate::Policies.for_all} refuses everything else.
      #
      # Every constant is root-qualified: this sits inside {CLI}, whose own
      # classes shadow several top-level names.
      class Adjudication
        # A pair of nils is the "not wired" fact
        # {Approval::Gate::Policies::Deps} reads, so an `adjudicated` stage
        # handed it is refused by name rather than guessed at.
        Pair = Data.define(:role_spawn, :brief)
        NONE = Pair.new(role_spawn: nil, brief: nil)

        # `epic submit` exposes only the provider and the model, and every
        # model turn needs a ceiling.
        MAX_TOKENS = 4_096

        # @param config [#gate_policy_for]
        def self.wanted?(config)
          Lain::Epic::STAGES.any? do |stage|
            config.gate_policy_for(stage) == Lain::Approval::Gate::Policy::Adjudicated::NAME
          end
        end

        # @param config [#gate_policy_for] decides whether a pair is built at all
        # @param paths [Paths] resolves the epic home the brief points into
        # @param root [String] the project root, likewise
        # @param backend [#call] answers a {Backend}-shaped duck (`#provider`,
        #   `#context`, `#slots`), and is CALLED only when a stage is
        #   adjudicated -- which is what keeps the provider unbuilt otherwise
        # @param tool_middleware [#call] the guard the spawned children run
        #   behind, as the thunk {Tools::Subagent::Seam} carries. Required on
        #   every path, adjudicated or not: out of chat no guard reaches a child
        #   unless it is handed in here, and a default would be how one went
        #   without in silence.
        # @return [Pair]
        def self.pair(config:, paths:, root:, backend:, tool_middleware:)
          return NONE unless wanted?(config)

          built = backend.call
          spawner = new(provider: built.provider, context_factory: -> { built.context }, slots: built.slots,
                        tool_middleware:)
          Pair.new(role_spawn: spawner.role_spawn, brief: Brief.new(config:, paths:, root:))
        end

        # Read key by key, so a Thor options hash and a plain one both work.
        #
        # @param options [Hash] the invoked command's parsed flags
        # @option options [String] :provider the backend provider, when given
        # @option options [String] :model the model, when given
        # @option options [Integer] :max_tokens the per-turn ceiling; defaults to {MAX_TOKENS}
        # @return [Hash{Symbol=>Object}] what {Backend.new} reads
        def self.flags(options)
          { provider: options[:provider], model: options[:model],
            max_tokens: options[:max_tokens] || MAX_TOKENS }.compact
        end

        def initialize(provider:, context_factory:, slots:, tool_middleware:)
          @seam = Lain::Tools::Subagent::Seam.new(provider:, context_factory:, parent: Lain::Timeline.empty,
                                                  tool_middleware:)
          @slots = slots
        end

        # @return [Skill::RoleSpawn]
        def role_spawn = Lain::Skill::RoleSpawn.new(seam: @seam, toolset: union, slots: @slots)

        private

        # What both roles attenuate FROM: the researcher reads and searches,
        # the adjudicator only reads. {Toolset#only} refuses a role whose tools
        # the union lacks, so it holds every one either names.
        def union
          Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                             Lain::Tools::Grep.new, Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
        end

        # What the spike is told to read. The gate's artifact duck is `#digest`
        # and `#gate_question` and nothing more, so {Approval::Gate::Adjudicator}
        # deliberately maps no digest to a path; the submission knows its stage,
        # epic and issue, and this maps them onto the epic home.
        class Brief
          def initialize(config:, paths:, root:)
            @config = config
            @paths = paths
            @root = root
          end

          # @param artifact [Epic::Submission]
          # @return [String] the researcher's prompt
          def call(artifact)
            <<~PROMPT
              An approval gate is about to decide the #{artifact.stage} stage of epic #{artifact.slug.inspect}#{about(artifact)}.
              Gather the evidence it will be decided on. Do not judge it -- another reader decides.

              Read:
              #{sources(artifact).map { |source| "- #{source}" }.join("\n")}

              Report what the artifact establishes, what it leaves open, and anything in it that disagrees
              with the rest of the epic, citing the file for each finding.
            PROMPT
          end

          private

          def about(artifact) = artifact.issue_id ? " for issue #{artifact.issue_id}" : ""

          # An `else` that RAISES, for {Artifacts#submission}'s reason: a fifth
          # stage must not be briefed as somebody else's artifact.
          def sources(artifact)
            home = Lain::Epic::Home.resolve(config: @config, paths: @paths, root: @root, slug: artifact.slug)
            case artifact.stage
            when "research" then [home.research.path]
            when "epic_plan" then [home.epic.path, home.research.path]
            when "issue_plan" then issue_plan_sources(home, artifact.issue_id)
            when "implementation" then implementation_sources(home, artifact)
            else raise Lain::Epic::UnknownStage, "no brief for the #{artifact.stage} stage"
            end
          end

          def issue_plan_sources(home, id)
            [home.plan(id).path, "#{home.epic.path} (issue #{id}'s acceptance criteria)"]
          end

          def implementation_sources(home, artifact)
            ["the changeset #{artifact.changeset} in this project's git history",
             home.plan(artifact.issue_id).path]
          end
        end
      end
    end
  end
end
