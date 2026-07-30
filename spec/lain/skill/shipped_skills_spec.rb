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
    catalog = Lain::Skill::Catalog.load(root:)
    slots = Lain::Prompt::Slots.load(root:)
    Lain::Skill::Renderer.new(catalog:, slots:)
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
    it "ships the process skills, gherkin-tests, and the four epic-tier skills" do
      expect(shipped_names).to include(:"create-plan", :"execute-plan", :critique, :"gherkin-tests")
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
  end

  describe "create-plan's scaffold drives a plan, not code" do
    it "instructs grounding-before-planning, Gherkin acceptance criteria, and writing to planning/specs" do
      with_empty_project do |renderer|
        scaffold = renderer.render("create-plan")

        expect(scaffold.downcase).to include("ground")
        expect(scaffold.downcase).to match(/before .*plan|ground.* first|ground.* before/)
        expect(scaffold).to match(/[Gg]herkin/)
        expect(scaffold).to include("planning/specs")
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

  describe "execute-plan's scaffold orchestrates TDD sub-agents" do
    it "instructs the red-first TDD loop, worktree isolation, and orchestrator-owned commits" do
      with_empty_project do |renderer|
        scaffold = renderer.render("execute-plan").downcase

        expect(scaffold).to include("red")
        expect(scaffold).to include("worktree")
        expect(scaffold).to include("orchestrat")
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
      expect(Lain::Approval::Gate::Policy.subclasses.map { |policy| policy::NAME })
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
