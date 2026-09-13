# frozen_string_literal: true

# Mechanical enforcement of the rule {Lain::Tool::Bounds} states and nothing
# until now checked: a tool whose result carries arbitrary content declares a
# ceiling. It sits at `spec/*_discipline_spec.rb` with its siblings rather than
# at a mirror path, for `output_discipline_spec.rb`'s reason -- the subject is
# the whole toolset, not one class, and a gate nobody finds gets duplicated or
# disabled.
#
# == Why the enumeration is the point
#
# A bound is a class constant each tool consults privately, so nothing links
# one tool's ceiling to another's and nothing at all reports a tool that has
# none. The only list of which tools were bounded has twice been prose in a
# planning document, and was stale both times -- once because a tool was added
# after the list was written, once because a bound was added after it. Prose
# drift is silent by construction. So the list lives here, derived from the
# tree on every run, and the only hand-maintained half is the set of tools
# EXEMPT from the rule, each with the reason it is exempt.
#
# The exempt list is the deliverable, not a loophole. A tool whose result is
# structurally a fixed sentence has no ceiling to declare, and saying so beside
# the tool's name is what makes the next reader see a decision instead of an
# omission.
#
# == Matching a shape, not a name
#
# The naming across the tree is already non-uniform -- `OUTPUT_BOUND`,
# `WHOLE_BOUND`/`WINDOW_BOUND`, `DEFINITIONS_BOUND`/`REFERENCES_BOUND`,
# `ANSWER_BOUND`, `EXPANSION_BOUND`, and a bare `BOUND` at six tools -- so a
# sweep keyed on the constant's NAME would be wrong before it reached its
# second tool. What is asked instead is whether a constant's VALUE is one of
# {Lain::Tool::Bounds}' shapes, which is the thing the rule is actually about.
#
# The shapes themselves are derived rather than listed, so a fourth one is
# covered the day it lands: a `Data` subclass under {Lain::Tool::Bounds} that
# answers `admits?` is a ceiling. That predicate is what separates the three
# bounds from {Lain::Tool::Bounds::Overrun}, which is a `Data` under the same
# module carrying `limit` -- a result rather than a ceiling, and a tool holding
# one would not thereby be bounded.
#
# == One level of nesting, for exactly one tool
#
# {Lain::Tools::AskHuman}'s ceiling is `Ceiling::BOUND`, a module nested beside
# the subject line and the confirmation word that are read together with it.
# Hoisting it to satisfy this sweep would split a coherent object to please a
# test, so the sweep descends one level into a tool's own nested constants
# instead. One level and no more: an unbounded depth would start finding
# ceilings that belong to something else a tool merely holds a reference to.
#
# That tool is the descent's SINGLE justification, and a future reader deciding
# whether the descent still earns its place needs that stated rather than
# guessed. {Lain::Tools::RunSkill} looks like a second one and is not: its
# `Ceiling` is a `Data.define(:bound)` whose default is the direct class
# constant `EXPANSION_BOUND`, so the sweep finds that tool at the top level and
# never descends for it. Delete the descent and only `ask_human` and its
# delivery variant go unbounded.
#
# Inherited declarations count, which is what covers `::Unattended` -- the
# same tool with a different delivery, declaring no bound of its own and
# reaching `Ceiling::BOUND` through its superclass exactly as its own
# `#perform` does.
#
# == What this sweep cannot see
#
# `Lain::Middleware::SkillDispatch#expand` is unbounded and will NOT be caught
# here, because it is a {Lain::Middleware::Base} and not a {Lain::Tool}
# subclass. That is the known gap and it is currently deliberate: a human typed
# `/skill` and is at a terminal, so the plausible answer there is
# confirm-and-proceed rather than a ceiling. The asymmetry is real -- the same
# skill expansion reaching the model through {Lain::Tools::RunSkill} is bounded
# by `EXPANSION_BOUND` and reaching it through the middleware is bounded by
# nothing -- so the gap is ASSERTED below rather than only described here, the
# way `refusal_delivery_discipline_spec.rb` asserts its two lexical blind
# spots. A file written to end prose lists cannot record its own gap in prose.
#
# The subject set is also restricted to tools named under `Lain::`. Specs
# define their own {Lain::Tool} subclasses at load time and `parallel_tests`
# gives each worker a different set of them, so an unrestricted `ObjectSpace`
# sweep would have a subject set that depended on which files a worker drew.
# The restriction is what makes the same tools swept in every process; it also
# means an anonymous tool can never be swept, which is fine, because an
# anonymous tool cannot be named on the exempt list either.

module ToolBoundsDiscipline
  module_function

  # The ceiling shapes, derived. `admits?` is the question a ceiling answers and
  # {Lain::Tool::Bounds::Overrun} -- a `Data` under the same module, carrying a
  # `limit` -- does not answer it.
  def shapes
    Lain::Tool::Bounds.constants(false).filter_map do |name|
      value = Lain::Tool::Bounds.const_get(name)
      value if value.is_a?(Class) && value < Data && value.method_defined?(:admits?)
    end
  end

  def bound?(value) = shapes.any? { |shape| value.is_a?(shape) }

  # Every tool the suite can enumerate, named under `Lain::` so the set does not
  # depend on which spec files a worker happened to load.
  def tools
    ObjectSpace.each_object(Class).select do |klass|
      klass < Lain::Tool && klass.name.to_s.start_with?("Lain::")
    rescue StandardError
      false
    end.sort_by(&:name)
  end

  # @return [Array<String>] the fully-qualified path of every bound this tool
  #   declares or inherits, own constants and one level of nesting
  def declarations(klass)
    tool_ancestors(klass).flat_map { |ancestor| declared_on(ancestor) }.uniq
  end

  def declares_bound?(klass) = !declarations(klass).empty?

  # The rule itself, over any set of tools and any exempt list -- factored out
  # of the example that applies it to the real tree so a synthetic tool can be
  # put through the same code rather than through a comment claiming it would
  # be caught.
  #
  # @param tools [Array<Class>]
  # @param exempt [Array<String>] fully-qualified names
  # @return [Array<Class>] the tools that neither declare a bound nor are exempt
  def unaccounted(tools, exempt)
    tools.reject { |tool| declares_bound?(tool) || exempt.include?(tool.name) }
  end

  # Up the chain rather than at the class alone: a delivery variant that
  # overrides `#perform` still reaches its parent's ceiling by constant lookup,
  # so a sweep that ignored ancestry would report a tool unbounded that is not.
  def tool_ancestors(klass)
    klass.ancestors.select { |ancestor| ancestor.is_a?(Class) && ancestor <= Lain::Tool }
  end

  def declared_on(owner)
    owner.constants(false).flat_map do |name|
      value = read(owner, name)
      if bound?(value) then ["#{owner}::#{name}"]
      elsif nested_in?(owner, value) then declared_on_nested(value)
      else []
      end
    end
  end

  # The second and last level. A nested constant is descended into only when it
  # is not itself a tool -- a tool nested inside another declares its own
  # bounds, and reading them as the outer one's would report a ceiling where
  # there is none.
  def declared_on_nested(owner)
    owner.constants(false).filter_map do |name|
      "#{owner}::#{name}" if bound?(read(owner, name))
    end
  end

  def nested_in?(owner, value)
    return false unless value.is_a?(Module)
    return false if value.is_a?(Class) && value <= Lain::Tool

    owner.name.nil? || value.name.nil? || value.name.start_with?("#{owner.name}::")
  end

  # A constant a class holds but cannot resolve is not a bound. Autoload
  # failures and deprecation raisers both arrive here, and neither is this
  # sweep's business.
  def read(owner, name)
    owner.const_get(name, false)
  rescue StandardError, LoadError
    nil
  end
end

ToolExemption = Data.define(:tool, :grounds, :reason, :delegates_to)

# One tool the bound rule does not apply to, as one row. Reopened rather than
# built in a `Data.define` block, because a constant set inside that block lands
# on the enclosing scope instead of on the value class.
#
# `grounds` is drawn from a closed set so the reasons stay comparable across
# rows, and `reason` says the tool-specific half in words. Both are required:
# the grounds alone would let two unlike cases wear one label, and the prose
# alone would let the list grow a new category nobody noticed.
#
# `delegates_to` belongs to exactly one ground, so the pairing is an invariant
# of the value rather than a rule some example remembers to apply. A delegated
# row with no constant would otherwise reach `const_get(nil)` and die of a
# TypeError, which reads like a broken spec instead of an incomplete row.
class ToolExemption
  # The result is a fixed sentence, or a rendering of something whose size the
  # run configures rather than the world -- there is no arbitrary content to put
  # a ceiling on.
  FIXED_RESULT = :fixed_result

  # A cap applied DURING the walk, disclosed in band with the tool's own
  # trailer. {Lain::Tool::Bounds::Enumeration} cannot express these: its `#cap`
  # derives the true total from `rows.size`, and these tools stop walking
  # precisely so they never build the whole collection. Their wording is pinned
  # by other specs and the class doc on `lib/lain/tool/bounds.rb` says not to
  # unify the two formats.
  PRE_BOUNDS_TRAILER = :pre_bounds_trailer

  # The tool renders its result through another tool's declared bound, so it
  # holds no constant of its own by design -- one ceiling, not two that could
  # drift. The row names the constant, and the sweep resolves it.
  DELEGATED = :delegated

  # NOT a design decision: a tool that returns arbitrary content with no
  # ceiling, recorded here truthfully because the sweep found it and because
  # deciding what to do about it is a human's call rather than this spec's.
  # Every row under these grounds is pinned by name below, so one cannot be
  # added quietly.
  AWAITING_RULING = :awaiting_ruling

  GROUNDS = [FIXED_RESULT, PRE_BOUNDS_TRAILER, DELEGATED, AWAITING_RULING].freeze

  def initialize(tool:, grounds:, reason:, delegates_to: nil)
    raise ArgumentError, "#{tool}: unknown grounds #{grounds.inspect}, want one of #{GROUNDS.inspect}" unless
      GROUNDS.include?(grounds)
    raise ArgumentError, "#{tool} delegates, so it must name the constant it delegates to" if
      grounds == DELEGATED && delegates_to.nil?
    raise ArgumentError, "#{tool}: #{grounds.inspect} does not delegate, so it must name no constant" if
      delegates_to && grounds != DELEGATED

    super
  end
end

module ToolBoundsRegistry
  # Prose this short is a label rather than a reason, and a label is what this
  # list exists to replace: "fixed sentence" beside a tool name tells the next
  # reader nothing they could not have guessed, while the sentence naming WHICH
  # sentence the tool answers with is checkable against the code.
  REASON_FLOOR = 40

  # An Array, and the shape was chosen after trying the other one. A Hash keyed
  # by the tool LOOKS as though it makes a second, contradicting row for one
  # tool unrepresentable; what it actually does is let the later literal key win
  # in silence, so a tool carrying both "answers with a fixed sentence" and
  # "unbounded, awaiting a ruling" would read as whichever row happened to be
  # written last. Absorbing a contradiction is the failure this whole file is
  # written against, so the rows are held exactly as written and an example
  # below names any tool that has two of them.
  EXEMPT = [
    ToolExemption.new(
      tool: "Lain::Tools::EditFile", grounds: ToolExemption::FIXED_RESULT,
      reason: "answers with one sentence naming the path and the count of replacements it made; " \
              "the file's own content never comes back through the result"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::WriteFile", grounds: ToolExemption::FIXED_RESULT,
      reason: "answers with the byte count it wrote and the path it wrote to -- a measurement of " \
              "the content rather than the content"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::TodoWrite", grounds: ToolExemption::FIXED_RESULT,
      reason: "answers with the number of items the list now holds; the items themselves came " \
              "from the model and are not quoted back at it"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::ImprovementWrite", grounds: ToolExemption::FIXED_RESULT,
      reason: "answers with the kind of improvement recorded and the project it was filed under, " \
              "never the recorded text"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::SessionUsage", grounds: ToolExemption::FIXED_RESULT,
      reason: "answers with a header, a fixed set of counters and one ratio -- the line count is a " \
              "property of the renderer and does not move with the session's size"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::ToolSearch", grounds: ToolExemption::FIXED_RESULT,
      reason: "renders one tool's schema or a match list over the toolset, so its size is set by " \
              "the toolset a run was configured with and not by anything the model or the world supplies"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::Grep", grounds: ToolExemption::PRE_BOUNDS_TRAILER,
      reason: "pulls one match past its cap off a lazy walk so it never scans the rest, and the " \
              "daemon arm returns only a capped boolean -- neither can report the true total an " \
              "Enumeration notice names, and the existing trailer's wording is pinned elsewhere"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::AstSearch", grounds: ToolExemption::PRE_BOUNDS_TRAILER,
      reason: "caps during the walk exactly as grep does, and discloses it with the same trailer"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::AstDump", grounds: ToolExemption::PRE_BOUNDS_TRAILER,
      reason: "the extension caps the dump as it emits and ends the output with its own capped-at " \
              "line; a source nested past the depth cap is refused outright, naming that cap"
    ),
    ToolExemption.new(
      tool: "Lain::Bench::DisclosureSweep::FixtureTool", grounds: ToolExemption::FIXED_RESULT,
      reason: "a bench fixture carrying a name and a description read from a committed YAML file; " \
              "it is never routed through Tool#call and returns no result at all"
    ),
    ToolExemption.new(
      tool: "Lain::Bench::VarianceFixtures::DosingLookup", grounds: ToolExemption::FIXED_RESULT,
      reason: "a bench fixture answering one synthetic sentence with the drug name interpolated " \
              "into it; never wired into a shipped toolset"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::WebFetch", grounds: ToolExemption::AWAITING_RULING,
      reason: "TRUNCATES a page at 5 MiB and appends a label saying so, which is exactly what the " \
              "Bounds class doc argues a whole artifact must never do -- its first N bytes read " \
              "like the answer and are not -- and at 40x bash's ceiling besides. The cap is a " \
              "constructor argument, so it is not even a class constant a reader could find. " \
              "Recorded as found, not endorsed: whether it should become an Artifact refusal is a " \
              "ruling nobody has made"
    ),
    ToolExemption.new(
      tool: "Lain::Tools::RequestReview", grounds: ToolExemption::AWAITING_RULING,
      reason: "quotes every human annotation verbatim into its result with no ceiling. Its INPUTS " \
              "are bounded by Review::Bounds, but that bounds the changeset a reviewer is shown " \
              "and says nothing about how much a reviewer then types, so bounded-at-one-remove " \
              "does not reach the bytes this tool actually returns. Recorded as found, not endorsed"
    )
  ].freeze

  def self.names = EXEMPT.map(&:tool)

  def self.with_grounds(grounds) = EXEMPT.select { |row| row.grounds == grounds }
end

RSpec.describe "tool bounds discipline" do
  let(:tools) { ToolBoundsDiscipline.tools }

  it "sweeps the whole shipped toolset, so an empty sweep cannot read as a pass" do
    shipped = ToolRegistry.names.map { |name| ToolRegistry.build(name).class }

    # The size is asserted as well as the difference, because an empty `shipped`
    # would make the difference empty too and this example would then pass while
    # checking nothing at all.
    expect(shipped.size).to eq(ToolRegistry.names.size)
    expect(shipped - tools).to be_empty
  end

  it "derives the ceiling shapes without listing them, and does not mistake a result for one" do
    expect(ToolBoundsDiscipline.shapes).to contain_exactly(Lain::Tool::Bounds::Enumeration,
                                                           Lain::Tool::Bounds::Artifact,
                                                           Lain::Tool::Bounds::Handback)
  end

  it "has every tool either declaring a bound or named on the exempt list" do
    unaccounted = ToolBoundsDiscipline.unaccounted(tools, ToolBoundsRegistry.names)

    expect(unaccounted.map(&:name)).to be_empty, lambda {
      listing = unaccounted.map { |tool| "  #{tool.name}" }.join("\n")
      "A tool that returns arbitrary content declares a ceiling from Lain::Tool::Bounds. Found " \
        "neither a bound nor an exemption for:\n#{listing}\n" \
        "Declare a bound as a class constant, or add a row to ToolBoundsRegistry::EXEMPT saying why " \
        "this tool has nothing to bound."
    }
  end

  it "carries one row per tool, so nothing is exempt for two contradicting reasons" do
    doubled = ToolBoundsRegistry::EXEMPT.group_by(&:tool).select { |_, rows| rows.size > 1 }

    expect(doubled.keys).to be_empty, lambda {
      listing = doubled.map { |tool, rows| "  #{tool} -> #{rows.map(&:grounds).inspect}" }.join("\n")
      "A tool with two exempt rows is exempt twice over for reasons that need not agree, and the " \
        "list stops saying anything about it. Keep one row:\n#{listing}"
    }
  end

  it "carries a reason on every exempt row, not just a label" do
    thin = ToolBoundsRegistry::EXEMPT.select do |row|
      row.reason.to_s.strip.length <= ToolBoundsRegistry::REASON_FLOOR
    end

    expect(thin.map(&:tool)).to be_empty, lambda {
      listing = thin.map { |row| "  #{row.tool} (#{row.grounds}) -> #{row.reason.inspect}" }.join("\n")
      "An exempt row's reason is what makes the next reader see a decision instead of an omission, " \
        "so it says in words what this tool answers with and why that has no ceiling. Under " \
        "#{ToolBoundsRegistry::REASON_FLOOR} characters is a label, not a reason:\n#{listing}"
    }
  end

  it "keeps no row for a tool that has since declared a bound" do
    stale = ToolBoundsRegistry.names.select do |name|
      tool = tools.find { |klass| klass.name == name }
      tool && ToolBoundsDiscipline.declares_bound?(tool)
    end

    expect(stale).to be_empty, lambda {
      listing = stale.map do |name|
        "  #{name} -> #{ToolBoundsDiscipline.declarations(Object.const_get(name)).join(", ")}"
      end
      "These tools now declare a bound, so their exempt rows are stale and say the opposite of the " \
        "tree. Delete the row:\n#{listing.join("\n")}"
    }
  end

  it "names no tool the sweep cannot find" do
    missing = ToolBoundsRegistry.names - tools.map(&:name)

    expect(missing).to be_empty, lambda {
      "The exempt list names tools that no longer exist under Lain::, so these rows exempt nothing " \
        "and hide nothing:\n#{missing.map { |name| "  #{name}" }.join("\n")}"
    }
  end

  # A delegated row is the one kind whose reason is checkable, so it is checked:
  # the constant it names has to be a real ceiling, or the row is a claim rather
  # than a fact. No shipped row carries this ground at present, so this asserts
  # over an empty list and says so -- the rule itself is pinned against
  # hand-built rows in the unit block below, which is where it stays checkable
  # while nothing uses it.
  it "resolves the ceiling every delegated row points at" do
    delegated = ToolBoundsRegistry.with_grounds(ToolExemption::DELEGATED)
    unresolved = delegated.reject { |row| ToolBoundsDiscipline.bound?(Object.const_get(row.delegates_to)) }

    expect(unresolved.map(&:tool)).to be_empty, lambda {
      listing = unresolved.map { |row| "  #{row.tool} -> #{row.delegates_to}" }.join("\n")
      "A delegated row claims another tool's ceiling covers this one, and the constant it names is " \
        "not a Lain::Tool::Bounds value:\n#{listing}"
    }
  end

  # Pinned by name rather than counted, so a new one is a red example naming the
  # tool. These are findings the sweep made, held here until somebody rules on
  # them -- the list growing silently is the failure this whole file exists
  # against.
  it "pins the tools recorded as unbounded rather than exempt" do
    awaiting = ToolBoundsRegistry.with_grounds(ToolExemption::AWAITING_RULING).map(&:tool)
    known = ["Lain::Tools::WebFetch", "Lain::Tools::RequestReview"]

    expect(awaiting).to match_array(known), lambda {
      standing = ["now: #{awaiting.sort.inspect}", "pinned: #{known.sort.inspect}"].join("\n  ")
      "These rows are findings, not exemptions: a tool that returns arbitrary content with no " \
        "ceiling, recorded until a human rules on it.\n  #{standing}\n" \
        "A tool ADDED here was found unbounded -- bound it, or get the ruling and update this list. " \
        "A tool REMOVED was ruled on -- update the list in the same commit as the ruling."
    }
  end

  # The gap the module comment names, asserted so it stays a decision rather
  # than becoming a surprise, and so the comment is forced up to date the day
  # somebody makes this a tool.
  it "cannot see a skill expansion that never passes through a tool" do
    expect(Lain::Middleware::SkillDispatch).to be < Lain::Middleware::Base
    expect(Lain::Middleware::SkillDispatch < Lain::Tool).to be_nil
    expect(tools).not_to include(Lain::Middleware::SkillDispatch)

    # The other half of the asymmetry: the same expansion reaching the model
    # through the tool path IS bounded, which is what makes the gap worth a name.
    expect(ToolBoundsDiscipline.declarations(Lain::Tools::RunSkill))
      .to contain_exactly("Lain::Tools::RunSkill::EXPANSION_BOUND")
  end

  describe "an exempt row" do
    it "refuses grounds outside the closed set" do
      expect { ToolExemption.new(tool: "Lain::Tools::Nope", grounds: :seems_fine, reason: "a" * 60) }
        .to raise_error(ArgumentError, /unknown grounds/)
    end

    it "refuses to delegate without naming the ceiling it delegates to" do
      expect { ToolExemption.new(tool: "Lain::Tools::Nope", grounds: ToolExemption::DELEGATED, reason: "a" * 60) }
        .to raise_error(ArgumentError, /must name the constant/)
    end

    it "refuses to name a ceiling under grounds that do not delegate" do
      expect do
        ToolExemption.new(tool: "Lain::Tools::Nope", grounds: ToolExemption::FIXED_RESULT,
                          reason: "a" * 60, delegates_to: "X")
      end.to raise_error(ArgumentError, /does not delegate/)
    end

    # What a delegated row CLAIMS, asked of the claim rather than of the roster:
    # the constant it names has to be a ceiling, or the row is prose. No shipped
    # tool carries this ground today, so the registry example above runs over an
    # empty list and this is the only place the rule still has teeth. Both
    # directions are asserted, because a resolver that answered true for
    # everything would satisfy the first half alone.
    it "delegates to a real ceiling, and a constant that is merely present is not one" do
      ceiling = ToolExemption.new(tool: "Lain::Tools::Nope", grounds: ToolExemption::DELEGATED,
                                  delegates_to: "Lain::Tools::Bash::OUTPUT_BOUND", reason: "a" * 60)
      prose = ToolExemption.new(tool: "Lain::Tools::Nope", grounds: ToolExemption::DELEGATED,
                                delegates_to: "Lain::Tools::Bash::NARROWER", reason: "a" * 60)

      expect(ToolBoundsDiscipline.bound?(Object.const_get(ceiling.delegates_to))).to be(true)
      expect(ToolBoundsDiscipline.bound?(Object.const_get(prose.delegates_to))).to be(false)
    end
  end

  describe "the sweep itself" do
    # A NAMED namespace, and that is load-bearing rather than tidy. Ruby gives a
    # module const_set on an anonymous owner a temporary name rooted at its own
    # object id, so an anonymous fixture's nested module reports
    # `#<Module:0x..>::Inner` and #nested_in? rejects it for a reason that has
    # nothing to do with the rule -- which made the depth example below pass
    # against an implementation that recursed without limit. Real tools are
    # named, so the fixtures are too.
    def namespaced(path)
      path.split("::").inject(nil) do |parent, part|
        name = [parent, part].compact.join("::")
        stub_const(name, Module.new) unless Object.const_defined?(name)
        name
      end
      Object.const_get(path)
    end

    def tool_under(namespace, name)
      stub_const("#{namespace}::#{name}", Class.new(Lain::Tool))
    end

    it "names a tool that returns arbitrary content and declares nothing (self-test)" do
      unbounded = Class.new(Lain::Tool) do
        def name = "returns_whatever_it_read"

        def perform(input, _invocation) = Lain::Tool::Result.ok(File.read(input.fetch("path")))
      end
      bounded = Class.new(Lain::Tool) { const_set(:BOUND, Lain::Tool::Bounds::Artifact.new(limit: 8)) }

      expect(ToolBoundsDiscipline.declarations(unbounded)).to be_empty
      expect(ToolBoundsDiscipline.unaccounted([unbounded, bounded], [])).to contain_exactly(unbounded)
    end

    it "stops naming a tool once the exempt list carries it (self-test)" do
      named = Class.new(Lain::Tool)
      allow(named).to receive(:name).and_return("Lain::Tools::Hypothetical")

      expect(ToolBoundsDiscipline.unaccounted([named], ["Lain::Tools::Hypothetical"])).to be_empty
    end

    it "sees a bound whatever the constant is called (self-test)" do
      oddly_named = Class.new(Lain::Tool) do
        const_set(:SOME_OTHER_WORD, Lain::Tool::Bounds::Artifact.new(limit: 8))
      end

      expect(ToolBoundsDiscipline.declares_bound?(oddly_named)).to be(true)
    end

    it "sees a bound one level down, as ask_human's is (self-test)" do
      namespaced("ToolBoundsFixture")
      tool = tool_under("ToolBoundsFixture", "Nested")
      namespaced("ToolBoundsFixture::Nested::Ceiling")
        .const_set(:BOUND, Lain::Tool::Bounds::Handback.new(limit: 8))

      expect(ToolBoundsDiscipline.declarations(tool))
        .to contain_exactly("ToolBoundsFixture::Nested::Ceiling::BOUND")
    end

    it "does not descend past one level (self-test)" do
      namespaced("ToolBoundsFixture")
      tool = tool_under("ToolBoundsFixture", "Buried")
      namespaced("ToolBoundsFixture::Buried::Outer::Inner")
        .const_set(:BOUND, Lain::Tool::Bounds::Handback.new(limit: 8))

      expect(ToolBoundsDiscipline.declares_bound?(tool)).to be(false)
    end

    it "counts a parent's bound for a delivery variant that inherits it (self-test)" do
      parent = Class.new(Lain::Tool) { const_set(:BOUND, Lain::Tool::Bounds::Artifact.new(limit: 8)) }

      expect(ToolBoundsDiscipline.declares_bound?(Class.new(parent))).to be(true)
    end

    it "does not read a nested tool's own bound as the outer one's (self-test)" do
      outer = Class.new(Lain::Tool) do
        const_set(:Inner, Class.new(Lain::Tool) { const_set(:BOUND, Lain::Tool::Bounds::Artifact.new(limit: 8)) })
      end

      expect(ToolBoundsDiscipline.declares_bound?(outer)).to be(false)
    end

    it "does not mistake an overrun for a ceiling (self-test)" do
      holder = Class.new(Lain::Tool) do
        const_set(:OVER, Lain::Tool::Bounds::Handback.new(limit: 1)
                                                     .overrun(subject: "x", content: "xx", actions: ["shorten it"]))
      end

      expect(ToolBoundsDiscipline.declares_bound?(holder)).to be(false)
    end
  end
end
