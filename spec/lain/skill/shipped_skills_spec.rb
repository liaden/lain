# frozen_string_literal: true

require "tmpdir"

# Every skill Lain SHIPS, exercised against the REAL templates/skill tree (not a
# fixture), so this spec is the acceptance test that the shipped scaffolds
# genuinely load, render, and encode process. Loaded once from disk, composed in
# memory: the same session-fixed, pure render every other slot uses.
#
# "Every" is meant literally -- the roster below is derived from the catalog
# rather than listed, so this spec cannot fall behind the directory it guards.
RSpec.describe "shipped skills" do
  # The sentences that make the human's gate question show the review: its
  # id travels in epic_submit's `review` field, so deleting one turns a spec red.
  def quote_per_wave = "pass the review id epic_review returned for that wave as `review` on the `epic_submit` call"
  def quote_once = "pass the review id epic_review returned as `review` on the `epic_submit` call"

  # The roster is DERIVED from the shipped tree, never written down. The catalog
  # is a directory scan ({Skill::Catalog.read_dir}), so a hand-maintained list
  # can only lag it -- a newly shipped skill would be unpinned by exactly the
  # spec that exists to pin it, which is how `gherkin-tests` went unnoticed.
  # An empty tmpdir for `root:` so no project skill leaks into "as shipped".
  #
  # Methods, not constants in the example-group class, so re-loading the spec
  # never warns on a constant redefinition.
  def shipped_catalog = Dir.mktmpdir { |root| Lain::Skill::Catalog.load(root:) }

  def shipped_names = shipped_catalog.names

  # The epic tier, also derived: the assertions that are ABOUT the epic grammar
  # iterate this rather than the whole catalog. A fifth epic skill joins it by
  # being named like one, so it cannot ship unpinned either.
  def epic_names = shipped_names.grep(/epic/)

  # Epic-markdown examples embedded in a scaffold, as source strings.
  #
  # The convention these templates keep, and the reason this can be a regex: an
  # example that is claimed to PARSE is fenced with FOUR backticks tagged
  # `markdown`, so it can hold the three-backtick ```gherkin fence an issue
  # carries. A COUNTER-example -- a shape the grammar refuses -- is never fenced
  # that way, so nothing here asserts that a deliberate refusal parses.
  def epic_examples(scaffold)
    scaffold.scan(/^````markdown\r?\n(.*?)^````[ \t]*$/m).flatten
  end

  # A renderer over the REAL shipped skills. `root` is where the project's
  # `.lain/` overrides live; default it at an empty tmpdir so no stray user skill
  # or slot leaks into the "as shipped" assertions.
  def shipped_renderer(root:)
    Lain::Skill::Library.load(root:,
                              locals: { epic_home: "/state/lain/epics/test",
                                        gate_window: 900,
                                        provider_width: "runs 3 requests at once, so spawn " \
                                                        "at most 3 researchers at a time",
                                        researcher_limits: "60 iterations and a 16384-byte answer" }).renderer
  end

  def with_empty_project
    Dir.mktmpdir { |root| yield shipped_renderer(root:), root }
  end

  # Write a `.lain/slots/skill/<skill>/<hole>.md` override under +root+.
  def write_override(root, skill, hole, body)
    path = File.join(root, ".lain", "slots", "skill", skill, "#{hole}.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe "every shipped skill loads and renders" do
    # The derived roster is the guard, so this example is the floor under it:
    # a rename or a deletion still has to be loud somewhere.
    it "ships the process skills, qa, gherkin-tests, and the four epic-tier skills" do
      expect(shipped_names).to include(:"create-plan", :"execute-plan", :critique, :"gherkin-tests", :qa)
      expect(epic_names).to match_array(%i[research-epic plan-epic iterate-epic create-epic-issues])
    end

    it "renders each shipped skill to non-empty scaffold text" do
      with_empty_project do |renderer|
        shipped_names.each do |name|
          rendered = renderer.render(name)
          expect(rendered).to be_a(String)
          expect(rendered.strip).not_to be_empty
        end
      end
    end

    it "never mentions a plans/ path in any shipped skill" do
      with_empty_project do |renderer|
        mentioning = shipped_names.select { |name| renderer.render(name).include?("plans/") }

        expect(mentioning).to be_empty
      end
    end

    # "Lain ships this" and "a project may extend this" are different facts, and
    # conflating them is what made the roster un-derivable. `gherkin-tests`
    # correctly declares NO slots -- it is dispatched by Gherkin::TestGeneration
    # and was never meant to be user-extended -- so slot-emptiness cannot be a
    # whole-catalog assertion. What holds for EVERY skill is that each hole it
    # does promise resolves.
    it "resolves every hole every shipped skill promises" do
      Dir.mktmpdir do |root|
        renderer = shipped_renderer(root:)

        # A declared slot with no shipped default is a broken skill: render
        # raises UnknownSlot rather than splicing silence.
        Lain::Skill::Catalog.load(root:).all.each do |skill|
          expect { renderer.render(skill.name) }.not_to raise_error
        end
      end
    end

    it "has at least one extensible skill, so the slot machinery is genuinely exercised" do
      expect(shipped_catalog.all.select { |skill| skill.slots.any? }).not_to be_empty
    end

    # A shipped skill naming a model would pin this tree to one provider's
    # namespace: a run under another provider would meet
    # Tools::Subagent::ModelChoice::Unserved -- correctly, and uselessly -- on
    # every role-bound invocation. Naming a model is a project's business, and
    # `.lain/skills/<name>/` already overrides a shipped skill wholesale.
    it "declares no model in any shipped skill, so the tree stays provider-neutral" do
      named = shipped_catalog.all.reject { |skill| skill.model.empty? }

      expect(named.map(&:name)).to be_empty
    end
  end

  describe "gherkin-tests names each framework's red rule" do
    let(:scaffold) do
      rendered = nil
      with_empty_project { |renderer| rendered = renderer.render("gherkin-tests") }
      rendered
    end

    it "counts the subject's own uninitialized constant as red for rspec" do
      expect(scaffold).to match(/rspec.*`uninitialized constant`.*counts as red/mi)
    end

    it "limits the rspec rule to a subject file not written yet, with every error naming its constant" do
      expect(scaffold).to match(/rspec.*does not exist yet.*every\s+error\s+names/mi)
    end

    it "counts an undefined function, type or method in the target file as red for cargo" do
      expect(scaffold).to match(/cargo.*function, type or method.*counts as red.*inline.*subject file/mi)
    end

    it "says every other load or compile error is not red" do
      expect(scaffold).to match(/every other load or compile error is not red/i)
    end
  end

  describe "create-plan's scaffold drives a plan, not code" do
    it "instructs grounding-before-planning, Gherkin acceptance criteria, and writing where the conventions name" do
      with_empty_project do |renderer|
        scaffold = renderer.render("create-plan")

        expect(scaffold.downcase).to include("ground")
        expect(scaffold.downcase).to match(/before .*plan|ground.* first|ground.* before/)
        expect(scaffold).to match(/[Gg]herkin/)
        expect(scaffold).to match(/Write the plan (to|where) .*conventions/)
      end
    end

    it "ships no template that cites lain's own manifest or plan path" do
      tree = File.expand_path("../../../lib/lain/prompt/templates", __dir__)
      shipped = Dir.glob("**/*", base: tree).map { |f| File.join(tree, f) }.select { |f| File.file?(f) }

      expect(shipped).not_to be_empty
      shipped.each do |file|
        expect(File.read(file)).not_to match(%r{require manifest|planning/specs/|lib/lain/|ROADMAP\.md}), file
      end
    end

    it "references lain's real role-catalog names" do
      with_empty_project do |renderer|
        scaffold = renderer.render("create-plan")
        # A plan for parallel sub-agents must name the real roles the orchestrator
        # can spawn; a made-up role would fail loudly at Role::Catalog.fetch time.
        real_roles = Lain::Role::Catalog.names.map(&:to_s)
        named = real_roles.select { |role| scaffold.include?(role) }
        expect(named).not_to be_empty
        expect(scaffold).to include("test_engineer")
      end
    end

    it "names role delegation and describes run_skill accurately as a runtime continuation" do
      with_empty_project do |renderer|
        scaffold = renderer.render("create-plan")

        # Role delegation: both the inherit and fresh binding shapes.
        expect(scaffold).to include("@role/skill")
        expect(scaffold).to include("@role[/skill]")
        # run_skill is a TOOL the agent calls mid-run to get another skill's
        # rendered scaffold back as its next tool result -- NOT render-time
        # inlining (that mechanism is front-matter `includes:`). The scaffold
        # must describe the tool honestly, tying `run_skill` to a tool result,
        # and keep it distinct from the `includes:` inlining mechanism.
        run_skill_clause = scaffold[/`run_skill`[^.]*\./]
        expect(run_skill_clause).to match(/tool result|continuation/)
        expect(scaffold).to include("includes:")
      end
    end
  end

  describe "create-plan's scaffold carries the phases a plan needs" do
    def empty_hole_scaffold
      with_empty_project { |renderer, _root| renderer.render("create-plan") }
    end

    it "settles backwards compatibility, lints before the panel, spikes, and commits" do
      scaffold = empty_hole_scaffold

      expect(scaffold).to match(/backwards.compatib/i)
      expect(scaffold).to include("must keep").and include("free to break")
      expect(scaffold.index("Lint the draft")).to be < scaffold.index("run the panel review")
      expect(scaffold).to match(/[Ss]pike/)
      expect(scaffold).to match(/commit/i)
    end

    it "lists the task-card fields including risk, Reachable from and Stop and report if" do
      scaffold = empty_hole_scaffold

      ["Depends on", "Files", "Reuse", "Shared-file wiring", "Reachable from", "Stop and report if",
       "risk"].each do |field|
        expect(scaffold).to include(field)
      end
    end

    it "stays under run_skill's result ceiling" do
      expect(empty_hole_scaffold.bytesize).to be < Lain::Tool::Bounds::RESULT_BYTES
    end
  end

  describe "the skill catalog header" do
    it "does not claim the shipped tree is empty" do
      source = File.read(File.expand_path("../../../lib/lain/skill/catalog.rb", __dir__))

      expect(source).not_to include("Empty today")
    end
  end

  describe "execute-plan's scaffold orchestrates TDD sub-agents" do
    it "instructs the red-first TDD loop, worktree isolation, and orchestrator-owned commits" do
      with_empty_project do |renderer|
        scaffold = renderer.render("execute-plan").downcase

        expect(scaffold).to include("red")
        expect(scaffold).to include("worktree")
        expect(scaffold).to include("orchestrat")
      end
    end

    it "offers QA between landing and close-out, and hands findings back rather than fixing them" do
      with_empty_project do |renderer|
        scaffold = renderer.render("execute-plan")

        expect(scaffold.index("/qa")).to be_between(scaffold.index("Phase 4 "), scaffold.index("Phase 5 "))
        expect(scaffold).to include("reports, never fixes")
      end
    end

    it "lands a card through the coordinator and never commits on main from bash" do
      with_empty_project do |renderer|
        scaffold = renderer.render("execute-plan")

        expect(scaffold).to include("@dev/implement")
        expect(scaffold).to include("lain land enqueue HEAD --id <card>")
        expect(scaffold).to include("lain land wait")
        expect(scaffold).to match(/never `?git commit`? on main from bash/i)
        expect(scaffold).to match(/verification is skipped/i)
        expect(scaffold).to include("lain land drain --branch")
        expect(scaffold).to match(/^- 2:.{0,80}still queued/im)
        expect(scaffold).to match(/own lease branch/i)
        expect(scaffold).not_to match(/orchestrator-commits.{0,20}never run git/i)
      end
    end

    it "records the base sha beside status when a run starts and the head sha beside status: done when it ends" do
      with_empty_project do |renderer|
        scaffold = renderer.render("execute-plan")
        phase_one = scaffold[/## Phase 1.*?(?=## Phase 2)/m]
        close_out = scaffold[/## Phase 5.*/m]

        expect(phase_one).to match(/`base: <full sha of the base branch tip>`.{0,80}after\s+`status:`/m)
        expect(close_out).to match(/`head: <full sha of the base branch tip>`.{0,80}`status: done`/m)
      end
    end

    it "keeps an execution log, resumes from it, lands on a quiet box and nudges an idle child" do
      with_empty_project do |renderer|
        scaffold = renderer.render("execute-plan")

        expect(scaffold).to match(/Execution\s+log.{0,80}one\s+line\s+per\s+event/im)
        expect(scaffold).to match(/fresh\s+session\s+resumes\s+from\s+(it|the log)/i)
        expect(scaffold).to match(/quiet box/i)
        expect(scaffold).to match(/idle child/i)
      end
    end
  end

  # One source for the ladder's policy, and it is the code. These pin the words
  # the model is told to the names the code records, so a renamed rule or fence
  # cannot leave a prompt describing a ladder nothing runs -- the failure mode
  # this whole spec exists for, one subsystem over.
  describe "qa's scaffold describes the ladder the code runs" do
    it "names every escalation rule the code can record, and the fences it reads replies out of" do
      with_empty_project do |renderer|
        scaffold = renderer.render("qa")

        Lain::QA::Escalation::RULES.each do |rule|
          expect(scaffold).to include("`#{rule.name}`"), "the qa skill never names the #{rule.name} rule"
        end
        expect(scaffold).to include("`#{Lain::QA::Answer::FENCE}`", "`#{Lain::QA::Report::FENCE}`")
      end
    end

    it "names every severity, verdict and rung the code carries" do
      with_empty_project do |renderer|
        scaffold = renderer.render("qa")

        (Lain::QA::SEVERITIES + Lain::QA::VERDICTS + Lain::QA::TIERS).each do |word|
          expect(scaffold).to include("`#{word}`"), "the qa skill never names #{word}"
        end
      end
    end

    # The criteria grammar is closed and its one human-judged marker is
    # `# rubric` -- there is no visual axis, so a scaffold offering a `[visual]`
    # scenario prefix would teach a route to the media rung that no parser reads
    # and no rung answers.
    it "teaches the marker the grammar really carries, and offers no route to a rung nothing binds" do
      with_empty_project do |renderer|
        scaffold = renderer.render("qa")

        expect(scaffold).to include("`#{Lain::Gherkin::Parse::RUBRIC}`")
        expect(scaffold).not_to include("[visual]")
      end
    end

    # The role holds read and search tools and nothing else, so a scaffold that
    # told it to run the suite would be teaching a tool call it cannot make --
    # and `executed` is the one field a model could answer dishonestly for it.
    it "reports rather than fixes, and says the rung runs no command" do
      with_empty_project do |renderer|
        scaffold = renderer.render("qa")

        expect(scaffold).to include("report, never fix")
        # The SENTENCE, not a pattern: an earlier alternation here was satisfied
        # by an unrelated "you cannot run `git`" further down the same scaffold,
        # so deleting this claim left the suite green -- and this claim is the
        # whole reason a rung's `executed` can be trusted to be false.
        expect(scaffold).to include("**you run no commands**")
        expect(scaffold).to include("so it is `false`")
      end
    end

    it "points a project at the tiers slot rather than binding a model itself" do
      with_empty_project do |_renderer, root|
        marker = "QA-TIERS-MARKER-19: t1 is the cheap reader, t2 the strong one."
        write_override(root, "qa", "tiers", marker)

        expect(shipped_renderer(root:).render("qa")).to include(marker)
      end
    end
  end

  describe "critique's scaffold reviews without touching the tree" do
    it "asks for architectural, SOLID, and duplication findings ranked for the author" do
      with_empty_project do |renderer|
        scaffold = renderer.render("critique")

        expect(scaffold).to include("SOLID")
        expect(scaffold.downcase).to include("duplicat")
        expect(scaffold.downcase).to match(/blocker|should-fix|nit|rank/)
      end
    end
  end

  describe "handoff's scaffold leaves a note a fresh session can resume from" do
    it "refuses while children run, writes the six sections under tmp, and prints the resume prompt" do
      with_empty_project do |renderer|
        scaffold = renderer.render("handoff")

        expect(scaffold).to match(/refuse.{0,200}(children|subagent)/mi)
        expect(scaffold).to include("tmp/handoff-<date>-<slug>.md")
        ["Goal", "Decisions", "Current state", "Next steps", "Files that matter", "Open questions"].each do |heading|
          expect(scaffold).to include("## #{heading}")
        end
        expect(scaffold).to match(/argument.{0,120}first.{0,80}Next steps/mi)
        expect(scaffold).to match(/print.{0,80}resume prompt/i)
      end
    end
  end

  describe "implement's scaffold briefs an implementer red first" do
    it "asks for the failing spec first, one commit for lib and spec, named paths and the handback file" do
      with_empty_project do |renderer|
        scaffold = renderer.render("implement")

        expect(scaffold).to match(/failing spec first/i)
        expect(scaffold).to match(/red run/i)
        expect(scaffold).to match(/lib and (its )?spec.*same commit/i)
        expect(scaffold).to match(/name the paths you stage/i)
        expect(scaffold).to match(/handback file/i)
        expect(scaffold).to match(/never run the suite while another run holds the lock/i)
      end
    end

    it "warns a commit runs the hooks and the suite, and forbids --no-verify, reset --hard and stash" do
      with_empty_project do |renderer|
        scaffold = renderer.render("implement")

        expect(scaffold).to match(/commit runs the checkout's hooks and the suite's wall/i)
        expect(scaffold).to include("--no-verify", "git reset --hard", "git stash")
      end
    end

    it "carries no model, so it follows the session" do
      expect(shipped_catalog.fetch(:implement).model.to_s).to eq("")
    end
  end

  describe "the skills that brief children state where a child works" do
    it "has execute-plan brief implementers with relative paths and landing run the card's checks" do
      with_empty_project do |renderer|
        rendered = renderer.render("execute-plan")
        scaffold = rendered.squish
        landing = rendered[/^## Phase 4 .*?(?=^## Phase 4½)/m].to_s.squish

        expect(scaffold).to match(/own checkout, cut from the committed tip/i)
        expect(scaffold).to match(/relative to (its|the child's) working directory/i)
        expect(landing).to match(/card's named checks/i)
        expect(landing).not_to match(/full suite green/i)
      end
    end

    it "has create-plan and research-epic say how a child's files are named" do
      with_empty_project do |renderer|
        expect(renderer.render("create-plan").squish).to match(/commit the plan draft before it can read it/i)
        researching = renderer.render("research-epic").squish
        expect(researching).to match(/researcher works in a scratch directory.{0,80}by absolute path/i)
      end
    end
  end

  describe "implement-issue's scaffold is the epic driver's per-issue brief" do
    it "says the tests are committed, the issue is in the brief, and the actor rebases but never merges" do
      with_empty_project do |renderer|
        scaffold = renderer.render("implement-issue").squish

        expect(scaffold).to match(/failing tests are already committed/i)
        expect(scaffold).to match(/never weaken|must not (be )?weaken/i)
        expect(scaffold).to match(/approved issue.{0,40}in the brief/i)
        expect(scaffold).not_to include("plans/")
        expect(scaffold).to match(/project's own test command/i)
        expect(scaffold).to match(/rebase/i).and match(/harness.{0,40}merg|merg.{0,60}harness/i)
        expect(scaffold).to include("dev", "reviewer_code")
      end
    end

    it "names where the epic's sources live and says child briefs use paths relative to the child's checkout" do
      with_empty_project do |renderer|
        scaffold = renderer.render("implement-issue").squish

        expect(scaffold).to include("/state/lain/epics/test/<slug>/sources")
        expect(scaffold).to include("<slug>/sources` if the research cited any")
        expect(scaffold).to match(/relative to (the child's|its) (checkout|working directory)/i)
        expect(scaffold).to match(/commit .{0,60}before .{0,40}(child|it) can read/i)
      end
    end

    it "mentions none of execute-plan's orchestration vocabulary" do
      with_empty_project do |renderer|
        expect(renderer.render("implement-issue")).not_to match(/commit-mode|panel|task card|lain land|handback file/i)
      end
    end

    it "describes itself as the epic driver's brief and carries none of lain's workflow idioms" do
      skill = shipped_catalog.fetch(:"implement-issue")
      idioms = /design plan|commit-grouping|lib file and its spec|pre-commit|stash|\btraps?\b|\btoolchain\b/i

      expect(skill.description).to match(/epic/i)
      expect(skill.scaffold).not_to match(idioms)
    end
  end

  describe "research's scaffold runs without a human and compares options" do
    it "asks no question, compares 3 options including doing nothing, and writes the dated report" do
      with_empty_project do |renderer|
        scaffold = renderer.render("research")

        expect(scaffold).to match(/ask no question|never ask/i)
        expect(scaffold).to match(/at least 3 options/i)
        expect(scaffold).to match(/do nothing/i)
        expect(scaffold).to match(/existing library/i)
        expect(scaffold).to include("planning/<slug>-research-<YYYY-MM>.md")
        ["Executive summary", "Context", "Options", "Comparison", "Recommendation", "Discarded options",
         "Open questions", "Sources"].each do |heading|
          expect(scaffold).to include("## #{heading}")
        end
        expect(scaffold).to include("@researcher/research")
      end
    end

    it "is listed beside research-epic with a different description" do
      catalog = shipped_catalog

      expect(catalog.names).to include(:research, :"research-epic")
      expect(catalog.all.map(&:description).uniq.size).to eq(catalog.all.size)
    end
  end

  describe "the four epic-tier skills are catalog-visible and render" do
    it "presents each of them in the shipped catalog with a conventions slot that resolves" do
      Dir.mktmpdir do |root|
        catalog = Lain::Skill::Catalog.load(root:)
        renderer = shipped_renderer(root:)

        epic_names.each do |name|
          expect(catalog.names).to include(name)
          expect(catalog.fetch(name).slots).to include(:conventions)
          expect { renderer.render(name) }.not_to raise_error
          expect(renderer.render(name).strip).not_to be_empty
        end
      end
    end

    it "warns the human about the gate window and the denial form in the three skills that submit a gate" do
      with_empty_project do |renderer|
        %i[research-epic plan-epic create-epic-issues].each do |name|
          section = renderer.render(name)[/^## Phase \d+ . Request the .*?(?=^## |\z)/m]

          expect(section).to include("Before you call `epic_submit`", "gate waits 900 seconds", "deny: <reason>")
        end
      end
    end

    it "encodes the phase each one owns" do
      with_empty_project do |renderer|
        # Each scaffold must actually teach its own step of the pipeline rather
        # than being four copies of one epic preamble.
        expect(renderer.render("research-epic")).to include("research.md")
        expect(renderer.render("plan-epic")).to include("epic.md")
        expect(renderer.render("iterate-epic").downcase).to include("split")
        expect(renderer.render("create-epic-issues")).to include("issues/<id>.md")
      end
    end

    it "tells research-epic to keep cited facts as sources and cite them from research.md" do
      with_empty_project do |renderer|
        text = renderer.render("research-epic")

        expect(text).to include("`source`", "sources/<name>.md")
      end
    end

    it "teaches the filename grammar as a refusal rather than a guarantee, and agrees across skills" do
      with_empty_project do |renderer|
        plan = renderer.render("plan-epic")
        issues = renderer.render("create-epic-issues")

        # Both scaffolds quote the SAME constant, so a change to Home::NAME goes
        # red here rather than leaving two skills teaching different rules.
        expect([plan, issues]).to all(include(Lain::Epic::Home::NAME.source))

        # Epic::ID_RESERVED forbids only backticks and line breaks, so `epic.md`
        # legally carries (and round-trips) `Export_Schema`. Home::NAME is the
        # stricter grammar and it REFUSES, at write time, via
        # Home#issue -> checked_name -> MalformedName. A scaffold that says an id
        # reaching it "is already a legal filename" has the implication backwards.
        expect(issues).to include("MalformedName"),
                          "create-epic-issues must name the failure a bad id actually produces"
        expect(issues).not_to match(/already a legal filename/i)
      end
    end

    it "warns that an abandoned blocker still blocks, and names the edge edit that clears it" do
      with_empty_project do |renderer|
        # The domain fact first, so the prose assertion below is pinned to
        # behaviour rather than to a phrase. Graph#ready selects on
        # `status == "done"`, and `abandoned` is not `done`.
        graph = Lain::Epic::Document.parse_markdown(
          "### [ ] `alpha` Alpha\n\nBlocks: `beta`\n\n### [ ] `beta` Beta\n"
        )
        abandoned = Lain::Epic::Graph.new(
          issues: graph.map { |issue| issue.id == "alpha" ? issue.with_status("abandoned") : issue }
        )
        # Silently: nothing raises, `beta` simply never becomes ready.
        expect(abandoned.ready).to be_empty
        expect(abandoned.blocked_by("beta")).to eq(["alpha"])

        # Dropping the edge is what actually unblocks it -- a status change never will.
        cleared = Lain::Epic::Graph.new(
          issues: abandoned.map { |issue| issue.id == "alpha" ? issue.with(blocks: []) : issue }
        )
        expect(cleared.ready.map(&:id)).to eq(["beta"])

        scaffold = renderer.render("iterate-epic")
        expect(scaffold.downcase).to include("abandon"),
                                     "iterate-epic must warn that abandoning a blocker does not unblock"
        expect(scaffold).to match(/edge edit/i)
      end
    end

    # The stage each skill hands its artifact to. Written here as the skill's
    # own claim, checked against {Epic::STAGES} below, so a renamed stage goes
    # red rather than leaving four scaffolds naming a door that closed.
    def ends_at
      { "research-epic" => "research", "plan-epic" => "epic_plan",
        "create-epic-issues" => "issue_plan", "iterate-epic" => "epic_plan" }
    end

    # The verbs `lain epic` really registers, read out of exe/lain's own
    # subcommand block rather than listed here. exe/lain is a script and not a
    # loadable constant, so this is the only way to hold a scaffold to the
    # command surface a user actually has.
    def registered_epic_verbs
      source = File.read(File.expand_path("../../../exe/lain", __dir__))
      start = source.index(/^  class Epic < Thor$/)
      raise "exe/lain no longer declares `class Epic < Thor`; this derivation needs rewriting" if start.nil?

      # Past the declaration line itself before looking for the next class, or
      # the lookahead matches at offset zero and the body comes back empty --
      # which reads as "nothing is registered" rather than as a broken scan.
      rest = source[start..].sub(/\A.*\n/, "")
      body = rest[/\A.*?(?=^  class )/m] || rest
      verbs = body.scan(/^\s{4}desc "([a-z-]+)/).flatten.uniq
      raise "exe/lain's Epic subcommand block parsed to no verbs; this derivation needs rewriting" if verbs.empty?

      verbs
    end

    it "ends each epic skill at the submit stage it owns, through the epic_submit tool" do
      with_empty_project do |renderer|
        ends_at.each do |name, stage|
          expect(Lain::Epic::STAGES.map(&:to_s)).to include(stage)
          rendered = renderer.render(name)
          expect(rendered).to include("epic_submit"), "#{name} never names the epic_submit tool"
          expect(rendered).to match(/epic_submit.{0,200}#{stage}/m), "#{name} never names the stage #{stage} it ends at"
        end
      end
    end

    it "names only verbs lain epic actually registers" do
      with_empty_project do |renderer|
        named = epic_names.flat_map { |name| renderer.render(name).scan(/lain epic ([a-z-]+)/).flatten }.uniq

        expect(named).not_to be_empty
        expect(named - registered_epic_verbs).to be_empty,
                                                 "these skills name `lain epic` verbs nothing registers: " \
                                                 "#{(named - registered_epic_verbs).join(", ")}"
      end
    end

    # Restructuring is an edge rewrite, and the three operations do it. A
    # scaffold telling an author to re-emit `epic.md` by hand is teaching the
    # one move that produces a dangling edge.
    it "has iterate-epic reach for the graph tool rather than re-emitting epic.md by hand" do
      with_empty_project do |renderer|
        scaffold = renderer.render("iterate-epic")

        expect(scaffold).to include("epic_graph")
        %w[split merge add].each do |verb|
          expect(scaffold).to match(/epic_graph.{0,400}#{verb}/m), "iterate-epic never pairs epic_graph with #{verb}"
        end
      end
    end

    it "hands the reader on to the driver and the commands that finish an epic" do
      with_empty_project do |renderer|
        expect(renderer.render("create-epic-issues")).to include("/implement-epic")
        expect(epic_names.map { |name| renderer.render(name) }.join).to include("lain epic finish")
      end
    end

    it "names no internal Ruby API in any epic skill" do
      internals = ["Epic::Home.resolve", "Epic::Home::NAME", "Lain::Epic"]
      with_empty_project do |renderer|
        epic_names.each do |name|
          rendered = renderer.render(name)

          internals.each do |internal|
            expect(rendered).not_to include(internal), "#{name} names the internal #{internal}"
          end
        end
      end
    end

    it "renders the absolute epic home into the skills that write or read artifacts" do
      with_empty_project do |renderer|
        epic_names.each do |name|
          expect(renderer.render(name)).to include("/state/lain/epics/test/"), "#{name} never names the epic home"
        end
      end
    end

    it "has research-epic write through epic_write and submit through epic_submit" do
      with_empty_project do |renderer|
        scaffold = renderer.render("research-epic")

        expect(scaffold).to include("epic_write")
        expect(scaffold).to include("epic_submit")
        expect(scaffold).to include("/state/lain/epics/test")
      end
    end

    it "has plan-epic and create-epic-issues write through epic_write" do
      with_empty_project do |renderer|
        %w[plan-epic create-epic-issues].each do |name|
          expect(renderer.render(name)).to include("epic_write"), "#{name} never names the epic_write tool"
        end
      end
    end

    it "keeps lain epic commands inside paragraphs addressed to the user" do
      with_empty_project do |renderer|
        epic_names.each do |name|
          paragraphs = renderer.render(name).split(/\n\n+/).grep(/lain epic (queue|approve|deny|status|finish|submit)/)

          expect(paragraphs).to all(match(/\buser\b/i)), "#{name} has a lain epic command outside text for the user"
        end
        expect(renderer.render("create-epic-issues")).to include("lain epic finish --local")
      end
    end

    it "tells the agent an adjudicated stage cannot be submitted from the chat" do
      with_empty_project do |renderer|
        epic_names.each do |name|
          paragraph = renderer.render(name).split(/\n\n+/).grep(/cannot be submitted from the chat/).first

          expect(paragraph).to match(/lain epic submit \w+ <slug>/), "#{name} never relays the shell command"
          expect(paragraph).to match(/stop/i)
          expect(paragraph).to match(/no answer/i)
          expect(paragraph).to include("--btw")
        end
      end
    end

    it "does not quote a command in the refusal for an issue_plan submit that names no issue" do
      with_empty_project do |renderer|
        sentence = renderer.render("create-epic-issues")[/the tool refuses an issue_plan submit that names no issue.*/]

        expect(sentence).not_to be_nil
        expect(sentence).not_to include("lain epic")
      end
    end

    it "uses only the verbs, stages and artifacts the tools accept" do
      with_empty_project do |renderer|
        text = epic_names.map { |name| renderer.render(name) }.join
        allowed = {
          "verb" => Lain::Tools::EpicGraph::VERBS, "stage" => Lain::Tools::EpicSubmit::STAGES,
          "artifact" => Lain::Tools::EpicWrite::ARTIFACTS.keys.map(&:to_s)
        }

        allowed.each do |field, values|
          named = text.scan(/`#{field}(?:: |` is )`?([a-z_]+)`/).flatten
          expect(named).not_to be_empty
          expect(named - values).to be_empty, "skills name #{field} values the tool refuses: #{named - values}"
        end
      end
    end

    it "keeps research on the project and the paths the user named" do
      with_empty_project do |renderer|
        phase = renderer.render("research-epic")[/## Phase 2.*?(?=^## Phase 3)/m]

        expect(phase).to match(/paths the user (gave|named)/i)
        expect(phase).to match(/report/i)
        expect(phase).to match(/(not|never|do not) .{0,40}(search|look) above/i)
      end
    end

    it "tells the parent how many researchers the provider runs at once, and each one's limits" do
      with_empty_project do |renderer|
        phase = renderer.render("research-epic")[/## Phase 2.*?(?=^## Phase 3)/m]

        expect(phase).to include("runs 3 requests at once", "at most 3 researchers at a time",
                                 "60 iterations and a 16384-byte answer")
      end
    end

    it "says there is no concurrency limit when the provider declares no width" do
      Dir.mktmpdir do |root|
        renderer = Lain::Skill::Library.load(root:, locals: { epic_home: "/e", gate_window: 900,
                                                              provider_width: "has no concurrency " \
                                                                              "limit that lain enforces",
                                                              researcher_limits: "x" }).renderer

        expect(renderer.render("research-epic")).to include("no concurrency limit that lain enforces")
      end
    end

    it "tells the parent that researchers run commands and spikes in a lease, and names extends" do
      with_empty_project do |renderer|
        text = renderer.render("research-epic")

        expect(text).to match(/researchers? (can|may) run commands/i)
        expect(text).to match(/spike/i)
        expect(text).to include("extends")
      end
    end

    it "tells the user to restart only when this chat created the epic" do
      with_empty_project do |renderer|
        sentence = renderer.render("research-epic").split(/(?<=\.)\s+/).grep(/restart/i)

        expect(sentence.size).to eq(1)
        expect(sentence.first).to match(/if .{0,60}(created|started) .{0,40}this chat/i)
        expect(sentence.first).to match(%r{restart.{0,90}mount.{0,100}(review|/implement-epic)}im)
      end
    end

    # The generated failing tests are placed by mirroring ONE source file, and
    # an Epic::Issue names none -- the plan does, on a `Subject:` line. A
    # scaffold that never teaches it leaves the red step refusing by name.
    it "teaches the plan's Subject: line, which the red step refuses without" do
      with_empty_project do |renderer|
        %w[plan-epic create-epic-issues].each do |name|
          expect(renderer.render(name)).to include("Subject:"),
                                           "#{name} never teaches the plan's Subject: line"
        end
      end
    end

    it "teaches plan-epic to put Subject: and Level: in epic.md, not in a plan file" do
      with_empty_project do |renderer|
        text = renderer.render("plan-epic")

        expect(text).to include("`Subject:`", "`Level:`")
        expect(text).not_to include("plans/<id>.md")
      end
    end

    it "teaches create-epic-issues that lain renders the header, the epic's scenarios and the links" do
      with_empty_project do |renderer|
        text = renderer.render("create-epic-issues")

        expect(text).to include("lain renders", "## Acceptance criteria", "## References")
        expect(text).to match(/do not restate .{0,40}description/i)
        expect(text[/^## Phase 3 .*?(?=^## )/m]).to include("epic_show")
        expect(text).not_to match(/^(Blocked by|Blocks|Related|Discovered from): </)
      end
    end

    it "teaches create-epic-issues the optional Allowed paths section, tests included, and how a gate admits more" do
      with_empty_project do |renderer|
        phase = renderer.render("create-epic-issues")[/^## Phase 2 .*?(?=^## Phase 3 )/m]

        expect(phase).to include("## Allowed paths", "test files", "approve, admit <path>")
      end
    end

    it "has plan-epic and create-epic-issues read status and issues through tools, never a lain epic command" do
      with_empty_project do |renderer|
        %w[plan-epic create-epic-issues].each do |name|
          text = renderer.render(name)

          expect(text).to include("epic_status", "epic_show"), "#{name} never names the read tools"
          expect(text).not_to match(/lain epic (status|show)/), "#{name} still sends the agent to the shell"
        end
      end
    end

    it "teaches create-epic-issues to submit the issue plans one wave at a time" do
      with_empty_project do |renderer|
        phase = renderer.render("create-epic-issues")[/^## Phase 4 .*?(?=^## )/m]

        expect(phase).to include("`wave`", "epic_status", "deny <id>: <reason>")
        expect(phase).to match(/wave by wave|one wave at a time/i)
      end
    end

    it "closes create-epic-issues on a readiness check, after the gate phase and before the hand-off" do
      with_empty_project do |renderer|
        text = renderer.render("create-epic-issues")
        phase = text[/^## Phase 5 .*?(?=^## )/m]

        expect(phase).to include("`epic_status`", "`readiness`", "quote")
        expect(text.index("## Phase 4 ")).to be < text.index("## Phase 5 ")
        expect(text.index("## Phase 5 ")).to be < text.index("## Where the epic goes after you")
      end
    end

    it "has create-epic-issues review each wave with epic_review before it submits, and pass the review id" do
      with_empty_project do |renderer|
        phase = renderer.render("create-epic-issues")[/^## Phase 4 .*?(?=^## )/m]

        expect(phase).to include("epic_review", "`issue_plan`", "`wave`")
        expect(phase.index("epic_review")).to be < phase.index("epic_submit")
        expect(phase.split.join(" ")).to include(quote_per_wave)
      end
    end

    it "has plan-epic review the graph with epic_review before it submits, and pass the review id" do
      with_empty_project do |renderer|
        phase = renderer.render("plan-epic")[/^## Phase 6 .*?(?=^## |\z)/m]

        expect(phase).to include("epic_review", "`epic_plan`")
        expect(phase.index("epic_review")).to be < phase.index("epic_submit")
        expect(phase.split.join(" ")).to include(quote_once)
      end
    end

    it "tells create-epic-issues to relay the shell command the refusal names" do
      with_empty_project do |renderer|
        text = renderer.render("create-epic-issues")

        expect(text).not_to include("relay the shell command\n`lain epic submit issue_plan <slug> --issue <id>`")
        expect(text).to match(/relay the shell\s+command the refusal names/)
      end
    end

    it "says an issue's criteria are approved together with its plan" do
      with_empty_project do |renderer|
        expect(renderer.render("create-epic-issues")).to match(/approved (with|together with) .{0,40}plan/i)
      end
    end

    it "names only stages, statuses, and marks the domain actually carries" do
      with_empty_project do |renderer|
        scaffold = renderer.render("plan-epic")

        Lain::Epic::STAGES.take(2).each { |stage| expect(scaffold).to include(stage) }
        Lain::Epic::STORED_STATUSES.each { |status| expect(scaffold).to include(status) }
        # `ready` is derived, so the scaffold must say so rather than offer it as
        # something an author writes.
        expect(scaffold).to match(/`?ready`? is NOT one of them|`ready` is/i)
        # Blocked by: is refused by the grammar; the epic-side scaffold must not
        # teach it as writable.
        expect(scaffold).to include("`Blocked by:` is not writable")
      end
    end
  end

  # The failure this whole card exists to police: prose that states INTENT as
  # BEHAVIOUR. Two landed objects can read like one feature -- {Gate::Policy::Deferred}
  # parks, {Gate::Adjudicator} spikes-then-adjudicates -- and describing their
  # union teaches a gate nobody has wired.
  #
  # {Gate::Policy::Adjudicated} is what closed the gap: the spike-then-park path
  # IS a selectable policy now, so the scaffolds name it -- as its own policy,
  # beside `deferred` rather than instead of it. `deferred` still gathers
  # nothing, which is why it stays the overnight run's no-spend option.
  describe "the epic scaffolds describe gate behaviour that has actually landed" do
    # Pinned against the DOMAIN, not against the source text. The first attempt
    # here grepped `lib/` for `Adjudicator.new` -- a property of files this spec
    # does not govern, standing in for one it does -- and that came apart in
    # three directions: an aliased or injected construction slipped past it
    # (injection being this repo's house style), an `Adjudicator.new` anywhere
    # unrelated would have fired it falsely, and the cwd-relative glob passed
    # vacuously when rspec ran from another directory.
    #
    # Policy's closed family IS the fact the scaffolds rest on: each policy the
    # prose names has to be one somebody can configure. NAME rather than the
    # class name, because NAME is the durable journal label the scaffolds
    # actually quote.
    it "pins the closed policy family the gate prose depends on" do
      expect(Lain::Epic::Gate::Policy.subclasses.map { |policy| policy::NAME })
        .to match_array(%w[interactive hands_off deferred adjudicated]),
            "The gate policy family has changed. research-epic, plan-epic and create-epic-issues " \
            "each describe every policy a session can configure; re-check all three against the " \
            "policy that moved before relaxing this."
    end

    # ONE CLAIM PER POLICY, not one paragraph per topic. Blank lines separate
    # paragraphs, but a markdown bullet is its own claim inside one, and
    # research-epic states all four policies as a single bullet list -- so a
    # paragraph-level grep matched `deferred` and `adjudicated` on the SAME
    # 1074-character blob and let each policy's sentences satisfy the other's
    # pins. It passed vacuously: an adjudicated bullet rewritten to "the gate
    # then settles itself. It never needs a human." stayed green, because
    # `deferred`'s own "parks the question" answered the park match.
    def gate_claims(scaffold)
      scaffold.split(/\n\n+/).flat_map { |paragraph| paragraph.split(/\n(?=- )/) }
    end

    it "describes deferred as the refusal-and-park it is, asking no model on the way" do
      with_empty_project do |renderer|
        %w[research-epic plan-epic create-epic-issues].each do |name|
          scaffold = renderer.render(name)
          deferred = gate_claims(scaffold).grep(/`deferred`/)
          expect(deferred).not_to be_empty, "#{name} never describes the deferred policy"

          deferred.each do |paragraph|
            expect(paragraph).to match(/refus/i), "#{name}: deferring is a refusal, not a soft yes"
            expect(paragraph).to match(/park/i), "#{name}: a deferred gate parks for later sign-off"
            # `\s+` rather than a literal space: these are wrapped markdown
            # paragraphs, and a phrase that reflows across a line break is the
            # same sentence.
            expect(paragraph).to match(/no\s+model\s+is\s+asked/i),
                                 "#{name}: must say plainly that deferring spends nothing"
            # The blanket claim the scaffolds used to make. It was true of
            # Policy::Deferred and is false of a parked sign-off in general now
            # that Policy::Adjudicated parks WITH evidence attached, and these
            # paragraphs are read as a description of the queue a reviewer will
            # find in the morning.
            expect(paragraph).not_to match(/no\s+evidence\s+is\s+gathered/i),
                                     "#{name}: an adjudicated gate parks with evidence -- do not claim otherwise"
          end
        end
      end
    end

    it "describes adjudicated as a spike that gathers evidence and may still park" do
      with_empty_project do |renderer|
        %w[research-epic plan-epic create-epic-issues].each do |name|
          adjudicated = gate_claims(renderer.render(name)).grep(/`adjudicated`/)
          expect(adjudicated).not_to be_empty, "#{name} never describes the adjudicated policy"

          adjudicated.each do |paragraph|
            expect(paragraph).to match(/spike/i), "#{name}: adjudicating runs a read-only spike first"
            expect(paragraph).to match(/evidence/i), "#{name}: the spike gathers evidence, and it is journaled"
            expect(paragraph).to match(/park/i),
                                 "#{name}: adjudicating may still park for a human -- it is not a gate that " \
                                 "always answers itself"
            # A blank or failed spike parks with `evidence_digest: nil` and
            # {Adjudicator}'s note instead, so a paragraph that promises
            # evidence on EVERY park promises the morning reviewer something
            # the queue will not be holding.
            expect(paragraph).to match(/empty/i),
                                 "#{name}: name the case where the spike came back empty"
            expect(paragraph).to match(/reason/i),
                                 "#{name}: an empty spike parks the reason it failed, not evidence"
          end
        end
      end
    end
  end

  describe "the shipped conventions defaults are neutral" do
    idioms = /design plan|commit-grouping|lib file and its spec|pre-commit|stash|\btraps?\b|\btoolchain\b/i
    conventions_skills = %w[create-epic-issues create-plan execute-plan iterate-epic plan-epic research-epic]

    it "keeps lain's own workflow idioms out of every shipped conventions.md" do
      tree = File.expand_path("../../../lib/lain/prompt/templates/skill", __dir__)
      files = Dir.glob("*/conventions.md", base: tree)

      expect(files.map { |f| File.dirname(f) }).to match_array(conventions_skills)
      files.each { |f| expect(File.read(File.join(tree, f))).not_to match(idioms), f }
    end

    conventions_skills.each do |skill|
      it "renders #{skill} for a bare project naming its own contributor guide" do
        with_empty_project do |renderer|
          rendered = renderer.render(skill).squish

          expect(rendered).to include("If the project has a contributor or agent guide",
                                      "`CONTRIBUTING.md`, `AGENTS.md` or `CLAUDE.md`", "if not, apply")
        end
      end
    end
  end

  describe "a project override replaces an epic skill's conventions fill" do
    it "renders plan-epic with the project's override in place of the shipped default" do
      with_empty_project do |_renderer, root|
        marker = "EPIC-CONVENTIONS-MARKER-77: ids are prefixed by the subsystem."
        write_override(root, "plan-epic", "conventions", marker)

        rendered = shipped_renderer(root:).render("plan-epic")
        expect(rendered).to include(marker)
        # The shipped default's own sentence is GONE, not merely joined -- an
        # override replaces a fill, it does not append to it.
        expect(rendered).not_to include(".lain/slots/skill/plan-epic/conventions.md")
      end
    end
  end

  # The third acceptance criterion, and the one that keeps the prose honest: an
  # example of the grammar that the grammar itself refuses would teach a shape
  # nobody can write. Epic::Document is the arbiter, not a restatement of it here.
  describe "the epic grammar the templates teach parses" do
    it "parses plan-epic's embedded example into a graph whose ids are legal filenames" do
      with_empty_project do |renderer|
        examples = epic_examples(renderer.render("plan-epic"))
        expect(examples).not_to be_empty

        examples.each do |source|
          graph = Lain::Epic::Document.parse_markdown(source)
          expect(graph.ids).not_to be_empty
          # An id is both a grammar token and a filename, and the filename
          # grammar is the stricter of the two -- the scaffold claims ids that
          # satisfy both, so every id it shows must survive this.
          graph.ids.each { |id| expect { Lain::Epic::Home.checked_name(id, "issue id") }.not_to raise_error }
        end
      end
    end

    it "round-trips every embedded example byte-for-byte through the emitter" do
      with_empty_project do |renderer|
        epic_names.flat_map { |name| epic_examples(renderer.render(name)) }.each do |source|
          graph = Lain::Epic::Document.parse_markdown(source)
          # Byte-identical, not merely digest-equal: the scaffold tells an author
          # that a document shaped like the example survives later edits
          # unchanged, and that claim is only true if the emitter agrees.
          expect(Lain::Epic::Document.to_markdown(graph)).to eq(source)
        end
      end
    end

    it "shows every status mark the grammar defines across the epic-tier examples" do
      with_empty_project do |renderer|
        statuses = epic_names.flat_map { |name| epic_examples(renderer.render(name)) }
                             .flat_map { |source| Lain::Epic::Document.parse_markdown(source).map(&:status) }
        expect(statuses.uniq).to match_array(Lain::Epic::STORED_STATUSES)
      end
    end

    it "teaches the derived provenance edge by showing one that names a vanished issue" do
      with_empty_project do |renderer|
        graphs = epic_names.flat_map { |name| epic_examples(renderer.render(name)) }
                           .map { |source| Lain::Epic::Document.parse_markdown(source) }
        # `Discovered from:` outliving its target is the one dangling reference
        # the grammar allows, and a split is why. An example that never shows it
        # would leave an author believing every id in a link line must resolve.
        vanished = graphs.any? do |graph|
          graph.any? { |issue| issue.discovered_from && !graph.ids.include?(issue.discovered_from) }
        end
        expect(vanished).to be(true)
      end
    end
  end

  describe "a user slot extends a shipped skill at the declared hole" do
    it "renders create-plan with the project's conventions override in place of the shipped default" do
      with_empty_project do |_renderer, root|
        marker = "USER-CONVENTIONS-MARKER-42: prefer the smallest seam."
        write_override(root, "create-plan", "conventions", marker)

        # Reload against the same root so the override is read from disk.
        rendered = shipped_renderer(root:).render("create-plan")
        expect(rendered).to include(marker)
      end
    end
  end
end
