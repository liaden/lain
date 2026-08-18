# frozen_string_literal: true

require "prism"
require "pathname"

# Mechanical, REPORT-ONLY guard against assertion shapes that structurally
# cannot fail. The suite is largely LLM-written and keeps growing that way, so
# a one-time prune (T16) only fixes today's instances -- this spec is what
# makes tomorrow's mechanically visible, the way `output_discipline_spec.rb`
# makes a stray `puts` visible.
#
# Two shapes, both drawn from a manual audit during planning:
#
#   1. An example whose only assertions are `expect { ... }.not_to raise_error`
#      (or `.to_not`) -- "no non-vacuous assertion", not literally "exactly
#      one call": TWO such calls and nothing else is still 100% vacuous (see
#      `sole_raise_error_shape?`/`record_example_result`). "Nothing raised" is
#      true of almost any program state, so a lone instance of this cannot
#      fail for the reason the example claims to cover -- but that is a claim
#      about the ASSERTION, not a verdict on the example. This IS flagged
#      when it is genuinely the example's only assertion, including the
#      card's own named keep,
#      spec/support/shared_examples/review_surface.rb:242-250 (one call of
#      each port message inside a single `expect do ... end.not_to
#      raise_error`, no second assertion beside it -- it does NOT escape this
#      rule by having a real assertion next to it). The card judges that one
#      worth keeping anyway -- cheap coverage that the whole port survives one
#      pass -- so it is flagged AND kept, not evidence the rule mis-fired;
#      see `.handback-T18-report.md`'s "card-named keeps" section, since this
#      guard builds no allowlist to encode that judgment in code. The report
#      also finds this shape's precision to be well under 100% generally (see
#      its own banner) -- FLAGGED is a claim about the assertion, never a
#      verdict on the check it wraps.
#      KNOWN LIMITATION: only `expect(...)`/`is_expected`/
#      `expect_any_instance_of` receivers are recognised as assertions.
#      Project helpers that wrap `expect` internally (e.g. `expect_journaled`)
#      are statically invisible to this scan and can produce a false "sole"
#      flag -- not fixable without evaluating the helper's body, so it stays
#      a documented gap rather than a guess. Also unaddressed on purpose:
#      `not_to raise_error(SpecificError)` (a class-filtered negative) is
#      flagged identically to the bare form today; it is arguably a
#      different, slightly less vacuous shape, but affects zero currently
#      flagged instances (the one occurrence in the suite,
#      `spec/lain/rust/prompt_spec.rb:110`, sits beside a second real
#      assertion and was never flagged to begin with), so it is left as a
#      noted distinction rather than a special case with nothing to test it.
#   2. A nested `expect` inside an `expect { ... }` block, flagged regardless
#      of what else the example asserts. The mechanism is NOT "raise_error
#      swallows the inner exception" -- `spec/spec_helper.rb:57-58` turns on
#      `aggregate_failures` for every example by default (opt out with
#      `aggregate_failures: false`), and aggregation replaces the failure
#      NOTIFIER: a failing inner `expect` never raises at all, it is
#      collected and reported separately, at its own line, once the example
#      ends. So the outer `expect { }.not_to raise_error` sees nothing rise
#      and passes on its own terms -- the example still fails overall (via
#      the aggregated failure, verified empirically against this repo's
#      actual RSpec + gems), but the outer construct is misleading about what
#      it is testing, and the inner check's identity is invisible to a reader
#      of the failure it "guards". The shape that WOULD produce a true
#      silent green -- a bare `expect { }.to raise_error` (positive, no
#      class filter) wrapping a nested `expect` -- has zero occurrences in
#      this suite today; a future ratchet should watch for that one
#      specifically, not just any nesting.
#      The dominant source of `nested_expect` flags is a DIFFERENT, legitimate
#      idiom that happens to share this shape: `spec/support_matchers_spec.rb`
#      tests the custom matchers under `spec/support/matchers/` via
#      `expect { expect(x).to my_matcher }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /msg/)`
#      -- RSpec's own recommended way to assert a matcher's failure message,
#      where the nesting is required, not a bug. That file carries its own
#      `aggregate_failures: false` (see its header comment) precisely because
#      aggregation would swallow the message this pattern needs to inspect --
#      which is a better mechanical discriminator than the shape of the outer
#      matcher, for whoever builds the next refinement.
#
# REPORT-ONLY, deliberately. A planning-time crude grep found 352 raw
# `not_to raise_error` occurrences across 183 files, of which roughly 127
# looked like sole assertions -- this AST scan lands close to that (see the
# report's calibration line). A guard that FAILS the suite on day one would
# need an allowlist sized to that count, which is a disabled guard wearing a
# spec's name -- so this spec prints the report and passes. T16 consumes the
# report and, per its own AC, fixes, deletes, or documents-with-a-reason each
# entry -- NOT "delete everything on the list" (see the report's own banner:
# a 25-entry manual spot-check found most `sole_raise_error` instances assert
# something real). The intended follow-up, once the count is down, is a
# RATCHET (`count <= <ceiling>`) so a new instance costs an old one -- not a
# hard failure now, and not built here.
module SpecDiscipline
  # A single flagged example, with enough context for T16 to find and judge it.
  # `bang_call` and `raise_sibling` are only meaningful for `:sole_raise_error`
  # (nil for `:nested_expect`) -- see the Scanner doc for what each measures.
  # Neither is a verdict: both are cheap, imperfect READING signals, not a
  # replacement for opening the file. See spec/spec_discipline_spec.rb's own
  # report for the measured precision against a manual read.
  Violation = Struct.new(:path, :line, :shape, :description, :bang_call, :raise_sibling) do
    def to_s
      "#{path}:#{line} [#{shape}]#{" #{description.inspect}" if description}"
    end
  end

  # Pure AST predicates: "does this node look like shape X". Kept separate
  # from Scanner on purpose -- Scanner owns traversal and the group/example
  # scope stacks, a genuinely different responsibility from "what does this
  # one node mean", and the split is what keeps either half readable.
  module Shapes
    # `it` and `specify` are RSpec's two example-defining aliases actually
    # reachable at the top level; `example` is not used anywhere in this
    # suite as of this scan (verified: no `example do`/`example {` in spec/),
    # so it is left out rather than guessed at.
    EXAMPLE_METHODS = %i[it specify].freeze
    # `describe`/`context` bound the group a "raise_error sibling" is read
    # against. The outermost one is `RSpec.describe`; every nested one is
    # receiverless (DSL methods instance_eval'd into the block).
    GROUP_METHODS = %i[describe context].freeze
    # The matcher-invocation methods RSpec dispatches on an assertion receiver.
    MATCHER_METHODS = %i[to not_to to_not].freeze
    # The two of those three that assert absence -- "and did NOT happen" is
    # the shape `.not_to raise_error` needs to match.
    NEGATIVE_METHODS = %i[not_to to_not].freeze
    # `expect(...)`/`expect { }` is the common case; `is_expected` and
    # `expect_any_instance_of` are the other two receiver shapes a real
    # assertion in this suite is written against. Without these, a SECOND,
    # real assertion spelled either way is invisible to the "sole" count and
    # produces a false positive.
    ASSERTION_RECEIVERS = %i[expect is_expected expect_any_instance_of].freeze

    module_function

    def example?(node)
      EXAMPLE_METHODS.include?(node.name) && node.receiver.nil? && !node.block.nil?
    end

    def group?(node)
      return false unless GROUP_METHODS.include?(node.name) && node.block

      node.receiver.nil? || rspec_const?(node.receiver)
    end

    def rspec_const?(node)
      node.is_a?(Prism::ConstantReadNode) && node.name == :RSpec
    end

    def matcher_call?(node)
      MATCHER_METHODS.include?(node.name) &&
        node.receiver.is_a?(Prism::CallNode) && ASSERTION_RECEIVERS.include?(node.receiver.name)
    end

    def sole_raise_error_shape?(node)
      return false unless NEGATIVE_METHODS.include?(node.name)
      return false unless node.receiver.name == :expect && node.receiver.block

      raise_error_matcher?(node)
    end

    # The signal a SIBLING reads: this example (anywhere in its body, not
    # just its top-level assertion) asserts that something DOES raise.
    def raise_positive_call?(node)
      return false unless node.name == :to && node.receiver.name == :expect

      raise_error_matcher?(node)
    end

    def raise_error_matcher?(node)
      matcher = node.arguments&.arguments&.first
      matcher.is_a?(Prism::CallNode) && matcher.name == :raise_error
    end

    # A cheap, imperfect proxy for "this wraps a method whose job is to
    # raise": this codebase's own convention marks such methods with a `!`
    # (`check!`, `admit!`, `ensure_open!`). Scans the whole wrapped block,
    # not just its first call, since the checked method is often reached via
    # a local built earlier in the block.
    def bang_call?(assertions)
      assertions.any? { |node| node.is_a?(Prism::CallNode) && any_bang_call?(node.receiver.block) }
    end

    def any_bang_call?(node)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::CallNode) && node.name.to_s.end_with?("!")

      node.compact_child_nodes.any? { |child| any_bang_call?(child) }
    end

    def expect_call?(node)
      node.name == :expect && node.receiver.nil?
    end

    def description(node)
      first = node.arguments&.arguments&.first
      first.is_a?(Prism::StringNode) ? first.unescaped : nil
    end
  end

  # Walks one file's syntax tree collecting violations. A violation is always
  # reported at its EXAMPLE's line (the `it`/`specify` line), never a
  # containing `describe`'s -- that is the line a reader, and T16, needs.
  class Scanner
    # One example-group's (`describe`/`context`) direct children, collected
    # so a vacuous example's report can name whether a SIBLING in the SAME
    # group asserts that something raises at all -- context a flat,
    # single-pass violation list cannot carry on its own. This is a
    # CORRELATE, not proof of an accept/refuse pair: it is set when ANY
    # sibling raises about ANYTHING, so a well-tested `describe "#method"`
    # with an unrelated raising example nearby will set it for every vacuous
    # sibling in the group, whether or not the two are actually paired (see
    # the module doc's caveat on `raise_sibling`).
    # `children` holds one Hash per direct child example (named `children`,
    # not `entries`, so it does not shadow `Struct#entries`):
    #   node:    the `it` call node (line + description)
    #   vacuous: true when every assertion in it is the sole_raise_error shape
    #   bang:    vacuous AND the wrapped block calls a `!`-suffixed method
    #   raises:  this example asserts `expect { }.to raise_error(...)` ANYWHERE
    Group = Struct.new(:children)

    # One example while its subtree is walked: the `it`/`specify` node
    # itself, one entry per matcher call found (`false`, or the matcher's
    # CallNode when it is the vacuous `not_to raise_error` shape -- kept
    # rather than a bare boolean so a bang-call scan can run on it once the
    # example turns out to be all-vacuous), and whether ANY assertion in the
    # example is a positive `raise_error` check (what a SIBLING reads).
    Example = Struct.new(:node, :assertions, :raises)

    def initialize(path)
      @path = path
      @violations = []
      @example_stack = []
      @group_stack = []
      @expect_depth = 0
    end

    # @return [Array<Violation>]
    def scan(source)
      @group_stack = [Group.new([])]
      walk(Prism.parse(source).value)
      finish_group(@group_stack.pop)
      @violations
    end

    private

    def walk(node)
      return unless node.is_a?(Prism::Node)
      return walk_call(node) if node.is_a?(Prism::CallNode)

      node.compact_child_nodes.each { |child| walk(child) }
    end

    def walk_call(node)
      return walk_group(node) if Shapes.group?(node)
      return walk_example(node) if Shapes.example?(node)

      record_sole_assertion_candidate(node)
      record_nested_expect(node)
      walk_expect_children(node)
    end

    # A nested group is fully self-contained: its own direct-child examples
    # are ITS siblings, computed and turned into violations before this
    # method returns, and it never becomes an entry in the group around it --
    # only `it`s do. That is what keeps "sibling" meaning "same immediate
    # describe", not "anywhere in the file".
    def walk_group(node)
      @group_stack.push(Group.new([]))
      node.compact_child_nodes.each { |child| walk(child) }
      finish_group(@group_stack.pop)
    end

    # An example is its own scope for the vacuous-assertion count: assertions
    # found while this example is on top of the stack -- INCLUDING ones
    # nested inside an `expect { }` block, which is what stops a
    # nested-expect example (shape 2) from also being miscounted as
    # all-vacuous (its real count is two: the outer `not_to raise_error` and
    # the inner matcher RSpec never gets to report on its own).
    def walk_example(node)
      @example_stack.push(Example.new(node, [], false))
      node.compact_child_nodes.each { |child| walk(child) }
      record_example_result(@example_stack.pop)
    end

    def record_example_result(example)
      vacuous = example.assertions.any? && example.assertions.all?
      @group_stack.last.children << {
        node: example.node,
        vacuous:,
        bang: vacuous && Shapes.bang_call?(example.assertions),
        raises: example.raises
      }
    end

    # Flushes one group: every vacuous direct child becomes a Violation, with
    # `raise_sibling` true when ANY other direct child of this SAME group
    # asserts a positive `raise_error` -- SOME sibling in this describe
    # raises, often but not always the refuse half of an accept/refuse pair
    # with THIS example (see the module doc: this over-promotes for any
    # well-tested `describe` that happens to carry an unrelated raising
    # example). A vacuous entry can never itself carry `raises: true` (that
    # would require a non-vacuous assertion, which fails the `.all?` vacuous
    # check above), so there is no need to exclude the entry from its own
    # sibling check.
    def finish_group(group)
      raises_present = group.children.any? { |child| child[:raises] }
      group.children.each do |child|
        next_violation(child, raises_present) if child[:vacuous]
      end
    end

    def next_violation(child, raise_sibling)
      @violations << violation(child[:node], :sole_raise_error, bang_call: child[:bang], raise_sibling:)
    end

    def record_sole_assertion_candidate(node)
      return unless Shapes.matcher_call?(node)

      current = @example_stack.last
      return unless current

      current.assertions << (Shapes.sole_raise_error_shape?(node) ? node : false)
      current.raises = true if Shapes.raise_positive_call?(node)
    end

    def record_nested_expect(node)
      return unless Shapes.expect_call?(node) && @expect_depth.positive?

      context = @example_stack.last&.node || node
      @violations << violation(context, :nested_expect)
    end

    # `expect { }` (block form) is the only shape that can swallow a nested
    # failure, so depth only tracks block-form expects. `expect(value)` opens
    # no scope for anything to hide inside.
    def walk_expect_children(node)
      opens_scope = Shapes.expect_call?(node) && node.block
      @expect_depth += 1 if opens_scope
      node.compact_child_nodes.each { |child| walk(child) }
      @expect_depth -= 1 if opens_scope
    end

    def violation(node, shape, bang_call: nil, raise_sibling: nil)
      Violation.new(@path, node.location.start_line, shape, Shapes.description(node), bang_call, raise_sibling)
    end
  end

  module_function

  def spec_root
    Pathname(__dir__).expand_path
  end

  def source_files
    spec_root.glob("**/*.rb").sort
  end

  # @return [Array<Violation>] every violation across the whole spec/ tree.
  # NOT memoized on a module ivar (ThreadSafety/ClassInstanceVariable, and
  # this codebase's own posture on shared mutable state) -- rescanning ~620
  # files was measured at ~1s, so a caller that needs the result more than
  # once in one flow (the report, the whole-suite example) computes it ONCE
  # and threads the Array through, rather than this method hiding a cache.
  def violations
    source_files.flat_map do |file|
      relative = file.relative_path_from(spec_root.parent).to_s
      Scanner.new(relative).scan(file.read)
    end
  end

  # @return [Pathname] where {SpecDisciplineReport} writes the full listing.
  REPORT_PATH = Pathname(__dir__).join("../tmp/spec_discipline_report.txt").expand_path
end

# Turns a violation list into the human-readable report T16 consumes. A
# module separate from SpecDiscipline on purpose: scanning/detection and
# report FORMATTING are different responsibilities -- folding the second
# into the first is what pushed SpecDiscipline over Metrics/ModuleLength.
module SpecDisciplineReport
  # Splits one violation list into the buckets {.text} prints: the
  # `sole_raise_error`/`nested_expect` shapes, and each shape's own
  # read-this-first split. A named collaborator rather than six local
  # variables, so the methods that print from it take one argument, not six.
  Buckets = Struct.new(:sole, :nested, :likely, :unclear, :idiom, :buggy) do
    def self.from(list)
      sole, nested = list.partition { |v| v.shape == :sole_raise_error }
      likely, unclear = sole.partition { |v| v.bang_call || v.raise_sibling }
      idiom, buggy = nested.partition { |v| v.path.end_with?("support_matchers_spec.rb") }
      new(sole, nested, likely, unclear, idiom, buggy)
    end
  end

  BANNER = <<~TEXT
    SPEC DISCIPLINE REPORT -- generated by spec/spec_discipline_spec.rb
    Regenerate: bundle exec rspec spec/spec_discipline_spec.rb -e "prints the counts"

    ======================================================================
    THIS IS A READING LIST, NOT A DELETE LIST.
    A 25-entry manual spot-check of `sole_raise_error` (panel review) found
    roughly 88% assert something real -- most are the accepts half of an
    accept/refuse pair against a method whose job is to raise (`Surface.check!`,
    `policy.admit!`, `bounds.check_presentation!`, ...), often sitting directly
    above a "refuses ..." sibling. Measured precision against this card's
    "structurally cannot fail" intent was ~12%, not "most of the list is dead".
    T16's own AC is "fixed, deleted, or documented-with-a-reason" per entry --
    not "delete what is flagged".
    ======================================================================
  TEXT

  module_function

  # Writes {.text} to {SpecDiscipline::REPORT_PATH} and returns the path. The
  # full per-violation listing lives in a FILE, not in RSpec's own reporter
  # -- `tmp/parallel_runtime_rspec.log` captures whatever the reporter
  # prints, and hundreds of listing lines every run is exactly the
  # stray-line-breaks-a-parser hazard CLAUDE.md's Output Discipline section
  # warns about for the Journal. Only the summary counts go through
  # `RSpec.configuration.reporter.message`.
  def write(list)
    SpecDiscipline::REPORT_PATH.dirname.mkpath
    SpecDiscipline::REPORT_PATH.write(text(list))
    SpecDiscipline::REPORT_PATH
  end

  # A `sole_raise_error` violation's assertion cannot fail for the reason its
  # `it` claims to cover -- that much is structural. Whether the CHECK it
  # wraps is itself meaningless is a different question this scan cannot
  # answer by itself, so it is not asked to: `bang_call`/`raise_sibling` are
  # cheap correlates (does the wrapped call look like a validator, does SOME
  # sibling in the same describe assert that something raises at all -- often,
  # not always, the refuse half of the same pair; any well-tested `describe`
  # can carry an unrelated raising example and over-promote every vacuous one
  # beside it), printed as a READING order, never as a verdict.
  def text(list)
    buckets = Buckets.from(list)
    ([header(list, buckets)] + sections(buckets)).join("\n")
  end

  def sections(buckets)
    [
      section("sole_raise_error -- bang_call or raise_sibling detected: READ THESE FIRST", buckets.likely),
      section("sole_raise_error -- neither signal detected (still read before deleting)", buckets.unclear),
      section(
        "nested_expect -- spec/support_matchers_spec.rb (legitimate matcher-testing idiom, see module doc)",
        buckets.idiom
      ),
      section("nested_expect -- elsewhere (misleading, not swallowed -- see module doc)", buckets.buggy)
    ]
  end

  # "occurrences / distinct examples", the shape every counts row prints.
  def pair(collection)
    "#{collection.size} / #{distinct(collection)}"
  end

  def header(list, buckets)
    notes = [SpecDisciplineCuratedNotes::FALSE_UNCLEARS_NOTE, SpecDisciplineCuratedNotes::CARD_NAMED_KEEPS_NOTE]
    [BANNER, counts_block(list, buckets), calibration_block(buckets), *notes].join("\n")
  end

  def counts_block(list, buckets)
    [total_line(list), sole_counts_block(buckets), nested_counts_block(buckets)].join("\n")
  end

  def total_line(list)
    <<~TEXT
      Counts (occurrences / distinct examples -- a duplicate path:line means one
      example contains more than one flagged call):
        total: #{pair(list)}
    TEXT
  end

  def sole_counts_block(buckets)
    <<~TEXT
      sole_raise_error:  #{pair(buckets.sole)}
        bang_call or raise_sibling detected (read first): #{buckets.likely.size}
        neither signal detected:                          #{buckets.unclear.size}
    TEXT
  end

  def nested_counts_block(buckets)
    <<~TEXT
      nested_expect:     #{pair(buckets.nested)}
        spec/support_matchers_spec.rb (legitimate idiom):  #{pair(buckets.idiom)}
        elsewhere (misleading, not swallowed):             #{pair(buckets.buggy)}
    TEXT
  end

  def calibration_block(buckets)
    <<~TEXT
      Calibration: sole_raise_error landed at #{buckets.sole.size} (planning-time
      crude grep estimated ~127; the card's escalation band is ~2x, 63-254). Not
      a ratchet -- see SpecDiscipline's module doc for why this guard does not
      fail the suite.
    TEXT
  end

  def section(title, list)
    body = list.sort_by { |v| [v.path, v.line] }.map { |v| "  #{v}#{flags(v)}" }.join("\n")
    "--- #{title} (#{list.size}) ---\n#{body}\n\n"
  end

  def flags(violation)
    return "" unless violation.shape == :sole_raise_error

    tags = [("bang!" if violation.bang_call), ("raise-sibling" if violation.raise_sibling)].compact
    tags.empty? ? "" : " (#{tags.join(", ")})"
  end

  def distinct(list)
    list.map { |v| [v.path, v.line] }.uniq.size
  end
end

# Hand-curated annotations that do NOT derive from the AST -- a manual
# spot-check's findings, and the one instance the card names as a deliberate
# keep. A separate module from SpecDisciplineReport on purpose: everything
# else in that module is MECHANICALLY computed from a violation list; this
# is knowledge that only exists because a human read the code and wrote it
# down, and folding it into the mechanical report is what pushed
# SpecDisciplineReport over Metrics/ModuleLength.
module SpecDisciplineCuratedNotes
  # Read-first/unclear is an ENRICHMENT of the mechanical signals, not a
  # filter on truth -- a manual 26-entry read of "unclear" found roughly
  # 25-30% genuinely vacuous, against ~12% for the flat list. Better odds,
  # not proof. These specific entries were read and confirmed NOT vacuous;
  # T16 must not delete them on the "neither signal detected" label alone.
  FALSE_UNCLEARS_NOTE = <<~TEXT
    "Neither signal detected" means less pre-sorted, not "safe to delete"
    (keep reading each one before deleting -- see the label above, which
    stays exactly as worded on purpose). Verified NOT vacuous on a manual
    read, despite landing in "unclear":
      spec/lain/structural/queries_spec.rb:33,93,142,198
      spec/lain/mode/posture_spec.rb:113,117
      spec/lain/skill/shipped_skills_spec.rb:85
      spec/lain/sensitivity/regions_spec.rb:384,388,397,537
      spec/lain/core/child_spec.rb:103
      spec/lain/frontend/completion_spec.rb:191
      spec/lain/review/keying_spec.rb:86
      spec/lain/tools/write_file_spec.rb:38
      spec/lain/review/session_spec.rb:777
  TEXT

  # The card names ONE `sole_raise_error` instance as a deliberate KEEP
  # despite being genuinely, correctly flagged (see SpecDiscipline's module
  # doc for why it does not escape the rule by having a nearby real
  # assertion -- it doesn't have one). No allowlist file exists to encode
  # that judgment in code (the card forbids one), so it is recorded here
  # instead.
  CARD_NAMED_KEEPS_NOTE = <<~TEXT
    Card-named keeps (flagged below; keep, do not delete -- T16's
    "documented-with-a-reason" branch covers these):
      spec/support/shared_examples/review_surface.rb:242 -- one call of each
        port message inside a single expect block, kept as cheap coverage
        that the whole port survives one pass in the documented order.
  TEXT
end

# Mechanical, REPORT-ONLY guard against a SECOND shape, added by T12: a public
# method in `lib/` that no other `lib/` code ever names, and that `spec/` does.
#
# CLAUDE.md says a spec drives design and that a tripped `Metrics/*` cop means
# an object is missing. It does not yet say that a method made public SO A TEST
# CAN REACH IT is a design smell rather than a testing convenience, and most of
# this suite is LLM-written -- the circumstance that produces that shape at
# scale.
#
# == What this shape is, and the one it is NOT
#
# FLAGGED: `lib/` names it nowhere, `spec/` names it somewhere. That is a fact
# about REACH and it is all this scan measures.
#
# NOT FLAGGED, and this is the important half: a method with a real `lib/`
# caller INSIDE ITS OWN CLASS, public only so the spec can reach it directly.
# That is the likeliest spelling of "public only for a test" -- and it is
# invisible here, because a caller in `lib/` is a `lib/` reference whatever
# object it sits on. Measured on this tree at the time of writing: 145 whole-
# tree / 7 under `lib/lain/review/**` carry that shape, against 70 / 9 for the
# shape below. Reading "0 lib_public_spec_only" as "no methods are public only
# for a test" is therefore wrong, and T14's `repo_as_fixture_spec.rb` paid for
# that lesson first (its first cut missed the likeliest spelling of its own
# motivating case). Seeing that second shape needs class-scoped name
# resolution, not the flat file-scoped index below; it is deliberately left
# unbuilt rather than approximated, because the file-scoped approximation was
# measured at 4 false positives in 7 (`Delta#identical`/`#changed` and
# `Docent#conversation` resolve to a Hash-value symbol and a keyword-argument
# label, `GithubPr#refs` to a second class living in the same file).
#
# == Why report-only, and why the finding is never "make it private"
#
# T12's own audit of `lib/lain/review/**` narrowed NOTHING, and the reason is
# structural rather than local: a method with zero `lib/` callers that is made
# private becomes unreachable, so `private` here is a deletion wearing a
# smaller word. What the shape actually finds is four different things with
# four different fixes -- an unwired capability landed ahead of its consumer
# (`Review::Prefill`, whose CLASS has no `lib/` consumer either), a documented
# convenience nobody took up (`Marks#state_for`), API answered by a duck the
# scan cannot see, and genuine dead code. Only the last is a deletion, and
# CLAUDE.md puts that call with whoever owns the capability. So this prints a
# reading list, the way the shapes above it do.
#
# `unwired_owner` is the one cheap discriminator worth carrying: when the
# owning constant itself is named nowhere else in `lib/`, every flag on it is
# ONE fact about the class rather than N facts about its methods.
#
# == Known blind spots, demonstrated rather than assumed
#
#   * Dynamic dispatch. `public_send(key)` (`cache_profile.rb:51`,
#     `compare.rb:121`) reaches a method this scan will swear nothing calls.
#     A name that arrives from a Hash, a constant or the wire is not visible
#     to any static index.
#   * Non-Ruby callers. The nvim plugin and `crates/lain-core` speak over RPC;
#     a method they call is spelled in Lua or Rust, not here. Verified for
#     T12's nine review-subtree flags (none is), NOT in general.
#   * A method NAME is the key, so two methods sharing a name share their
#     references: any reference to either suppresses the flag on both. That is
#     deliberate -- it under-reports, and T14's rule states the same
#     preference, since a false positive is a permanent tax on every
#     contributor while a miss costs one line of a report.
#   * {IMPLICIT} is a hand-written list of names Ruby, RSpec or a gem invokes
#     without ever spelling them. It is certainly incomplete.
#   * `attr_reader`/`Data.define` members are not `def`s and are not scanned.
#   * String-spelled references (`define_method("foo")`) are not counted.
#   * Visibility is read per statement list, with `private :sym` overrides
#     applied per FILE. A `send(:private, ...)`, or a visibility change made
#     from another file, is not seen.
module LibReach
  REPO_ROOT = Pathname(__dir__).join("..").expand_path
  LIB_ROOT = REPO_ROOT.join("lib")
  SPEC_ROOT = REPO_ROOT.join("spec")

  # @return [Pathname] where {LibReachReport} writes the full listing.
  REPORT_PATH = REPO_ROOT.join("tmp/lib_reach_report.txt")

  # Names whose caller never spells them: Ruby's own conversion and comparison
  # protocols, the hooks `Enumerable`/`Comparable` reach through, the ones a
  # gem calls by convention (`call`, `perform`, `to_journal`), and `initialize`
  # -- `.new` is what a caller writes. Without these, every `to_s` in `lib/`
  # reads as public-only-for-a-test the moment a spec asserts on one.
  IMPLICIT = %i[
    initialize initialize_copy inspect to_s to_str to_sym to_a to_h to_i to_f to_proc to_json
    coerce hash eql? == != <=> < <= > >= === =~ + - * / % ** << >> [] []= ! ~ & | ^ each
    method_missing respond_to_missing? included extended inherited prepended
  ].freeze

  # Owners that exist BECAUSE the specs needed them, and that CLAUDE.md names
  # approvingly: `Sink::Null`, `Provider::Mock`, `Effect::Handler::Mock`,
  # `Surface::Null`. An inspection method on one of these is reached from
  # `spec/` and nowhere else BY DESIGN, so a flag on it would be this rule's
  # error rather than a finding -- T12's card says exactly that, and
  # `Provider::Mock#last_request`/`#call_count` were the two it caught.
  # Matched on the owner's last constant segment, which is a convention this
  # codebase keeps rather than a path allowlist. The cost is not hypothetical
  # and is worth writing down: measured on this tree, this shields 105 public
  # defs across 29 owners -- 26 named `Null`, 3 named `Mock`, and none at all
  # for `Fake`/`Stub`/`Double`, which are here for the convention rather than
  # for anything they match today. A real class someone names `Null` is skipped
  # in silence, and 105 is how much room that hole has.
  DOUBLE_OWNERS = %w[Mock Null Fake Stub Double].freeze

  # One public `def` in `lib/`, with the lexical constant it was written under.
  Definition = Struct.new(:path, :line, :name, :owner, :singleton) do
    def to_s = "#{owner}#{singleton ? "." : "#"}#{name}"
  end

  # One flagged definition, with the spec sites that reach it.
  Violation = Struct.new(:definition, :spec_sites, :unwired_owner) do
    def path = definition.path
    def line = definition.line
    def to_s = "#{path}:#{line} #{definition} <- #{spec_sites.first(3).join(", ")}"
  end

  # Depth-first over a Prism tree. Its own module because three objects below
  # walk one and none of them is about walking.
  module Walk
    module_function

    def each_node(node, &block)
      return to_enum(:each_node, node) unless block_given?
      return unless node.is_a?(Prism::Node)

      yield node
      node.compact_child_nodes.each { |child| each_node(child, &block) }
    end
  end

  # ONE question, asked of one file: which `def`s in it are PUBLIC?
  #
  # Visibility in Ruby is per statement list and mutable at runtime, so this is
  # a reading of the common written forms and not an evaluation: a bare
  # `private`/`protected`/`public` sets the default for the statements after it
  # in the SAME list, `private def x` and `private :x` name one method, and
  # `private_class_method` does the same for a singleton. `module_function`
  # counts as PUBLIC -- the instance copy goes private but `Mod.name` stays
  # reachable, which is the reach this scan is about.
  class Visibility
    # Receiverless calls that change what the REST of a statement list means.
    BARE = %i[public private protected module_function].freeze

    # The two facts a statement list carries forward to the next `def` in it.
    # `singleton` is not redundant with `def self.x`: a `class << self` body and
    # a bare `module_function` both move a plainly-spelled `def` onto the
    # singleton, and without tracking it the report renders `Owner#name` for a
    # method every caller writes as `Owner.name` -- 3 of 70 entries, one of them
    # `Review::Prefill::Sidecar.beside`.
    State = Struct.new(:visibility, :singleton)

    def self.public_defs(path, source)
      new(path).run(Prism.parse(source).value)
    end

    def initialize(path)
      @path = path
      @defs = []
      @overrides = {}
    end

    # @return [Array<Definition>]
    def run(root)
      scope(root, "", false)
      @defs.select { |defn, vis| (@overrides[defn.name] || vis) == :public }.map(&:first)
    end

    private

    # Walks ONE statement list under `owner`. Every list starts public --
    # visibility does not inherit -- while `singleton` is a property of the list
    # its caller opened.
    def scope(node, owner, singleton)
      state = State.new(:public, singleton)
      statements(node).each { |stmt| state = statement(stmt, owner, state) }
    end

    # A `ProgramNode` keeps its list under `statements`; every other node that
    # opens one -- class, module, `class << self`, a block -- keeps it under
    # `body`. Anything else has no list of its own and is walked by {#descend}.
    def statements(node)
      body = node.is_a?(Prism::ProgramNode) ? node.statements : node.body
      body.is_a?(Prism::StatementsNode) ? body.body : []
    end

    def statement(stmt, owner, state)
      case stmt
      when Prism::DefNode then record(stmt, owner, state)
      when Prism::ClassNode, Prism::ModuleNode then scope(stmt, join(owner, const_name(stmt.constant_path)), false)
      when Prism::SingletonClassNode then scope(stmt, owner, true)
      when Prism::CallNode then return call(stmt, owner, state)
      when Prism::ConstantWriteNode then constant(stmt, owner, state)
      else descend(stmt, owner, state)
      end
      state
    end

    # `Widget = Data.define(...) do ... end` is how this codebase writes a value
    # object: the block IS Widget's class body, and the constant on the left is
    # the name a reader looks the method up under.
    def constant(stmt, owner, state)
      statement(stmt.value, join(owner, stmt.name.to_s), state)
    end

    # An `if`/`begin`/`case` does not open a visibility scope, so its branches
    # keep reading the list they are written in.
    def descend(stmt, owner, state)
      Walk.each_node(stmt) do |node|
        case node
        when Prism::DefNode then record(node, owner, state)
        when Prism::ClassNode, Prism::ModuleNode then scope(node, join(owner, const_name(node.constant_path)), false)
        end
      end
    end

    # `Data.define(...) do ... end` and `Struct.new do ... end` open a class
    # body written as a block, and this codebase's value objects all take that
    # shape -- so a block body is walked as its own statement list.
    def call(stmt, owner, state)
      return bare(stmt, owner, state) if stmt.receiver.nil? && BARE.include?(stmt.name)

      class_methods(stmt, owner) if stmt.receiver.nil? && stmt.name == :private_class_method
      scope(stmt.block, owner, state.singleton) if stmt.block.is_a?(Prism::BlockNode)
      state
    end

    # `private`/`protected`/`public` with no argument set the list's visibility;
    # a bare `module_function` moves the rest of the list onto the singleton,
    # where `Mod.name` is the reach this scan is about. With arguments, all four
    # name specific methods instead and the list's own state is unchanged --
    # `module_function :x` is deliberately not followed, since the instance copy
    # it also makes private is not what a `spec/` caller reaches.
    def bare(stmt, owner, state)
      args = stmt.arguments&.arguments || []
      return named(stmt, owner, state, args) unless args.empty?

      stmt.name == :module_function ? State.new(state.visibility, true) : State.new(stmt.name, state.singleton)
    end

    def named(stmt, owner, state, args)
      args.each { |arg| name(arg, owner, stmt.name) } unless stmt.name == :module_function
      state
    end

    def class_methods(stmt, owner)
      (stmt.arguments&.arguments || []).each { |arg| name(arg, owner, :private) }
    end

    # An override is keyed by NAME alone, so `private_class_method :x` also
    # silences an instance method spelled `x` in the same file. Harmless here
    # (it can only under-report, which is this rule's chosen direction) and
    # cheaper than a second key nothing else needs.
    def name(arg, owner, visibility)
      case arg
      when Prism::DefNode then record(arg, owner, State.new(visibility, false))
      when Prism::SymbolNode then @overrides[arg.unescaped.to_sym] = visibility
      end
    end

    def record(defn, owner, state)
      return if IMPLICIT.include?(defn.name)

      singleton = state.singleton || !defn.receiver.nil?
      @defs << [Definition.new(@path, defn.location.start_line, defn.name, owner, singleton), state.visibility]
    end

    def join(outer, inner) = outer.empty? ? inner : "#{outer}::#{inner}"

    def const_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then [const_name(node.parent), node.name].compact.join("::")
      else "?"
      end
    end
  end

  # Every NAME one tree spells, and where. A method name is spelled by a call
  # (`foo`, `x.foo`) or by a Symbol (`send(:foo)`, `def_delegators ... :foo`,
  # `method(:foo)`) -- both count, generously, because an over-counted
  # reference costs a missing report line while an under-counted one costs a
  # false positive, and T14's rule made the same trade.
  class Index
    METHOD_NAME = /\A[A-Za-z_][A-Za-z0-9_]*[?!=]?\z/

    def self.build(sources)
      sources.each_with_object(new) { |(path, source), index| index.add(path, source) }
    end

    def initialize
      @methods = Hash.new { |hash, key| hash[key] = [] }
      @constants = Hash.new { |hash, key| hash[key] = [] }
      @homes = Hash.new { |hash, key| hash[key] = [] }
    end

    attr_reader :methods, :constants, :homes

    def add(path, source)
      Walk.each_node(Prism.parse(source).value) do |node|
        named(node, "#{path}:#{node.location.start_line}")
        home(node, path)
      end
    end

    private

    # What this node SPELLS, which is the question the flag is about.
    def named(node, site)
      case node
      when Prism::CallNode then @methods[node.name] << site
      when Prism::SymbolNode then symbol(node, site)
      when Prism::ConstantReadNode then @constants[node.name] << site
      when Prism::ConstantPathNode then @constants[node.name] << site if node.name
      end
    end

    def symbol(node, site)
      value = node.unescaped
      @methods[value.to_sym] << site if value.match?(METHOD_NAME)
    end

    # Where a constant is OPENED, as opposed to merely named. A namespace with
    # its own directory is opened in every file under it (`Review::Prefill` in
    # `prefill.rb`, `prefill/finding.rb`, `prefill/sidecar.rb`), and counting
    # only the file that happens to define a flagged method left every such
    # class reading as wired.
    def home(node, path)
      case node
      when Prism::ClassNode, Prism::ModuleNode then @homes[node.constant_path.name] << path
      when Prism::ConstantWriteNode then @homes[node.name] << path
      end
    end
  end

  # Combines the three indexes into the verdict. Its own object so the rule can
  # be exercised against in-memory fixtures -- reading the real tree is what
  # {LibReach.violations} does, and it is not a precondition for testing this.
  class Scanner
    def initialize(lib_sources, spec_sources)
      @definitions = lib_sources.flat_map { |path, source| Visibility.public_defs(path, source) }
      @lib = Index.build(lib_sources)
      @spec = Index.build(spec_sources)
    end

    # @return [Array<Violation>]
    def violations
      @definitions.reject { |defn| @lib.methods.key?(defn.name) || double?(defn) }
                  .filter_map { |defn| violation(defn) if @spec.methods.key?(defn.name) }
                  .sort_by { |flagged| [flagged.path, flagged.line] }
    end

    private

    def violation(defn)
      Violation.new(defn, @spec.methods.fetch(defn.name), unwired?(defn))
    end

    def double?(defn) = DOUBLE_OWNERS.include?(defn.owner.split("::").last)

    # The owning constant's own last segment, named nowhere in `lib/` outside
    # the files that OPEN it. `Review::Prefill` is the motivating case: the
    # class has no `lib/` consumer at all, so each of its flagged methods is
    # one consequence of that and not an independent finding.
    #
    # File-granular, so a nested helper used only by the class it is written
    # under (`Timeline::Dominators`) reads as unwired too -- true as stated,
    # and still the wrong word for what it is. Asking this per CLASS rather
    # than per file needs the scoped resolution LibReach's doc declines to
    # approximate.
    def unwired?(defn)
      owner = defn.owner.split("::").last
      return false if owner.nil? || owner.empty?

      homes = @lib.homes.fetch(owner.to_sym, [])
      @lib.constants.fetch(owner.to_sym, []).all? { |site| homes.include?(site.split(":").first) }
    end
  end

  module_function

  def sources(root)
    root.glob("**/*.rb").sort.to_h { |file| [file.relative_path_from(REPO_ROOT).to_s, file.read] }
  end

  # @return [Array<Violation>] every flagged definition across the real tree.
  # Not memoized, for the reason {SpecDiscipline.violations} is not.
  def violations
    Scanner.new(sources(LIB_ROOT), sources(SPEC_ROOT)).violations
  end
end

# Turns a {LibReach} violation list into the reading list a follow-up consumes.
# Separate from the scan for the reason {SpecDisciplineReport} is separate from
# {SpecDiscipline}: detection and formatting are different responsibilities,
# and folding the second into the first is what pushes either over
# `Metrics/ModuleLength`.
module LibReachReport
  BANNER = <<~TEXT
    LIB REACH REPORT -- generated by spec/spec_discipline_spec.rb
    Regenerate: bundle exec rspec spec/spec_discipline_spec.rb -e "lib reach"

    ======================================================================
    THIS IS A READING LIST, NOT A DELETE LIST, AND NOT A `private` LIST.
    A flagged method has NO caller in lib/ at all, so making it private makes
    it unreachable -- `private` here is a deletion wearing a smaller word.
    T12's audit of lib/lain/review/** applied ZERO narrowings for that reason;
    see LibReach's own doc for the four different things this shape finds and
    the four different fixes they need.

    It also CANNOT see the likeliest spelling of "public only for a test" --
    a method with a real caller inside its own class. Read "0 flagged" as
    "nothing has zero lib callers", never as "nothing is public only for a
    test".

    THREE FAMILIES BELOW ARE LEGITIMATE AND DOMINATE THE LIST. Narrowing any
    of them is a defect, not a cleanup (T12's card names all three):
      * property-test law counterexamples -- `Algebra::Monoid#not_a_monoid`,
        `Algebra::Pure#not_pure` and their siblings exist to be called by a
        spec; that is their whole job.
      * alternative constructors -- `Question::Answer.from_body`,
        `Approval::Gate.from_journal`, `CLI::Up.from_options`: public API by
        intent even when only a spec exercises them today.
      * documented algebra predicates -- `Timeline#ancestor_of?`,
        `Timeline::Dominators#dominates?` are the DAG's public vocabulary.
    Injected collaborators and Null Objects are EXCLUDED rather than listed,
    since a flag on one is the rule's error -- see LibReach::DOUBLE_OWNERS.

    MEASURED PRECISION, stated the way the sibling shape states its own:
    T12 read all 9 flags under lib/lain/review/** and narrowed ZERO. Against
    the card's intent -- "a method public only for a test, which should be
    private" -- that is 0/9. The flags were not noise: each named a real fact
    (an unwired class, a convenience nobody took up, editor-facing API), but
    ONE FLAG CAN STAND FOR SEVERAL DIFFERENT FINDINGS with different fixes,
    which is the same conflation the sole_raise_error report carries at ~12%.
    Read a flag as "go look", never as "narrow this".
    ======================================================================
  TEXT

  module_function

  def write(list)
    LibReach::REPORT_PATH.dirname.mkpath
    LibReach::REPORT_PATH.write(text(list))
    LibReach::REPORT_PATH
  end

  def text(list)
    unwired, standalone = list.partition(&:unwired_owner)
    ([BANNER, counts(list, unwired, standalone)] + sections(unwired, standalone)).join("\n")
  end

  def counts(list, unwired, standalone)
    <<~TEXT
      Counts:
        total flagged: #{list.size}
        owner has no lib/ consumer either (ONE fact about the class): #{unwired.size}
        owner IS used from lib/, this method is not:                  #{standalone.size}
    TEXT
  end

  def sections(unwired, standalone)
    [
      section("owner IS wired into lib/, but this method has no lib/ caller: READ THESE FIRST", standalone),
      section("owner has no lib/ consumer either -- read the CLASS, not the method", unwired)
    ]
  end

  def section(title, list)
    body = list.map { |flagged| "  #{flagged}" }.join("\n")
    "--- #{title} (#{list.size}) ---\n#{body}\n\n"
  end
end

RSpec.describe "spec discipline" do
  describe SpecDiscipline::Scanner do
    def scan(source) = described_class.new("fixture_spec.rb").scan(source)

    it "flags an example whose sole assertion is expect { }.not_to raise_error" do
      source = <<~RUBY
        it "does not raise" do
          expect { subject.call }.not_to raise_error
        end
      RUBY

      found = scan(source)

      expect(found.size).to eq(1)
      expect(found.first.shape).to eq(:sole_raise_error)
      expect(found.first.line).to eq(1)
    end

    it "flags the same shape spelled with .to_not" do
      found = scan(<<~RUBY)
        it "does not raise, spelled the other way" do
          expect { subject.call }.to_not raise_error
        end
      RUBY

      expect(found.map(&:shape)).to eq([:sole_raise_error])
    end

    it "flags a nested expect inside an expect block" do
      source = <<~RUBY
        it "answers an Integer without raising" do
          expect { expect(subject.call).to be_a(Integer) }.not_to raise_error
        end
      RUBY

      found = scan(source)

      expect(found.map(&:shape)).to eq([:nested_expect])
    end

    it "does not ALSO flag the nested-expect example as a sole raise_error assertion" do
      # The nested inner matcher counts toward this example's assertion total,
      # so it is not "sole" by count -- shape 2 is what catches it, not shape 1.
      found = scan(<<~RUBY)
        it "answers an Integer without raising" do
          expect { expect(subject.call).to be_a(Integer) }.not_to raise_error
        end
      RUBY

      expect(found.map(&:shape)).not_to include(:sole_raise_error)
    end

    it "does not flag expect { }.not_to raise_error beside a real assertion" do
      source = <<~RUBY
        it "computes the value and does not raise" do
          expect { subject.call }.not_to raise_error
          expect(subject.result).to eq(42)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "does not flag a healthy example asserting an observable outcome" do
      source = <<~RUBY
        it "returns the computed total" do
          expect(subject.total).to eq(7)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "does not flag expect { }.to raise_error (asserting that it DOES raise)" do
      source = <<~RUBY
        it "raises for an invalid argument" do
          expect { subject.call(nil) }.to raise_error(ArgumentError)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "does not flag a pending example with no block" do
      expect(scan(%(it "is not written yet"\n))).to be_empty
    end

    it "reports the example's own line, not a nested one" do
      source = <<~RUBY
        describe "wrapper" do
          it "does not raise" do
            expect { subject.call }.not_to raise_error
          end
        end
      RUBY

      expect(scan(source).first.line).to eq(2)
    end

    it "carries the example's description for a readable report" do
      found = scan(<<~RUBY)
        it "is the Null channel, so a caller never has to guard `if journal`" do
          expect { subject.call }.not_to raise_error
        end
      RUBY

      expect(found.first.description).to eq("is the Null channel, so a caller never has to guard `if journal`")
    end

    it "flags an example whose only assertions are two vacuous not_to raise_error calls" do
      source = <<~RUBY
        it "never raises either way" do
          expect { subject.a }.not_to raise_error
          expect { subject.b }.not_to raise_error
        end
      RUBY

      found = scan(source)

      expect(found.map(&:shape)).to eq([:sole_raise_error])
    end

    it "recognises is_expected.to as a real assertion beside a raise_error smoke check" do
      source = <<~RUBY
        it "computes the value and does not raise" do
          expect { subject.call }.not_to raise_error
          is_expected.to eq(42)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "recognises expect_any_instance_of(...).to as a real assertion beside a raise_error smoke check" do
      source = <<~RUBY
        it "delegates without raising" do
          expect { subject.call }.not_to raise_error
          expect_any_instance_of(Logger).to receive(:info)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "flags a bang-suffixed check inside the block as a likely-meaningful sole assertion" do
      source = <<~RUBY
        it "refuses when the budget is exceeded" do
          expect { budget.check_tokens!(200) }.not_to raise_error
        end
      RUBY

      expect(scan(source).first.bang_call).to be(true)
    end

    it "does not flag bang_call when the wrapped call has no bang" do
      source = <<~RUBY
        it "is idempotent on close" do
          expect { journal.close }.not_to raise_error
        end
      RUBY

      expect(scan(source).first.bang_call).to be(false)
    end

    it "flags raise_sibling when a sibling example in the same describe asserts raise_error" do
      source = <<~RUBY
        describe "#check!" do
          it "accepts a valid value" do
            expect { subject.check!(1) }.not_to raise_error
          end

          it "refuses an invalid value" do
            expect { subject.check!(-1) }.to raise_error(ArgumentError)
          end
        end
      RUBY

      accepts = scan(source).find { |v| v.shape == :sole_raise_error }

      expect(accepts.raise_sibling).to be(true)
    end

    it "does not flag raise_sibling when no sibling in the same describe raises" do
      source = <<~RUBY
        describe "#close" do
          it "is idempotent on close" do
            expect { journal.close }.not_to raise_error
          end
        end
      RUBY

      expect(scan(source).first.raise_sibling).to be(false)
    end

    it "does not credit a raising example in a DIFFERENT nested context as a sibling" do
      source = <<~RUBY
        describe "Foo" do
          context "accepts" do
            it "accepts nothing new" do
              expect { subject.check!(1) }.not_to raise_error
            end
          end

          context "refuses" do
            it "refuses bad input" do
              expect { subject.check!(-1) }.to raise_error(ArgumentError)
            end
          end
        end
      RUBY

      accepts = scan(source).find { |v| v.shape == :sole_raise_error }

      expect(accepts.raise_sibling).to be(false)
    end
  end

  describe "the whole suite" do
    # REPORT-ONLY, and genuinely so: no assertion here can fail on the
    # COUNT. A prior draft asserted `be_between(63, 254)` and `not_to
    # be_empty` over `SpecDiscipline.violations.size` -- both a ratchet AND
    # an anti-ratchet on a number whose entire purpose is to move, which
    # trips the instant T16 succeeds (pruning brings the count under 63) or
    # the suite grows past double (over 254). The card is explicit that a
    # ratchet, if wanted, is a SEPARATE follow-up (`count <= <ceiling>`) once
    # the count is down -- not built here. Calibration against the
    # planning-time estimate is informational now, printed in the report
    # header, not asserted.
    #
    # This is the one place the guard touches the terminal, and it is a
    # spec, not a lib/ file -- output_discipline_spec.rb's own ALLOWLIST
    # comment names that split. Only the SUMMARY counts go through RSpec's
    # reporter; the full per-violation listing goes to its own file (see
    # SpecDiscipline::REPORT_PATH) so a parallel run's runtime log does not
    # grow by a couple hundred lines every pass.
    it "prints the counts by shape and writes the full report to a file" do
      violations = SpecDiscipline.violations
      by_shape = violations.group_by(&:shape).transform_values(&:size)
      RSpec.configuration.reporter.message(
        "spec discipline: #{violations.size} flagged example(s) -- #{by_shape.inspect} " \
        "(full listing: #{SpecDiscipline::REPORT_PATH})"
      )

      report_path = SpecDisciplineReport.write(violations)
      listed = File.readlines(report_path).grep(/\[(sole_raise_error|nested_expect)\]/).size

      # Not vacuous: this fails if the report-writing path drops an entry
      # (a `partition` bug, a section never rendered) even though the
      # violations themselves are unaffected -- the one place THIS spec
      # checks its own output rather than just producing it.
      expect(listed).to eq(violations.size)
    end
  end

  describe LibReach::Scanner do
    def scan(lib, spec = {}) = described_class.new(lib, spec).violations

    let(:consumer) { { "lib/consumer.rb" => "class Consumer\n  def run = Widget.new.total\nend\n" } }

    it "flags a public lib method that only spec names" do
      found = scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" },
                   { "spec/widget_spec.rb" => "it('x') { expect(Widget.new.total).to eq(1) }\n" })

      expect(found.map { |v| v.definition.to_s }).to eq(["Widget#total"])
      expect(found.first.line).to eq(2)
    end

    it "does not flag a method another lib file calls" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" }.merge(consumer)

      expect(scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })).to be_empty
    end

    it "does not flag a method nothing names at all -- unreached is a different finding" do
      expect(scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" })).to be_empty
    end

    it "counts a Symbol in lib as a reference, so send/delegation does not read as spec-only" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n",
              "lib/proxy.rb" => "class Proxy\n  def call(w) = w.public_send(:total)\nend\n" }

      expect(scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })).to be_empty
    end

    it "does not flag a method the file already made private" do
      source = "class Widget\n  private\n\n  def total = 1\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.send(:total)\n" })).to be_empty
    end

    it "does not flag `private def`" do
      source = "class Widget\n  private def total = 1\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.send(:total)\n" })).to be_empty
    end

    it "does not flag a name listed by private_class_method" do
      source = "class Widget\n  def self.total = 1\n  private_class_method :total\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "described_class.total\n" })).to be_empty
    end

    it "reads `public` as reopening the default after a `private` section" do
      source = "class Widget\n  private\n\n  def hidden = 1\n\n  public\n\n  def total = 2\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.total\nsubject.hidden\n" })

      expect(found.map { |v| v.definition.name }).to eq([:total])
    end

    it "reads a Data.define block as a class body, so its `private` section is honoured" do
      source = "Widget = Data.define(:n) do\n  def total = 1\n\n  private\n\n  def hidden = 2\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.total\nsubject.hidden\n" })

      expect(found.map { |v| v.definition.name }).to eq([:total])
    end

    it "does not flag a name Ruby invokes without spelling it" do
      source = "class Widget\n  def to_s = 'w'\n  def each = nil\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "expect(subject.to_s).to eq('w')\n" }))
        .to be_empty
    end

    it "shares references between two methods of the same name, so either reference clears both" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n",
              "lib/gadget.rb" => "class Gadget\n  def total = 2\nend\n",
              "lib/consumer.rb" => "class Consumer\n  def run = Gadget.new.total\nend\n" }

      expect(scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })).to be_empty
    end

    it "renders a `class << self` def as a singleton, the way a caller spells it" do
      source = "class Widget\n  class << self\n    def total = 1\n  end\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "described_class.total\n" })

      expect(found.map { |v| v.definition.to_s }).to eq(["Widget.total"])
    end

    it "honours a `private` section inside `class << self`" do
      source = "class Widget\n  class << self\n    private\n\n    def total = 1\n  end\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "described_class.send(:total)\n" }))
        .to be_empty
    end

    it "renders a def after a bare `module_function` as a singleton" do
      source = "module Widget\n  module_function\n\n  def total = 1\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "Widget.total\n" })

      expect(found.map { |v| v.definition.to_s }).to eq(["Widget.total"])
    end

    it "does not flag a protected method -- it is not part of the public interface either" do
      source = "class Widget\n  protected\n\n  def total = 1\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.send(:total)\n" })).to be_empty
    end

    it "does not flag an inspection method on a test double, which the specs are why it exists" do
      source = "module Provider\n  class Mock\n    def call_count = 1\n  end\nend\n"

      expect(scan({ "lib/mock.rb" => source }, { "spec/mock_spec.rb" => "expect(subject.call_count).to eq(1)\n" }))
        .to be_empty
    end

    it "tags unwired_owner when the owning constant has no lib consumer either" do
      found = scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" },
                   { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })

      expect(found.first.unwired_owner).to be(true)
    end

    it "does not tag unwired_owner when lib names the class somewhere else" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n",
              "lib/consumer.rb" => "class Consumer\n  def run = Widget.new\nend\n" }
      found = scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })

      expect(found.first.unwired_owner).to be(false)
    end

    it "names the spec sites that reach it, so the reading list needs no second search" do
      found = scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" },
                   { "spec/widget_spec.rb" => "\n\nexpect(Widget.new.total).to eq(1)\n" })

      expect(found.first.spec_sites).to include("spec/widget_spec.rb:3")
    end
  end

  describe "lib reach across the whole tree" do
    # REPORT-ONLY, and genuinely so -- no assertion here can fail on the COUNT,
    # for the reason the sibling example above states. What IS asserted is that
    # the report renders every violation it was handed, which fails if the
    # `partition` into wired/unwired ever drops one.
    it "prints the lib-reach counts and writes the full report to a file" do
      violations = LibReach.violations
      unwired = violations.count(&:unwired_owner)
      RSpec.configuration.reporter.message(
        "lib reach: #{violations.size} public lib method(s) named only from spec/ " \
        "(#{unwired} on a class lib/ never names either -- full listing: #{LibReach::REPORT_PATH})"
      )

      listed = File.readlines(LibReachReport.write(violations)).grep(%r{^  lib/.*:\d+ }).size

      expect(listed).to eq(violations.size)
    end
  end
end
