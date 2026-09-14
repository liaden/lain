# frozen_string_literal: true

require "pathname"
require "tmpdir"

# The chunk's constraint, mechanised: parts of the review surface that do not
# work out must be EASY TO DELETE, and a plan that says so and a suite that
# proves it are different things. It has since outgrown that one chunk --
# a unit a later audit found unreachable and deliberately left standing is the
# same claim wanting the same proof -- so each row names the plan that decided
# it.
#
# == Why a reference sweep alone is not the proof
#
# A sweep shows nothing points at a capability. It does not show the tree still
# LOADS without it, and the two failures are not the same shape: a dangling
# `require_relative` is a LoadError at boot, and a constant read in a class body
# is a NameError at boot -- neither of which any amount of grepping for a
# constant NAME finds, because the name is exactly what is gone. So each row
# here is also booted with its files removed; the negative control below
# proves the NameError shape specifically, over a synthetic pair rather than a
# real row, because a real row is deletable by definition and the control has
# to outlive the one it borrows.
#
# == What the map promises, and what it does not
#
# It promises each row is TRUE OF THE TREE: the paths exist, the markers are
# still where the row says they are, the capability's constants are defined
# inside the row rather than beside it, no file outside the row names them in
# code, and the tree boots with the row removed.
#
# It does not promise the map is COMPLETE, in either of the two senses that
# could be meant. A row's `edits` list is checked for staleness and never for
# completeness -- a site nobody wrote down stays green while leaving whoever
# deleted the capability with a file still talking to it. And the SET OF ROWS
# is hand-written: a unit that fell out of reach last month is simply not here,
# and nothing in this file can notice that it is missing.
#
# Both gaps have the same fix and it is not a spec. Deriving the row set means
# a whole-tree parse resolving constants to QUALIFIED paths -- anything
# matching leaf names reports live files as dead, which is how `Oracle::Router`
# gets confused with `Frontend::Neovim::Router` -- and a check that expensive
# is one that gets `--tag '~seam'`-ed out within a week, which is the argument
# the section above already makes against the cheaper delete-and-run.
# `bin/comment-census` is the established shape for a worklist a human runs on
# demand. Until something like it exists for reachability, a row gets here the
# way every row here got here: somebody audited the tree and wrote one.
#
# == And why the boot is not the whole proof either
#
# Booting is not running the suite. The full delete-and-run -- copy the tree,
# apply the whole row, `rake pspec`, score the example count -- is what actually
# means what §Intent claims, and it was performed by hand for every row at
# b3fbada (see the handback note for the counts). It is not shipped HERE
# because it costs a full suite per row: measured at ~36s each, ~4 minutes for
# the six, against a 44s wall for the whole suite. A check that multiplies the
# suite by five is a check that gets `--tag '~seam'`-ed out within a week, and a
# check nobody runs is worse than an honest cheaper one. What is shipped is:
# the map is true of the tree, nothing outside a row names the capability, and
# the tree boots without it. Stated plainly so nobody reads the delete-and-run's
# promise into it -- in particular, a spec that exercises a capability WITHOUT
# naming its constant is invisible to everything here.
#
# == The map has been wrong twice, which is the whole argument for this file
#
# Its lua modules were named without their numeric prefixes; four rows omitted
# the Ruby `require` line that loads them; and the GitHub-submit row said three
# sites where the tree has ten. Each was found by a human, none by a test. Every
# example below is written to be the one that would have caught one of those:
# {DeletionMap} rows carry the literal MARKER each edit site must contain, so a
# path or a line that has drifted fails by name rather than by silence.
#
# Note the asymmetry the rows record: a **lua** module has no require line at
# all -- the runtime loader globs the directory, so deleting the file is the whole edit
# -- while every **Ruby** unit has exactly one.

# One deletable capability, as one row of the map.
#
# `files` are deleted outright. `consumers` are files OUTSIDE the capability that
# name its constants in code and must be edited; the sweep pins that list
# exactly, so a new consumer is a red example rather than a silent extra site.
# `edits` are files that must change but do NOT name a constant -- a require
# path, a role symbol, a manual stanza -- so nothing but a literal marker can
# find them. `forces` is the nesting the plan records as data. `plan` is the
# planning document that decided this row was deletable, so a reader can find
# the reasoning rather than the verdict alone. `untestable` names, in words,
# why a row is exempt from the examples that need files.
Capability = Data.define(:key, :constants, :files, :consumers, :edits, :forces, :plan, :untestable) do
  def own = files
  def edited = edits.keys
  def paths = files + consumers + edits.keys
  def testable? = untestable.nil?
end

module DeletionMap
  # The two plans whose rows this map carries. The review surface's rows are
  # the ones its own `## Deletion map` table is pinned against below; the
  # verified-deletions plan ships no such table, which is why `plan` is a
  # field rather than an assumption.
  REVIEW_SURFACE = "planning/specs/chunk-review-surface.md"
  VERIFIED_DELETIONS = "planning/specs/simplify-03-verified-deletions.md"

  # Every message BOTH review commands reach the outbox through, named once
  # because the two rows below would otherwise drift apart one marker at a time
  # -- which is the failure this whole map is written against. `/survey` adds
  # `@outbox.open?` to it and nothing else does.
  OUTBOX_REACH = %w[outbox: @outbox.hold @outbox.held_source @outbox.held_verdict @outbox.target].freeze

  # The rows. A Ruby unit's `require` line is spelled here as it appears in the
  # file, because a dangling `require_relative` is a LoadError rather than a
  # missing feature and only a literal finds it.
  CAPABILITIES = [
    Capability.new(
      key: "thread",
      constants: %w[ThreadView],
      # Two spec files, because the pane has two halves: the editor's, which needs a
      # real nvim, and the view's, which does not. The recorder in `spec/support/`
      # is the capability's own fixture and goes with them -- neither sweep can see
      # it, since its name carries none of the capability's words.
      files: ["lib/lain/frontend/neovim/runtime/51_thread.lua", "lib/lain/frontend/neovim/thread_view.rb",
              "spec/lain/frontend/neovim/runtime/51_thread_spec.rb",
              "spec/lain/frontend/neovim/thread_view_spec.rb", "spec/support/recording_thread_inlet.rb"],
      # `#annotate` and `#thread` are the PORT's messages, so they survive the
      # pane and have to BECOME something -- deleting the pane is a rewrite here,
      # not a removal, which is the one thing the plan's "annotations still work"
      # does not say.
      consumers: ["lib/lain/review/surface/neovim.rb", "spec/lain/review/surface/neovim_spec.rb"],
      edits: {
        # Down from four markers to one: the other three named the protocol-9
        # changelog entry and the two examples that swept it, and the changelog
        # went when the handshake token stopped being a hand-maintained integer.
        "lib/lain/frontend/neovim.rb" => ['require_relative "neovim/thread_view"'],
        "plugin/nvim/doc/lain.txt" => ["*:LainThread*", "*lain://thread*"]
      },
      forces: %w[docent], plan: REVIEW_SURFACE, untestable: nil
    ),
    Capability.new(
      key: "docent", constants: %w[Docent],
      files: ["lib/lain/review/docent.rb", "lib/lain/prompt/templates/role/diff-docent.md",
              "spec/lain/review/docent_spec.rb"],
      # The two review COMMANDS joined the row when the capability stopped being
      # unreachable: each builds the docent off the editor's own surface, its
      # answerer off the run's role spawn and its journal off the chat's
      # chronicle, and each falls back to `Handover::Unattended` where the
      # surface has no thread pane. Their specs come with them -- both drive the
      # docent by name.
      consumers: ["lib/lain/cli/command/review.rb", "lib/lain/cli/command/survey.rb",
                  "lib/lain/cli/wiring/toolset_build.rb", "spec/lain/cli/command/survey_spec.rb",
                  "spec/lain/cli/wiring/toolset_build_spec.rb"],
      edits: {
        "lib/lain/review.rb" => ['require_relative "review/docent"'],
        # The catalog and the shipped templates are pinned equal in BOTH
        # directions, so a template without its catalog entry is a red spec and
        # a catalog entry without its roll-call name is another.
        "lib/lain/role/catalog.rb" => ["Role.new(name: :diff_docent"],
        "spec/lain/role_spec.rb" => [":merge_resolver, :diff_docent"]
      }, forces: [], plan: REVIEW_SURFACE, untestable: nil
    ),
    Capability.new(
      key: "submit",
      constants: %w[Submit REVIEW_SUBMIT submit_review],
      # The reach was added later -- the outbox, the verb and their specs; and
      # `endpoint.rb` builds only a review POST's own REST path, so it goes too.
      files: ["lib/lain/review/submit.rb", "lib/lain/review/submit/outbox.rb", "spec/lain/review/submit_spec.rb",
              "spec/lain/review/submit/outbox_spec.rb", "lib/lain/cli/command/review_submit.rb",
              "spec/lain/cli/command/review_submit_spec.rb", "lib/lain/forge/gh/endpoint.rb"],
      consumers: ["lib/lain/forge/gh.rb", "lib/lain/forge/gh/recorded.rb", "lib/lain/forge/intent.rb",
                  "lib/lain/forge/journaled.rb", "lib/lain/forge/reconcile.rb", "spec/lain/forge/gh_spec.rb",
                  "lib/lain/cli/command/surface.rb", "spec/lain/cli/command/review_spec.rb",
                  "spec/lain/cli/command/survey_spec.rb", "spec/lain/seams/survey_subdirectory_spec.rb",
                  "spec/lain/forge/gh/recorded_spec.rb", "spec/support/shared_examples/gh_parity.rb",
                  "spec/lain/cli/command/introspect_spec.rb"],
      edits: {
        "lib/lain/review.rb" => ['require_relative "review/submit"'],
        "lib/lain/forge/gh.rb" => ['require_relative "gh/endpoint"'],
        "lib/lain/cli/command.rb" => ['require_relative "command/review_submit"'],
        # FIVE sites the constant sweep is blind to: two spell the verb as the
        # wire STRING, one is the command set pinned as a LITERAL (the wiring
        # examples beside it go too), and BOTH review commands reach the outbox
        # through keywords and messages that name no constant at all. `/survey`
        # is the heavier of the two -- it holds a round AND reads the held
        # round's kind and VERDICT back to refuse a second review surface over a
        # round still awaiting judgement -- and this list is checked for
        # STALENESS only, never for completeness, so an omitted row stays green
        # while leaving a human who deleted the capability with a file still
        # talking to it.
        "lib/lain/cli/command/review.rb" => OUTBOX_REACH,
        "lib/lain/cli/command/survey.rb" => OUTBOX_REACH + ["@outbox.open?"],
        # A THIRD outbox reader, and the only one that neither opens a round nor
        # posts one: `/introspect` REPORTS the held round at the prompt. It names
        # no constant of this capability in code, so the sweep is blind to it and
        # only these literals find it -- `annotation_count` among them, since
        # that reader exists for this caller and no other.
        "lib/lain/cli/command/introspect.rb" => %w[outbox: @outbox.open? @outbox.target
                                                   @outbox.held_source @outbox.annotation_count],
        "spec/lain/cli/command/surface_spec.rb" => ["review-submit"],
        "spec/lain/forge/intent_spec.rb" => ["promote pr_create pr_merge review_submit"],
        "spec/lain/forge/reconcile_spec.rb" => ['blind(action: "review_submit"']
      },
      forces: [], plan: REVIEW_SURFACE, untestable: nil
    ),
    Capability.new(
      key: "github_pr",
      constants: %w[GithubPr],
      files: ["lib/lain/review/source/github_pr.rb", "spec/lain/review/source/github_pr_spec.rb"],
      # The CLI owns a whole pull-request LEG -- two refusals of its own, the
      # spelling probe, and the git call the ambiguity refusal needs -- and is
      # the only thing that ever builds one of these.
      consumers: ["lib/lain/cli/review.rb"],
      edits: {
        "lib/lain/review/source.rb" => ['require_relative "source/github_pr"'],
        # The spec drives that leg through the COMMAND, naming the source only
        # in prose, so the constant sweep is blind to eight examples that stop
        # compiling the moment the leg goes.
        "spec/lain/cli/review_spec.rb" => ["reads a bare number as a pull request",
                                           "refuses --base against a pull request"]
      },
      forces: %w[submit], plan: REVIEW_SURFACE, untestable: nil
    ),
    # The rows below are not the review surface's. They are units the
    # verified-deletions plan found unreachable and deliberately did not
    # remove, because whether they get WIRED instead is another plan's
    # question -- which is exactly the state a map of removable capabilities
    # is for: the cost of removing each one, machine-checked, standing ready
    # for whichever way that decision goes.
    Capability.new(
      key: "disclosure",
      # `Deferred` is spelled qualified and `Upfront` is not, and the leaf name
      # is the whole reason: `Approval::Gate::Policy::Deferred` is a live class
      # ending in the same segment, so a bare `Deferred` here would report four
      # files of the approval gate as unlisted consumers of a toolset strategy
      # they have never heard of.
      constants: %w[Disclosure Upfront Disclosure::Deferred],
      files: ["lib/lain/toolset/disclosure.rb", "lib/lain/toolset/disclosure/upfront.rb",
              "lib/lain/toolset/disclosure/deferred.rb", "spec/lain/toolset/disclosure_spec.rb",
              "spec/lain/toolset/disclosure/deferred_spec.rb"],
      # Nothing renders a Toolset through an arm: no `lib/` file outside the
      # bench sweep names either subclass, so the strategy seam has never been
      # on a live request path.
      consumers: [],
      edits: { "lib/lain/toolset.rb" => ['require_relative "toolset/disclosure"'] },
      # The map's only LOAD-TIME force, now that `diagnostics` -> `prefill` has
      # been executed: `disclosure_sweep.rb` reads both arms into `ARMS` while
      # its class body runs, so removing this row alone is a NameError at boot
      # rather than a missing feature. This row's boot example is that
      # coupling's only assertion -- it is green only because this line is
      # right, and reddens with a NameError naming `Disclosure` the moment it
      # is not. The search tool is the deferred arm's other half by design and
      # has no use without it -- that second force is a product decision, the
      # way every other `forces:` here is.
      forces: %w[disclosure_sweep tool_search],
      plan: VERIFIED_DELETIONS, untestable: nil
    ),
    Capability.new(
      key: "tool_search", constants: %w[ToolSearch],
      files: ["lib/lain/tools/tool_search.rb", "spec/lain/tools/tool_search_spec.rb"],
      # Both are whole-toolset properties, and neither is reached by wiring:
      # the registry builds the tool so the cross-tool examples can ask it
      # questions, and the bounds sweep exempts it by fully-qualified name.
      consumers: ["spec/support/tool_registry.rb", "spec/tool_bounds_discipline_spec.rb"],
      edits: {
        "lib/lain/tools.rb" => ['require_relative "tools/tool_search"'],
        # Two roll calls that spell the tool's model-facing NAME and never its
        # constant, so the sweep is blind to both: a posture's drop list and
        # the parallel-safety table's opted-out set.
        "spec/lain/mode/posture_spec.rb" => ['"request_review", "tool_search"'],
        "spec/lain/tools/parallel_safety_spec.rb" => ["web_fetch web_search tool_search"]
      },
      forces: [], plan: VERIFIED_DELETIONS, untestable: nil
    ),
    Capability.new(
      key: "disclosure_sweep", constants: %w[DisclosureSweep],
      # The committed task fixtures are the sweep's and no other reader's, so
      # they are files rather than an edit.
      files: ["lib/lain/bench/disclosure_sweep.rb", "spec/lain/bench/disclosure_sweep_spec.rb",
              "spec/fixtures/bench/disclosure/tasks.yml", "spec/fixtures/bench/disclosure/malformed.yml",
              "spec/fixtures/bench/disclosure/malformed_tool.yml",
              "spec/fixtures/bench/disclosure/missing_recorded_arm.yml"],
      consumers: ["spec/tool_bounds_discipline_spec.rb"],
      edits: { "lib/lain/bench.rb" => ['require_relative "bench/disclosure_sweep"'] },
      forces: [], plan: VERIFIED_DELETIONS, untestable: nil
    ),
    Capability.new(
      key: "epic_gate",
      constants: [], files: [], consumers: [], edits: {}, forces: [], plan: REVIEW_SURFACE,
      # The one row that is a REVERT rather than a removal: it owns no file, and
      # "make RequestReview refuse `implementation` again" is a behaviour change
      # across that tool's implementation leg and EpicMount's wiring. Named here
      # rather than left out, so the row cannot quietly acquire files without
      # somebody noticing it is no longer the shape this exemption was granted
      # for.
      untestable: "a behaviour revert, not a deletion: it owns no files"
    )
  ].freeze

  ROOT = Pathname(__dir__).join("..", "..", "..").expand_path

  # The rows the examples below iterate, and the roll call they are pinned
  # against. Two spellings on purpose: DERIVED is what every loop walks, and
  # NAMED is a literal, so a loop that quietly narrows -- the mutant that
  # survived until this pair existed -- is a red example rather than a green run
  # with fewer of them.
  TESTABLE = CAPABILITIES.select(&:testable?).freeze
  KEYS = %w[thread docent submit github_pr disclosure tool_search disclosure_sweep].freeze

  module_function

  def fetch(key)
    CAPABILITIES.find { |cap| cap.key == key } || raise("no such capability: #{key}")
  end

  # Every capability a row forces out with it, transitively.
  def dependents(cap)
    cap.forces.flat_map { |key| [fetch(key)] + dependents(fetch(key)) }
  end
end

# The tree, read once, with whole-line comments stripped: PROSE may name a
# capability anywhere (a sibling's comment citing {ThreadView::Entry} is better
# writing than one saying "the thread pane's editor half"), CODE may not. The
# thread pane's own deletability row reached that conclusion first and this
# generalises it.
#
# Read eagerly rather than memoised because six capabilities times three
# examples over ~1400 files is eight seconds of re-reading the same bytes, and
# because the sweep is a fact about a tree that does not change under it.
module TreeSweep
  # This file is the map, so it names every capability -- exempting it by path
  # is what keeps the sweep from reporting itself. A row's deletion takes its
  # entry in the map with it, which is an edit rather than a file.
  EXEMPT = "spec/lain/review/deletability_spec.rb"

  SOURCES = Dir[DeletionMap::ROOT.join("{lib,spec,exe}/**/*.{rb,lua}")]
            .select { |path| File.file?(path) }
            .map { |path| Pathname(path).relative_path_from(DeletionMap::ROOT).to_s }
            .reject { |path| path == EXEMPT }.sort.freeze

  CODE = SOURCES.to_h do |path|
    comment = path.end_with?(".lua") ? /^\s*--/ : /^\s*#/
    [path, DeletionMap::ROOT.join(path).readlines.grep_v(comment).join]
  end.freeze

  # `(?<!\w)` and not `\b`: the leaf of a qualified name (`Review::Submit`) must
  # match, while a longer identifier that merely ends in it (`EpicSubmit`) must
  # not.
  NAMING = DeletionMap::CAPABILITIES.to_h do |cap|
    pattern = Regexp.union(cap.constants.map { |name| /(?<!\w)#{Regexp.escape(name)}\b/ })
    [cap.key, cap.constants.empty? ? [] : CODE.select { |_path, body| body.match?(pattern) }.keys]
  end.freeze

  # Where a constant is DEFINED, as opposed to where it is read. This is the
  # check that catches a row which has drifted from the tree: a capability whose
  # constants live in a file its row does not name is not deletable by that row.
  DEFINING = DeletionMap::CAPABILITIES.to_h do |cap|
    pattern = Regexp.union(cap.constants.map { |name| /^\s*(?:class|module)\s+#{Regexp.escape(name)}\b/ })
    [cap.key, cap.constants.empty? ? [] : CODE.select { |_path, body| body.match?(pattern) }.keys]
  end.freeze

  module_function

  def naming(cap) = NAMING.fetch(cap.key)
  def defining(cap) = DEFINING.fetch(cap.key)

  # Every `lib/` unit that loads +unit+, by the stem relative to the requiring
  # file's own directory (`review/prefill` from `review.rb`, `prefill/finding`
  # from `review/prefill.rb`).
  def requiring(unit)
    SOURCES.grep(%r{^lib/.*\.rb$}).select do |path|
      stem = Pathname(unit).sub_ext("").relative_path_from(Pathname(path).dirname)
      CODE.fetch(path).match?(/^require_relative "#{Regexp.escape(stem.to_s)}"$/)
    end
  end
end

# A capability removed from a throwaway copy of `lib/`, so the tree can be
# booted without it. Hardlinked, so every write here is unlink-then-rewrite,
# never open-in-place: `cp -al` makes the copy share an inode with the real
# tree for every file it did not just create, and an in-place open or an
# overwriting copy onto an existing path would edit the real file through
# that shared inode rather than the copy alone.
class BootWithout
  Boot = Data.define(:ok, :output)

  def initialize(capabilities)
    @dir = Dir.mktmpdir("lain-deletability")
    system("cp", "-al", DeletionMap::ROOT.join("lib").to_s, File.join(@dir, "lib"), exception: true)
    capabilities.each { |cap| apply(cap) }
  end

  def boot
    entry = File.join(@dir, "lib", "lain.rb")
    output = IO.popen([RbConfig.ruby, "-e", %(require "#{entry}"; print "ok")], err: %i[child out], &:read)
    Boot.new(ok: output.include?("ok"), output:)
  end

  def remove = FileUtils.remove_entry(@dir)

  # Writes a fixture INTO this copy, never the real `lib/` the copy was
  # hardlinked from -- the same guarantee `apply` already gives every
  # capability's `edits`. Exists for one caller: the negative control below,
  # which needs a load-time coupling no shipped capability has anymore
  # (`diagnostics` -> `prefill` was the only one, and this plan executed it).
  # A capability BORROWED for that purpose breaks the day it is executed too
  # -- which is exactly what happened here -- so the control constructs its
  # own pair instead, sourced from `spec/fixtures/deletability_control/`
  # rather than shipped in `lib/`, where it would be permanently-dead
  # production code the next reachability audit would flag for deletion.
  #
  # `source` is copied WHOLE, so the fixture's full shape is on disk in the
  # copy; `requires` controls which of it the copy's own `lain.rb` actually
  # loads -- omitting one is how the control simulates that half having been
  # deleted, without needing a second call back into `apply`.
  #
  # Lands at `lib/<basename(source)>/` -- a name that collides with anything
  # already under `lib/` (today, only `lain/` and `lain.rb` exist to collide
  # with) is refused rather than silently overwritten: `FileUtils.cp` onto an
  # EXISTING path opens it for writing rather than creating a new inode, and
  # every such path here is hardlinked to the real tree, so overwriting one
  # is the exact corruption this class exists to make impossible.
  #
  # @param source [String] a directory of `.rb` fixture sources
  # @param requires [Array<String>] basenames (no extension) to require, in order
  # @raise [RuntimeError] if the destination path already exists in the copy
  def install(source, requires:)
    name = File.basename(source)
    dest = File.join(@dir, "lib", name)
    FileUtils.mkdir_p(dest)
    Dir.children(source).each do |file|
      target = File.join(dest, file)
      if File.exist?(target)
        raise "#{target} already exists in the copy -- install refuses to overwrite a path this copy " \
              "shares an inode with the real tree on; pick a fixture directory whose basename does not " \
              "collide with anything under lib/"
      end

      FileUtils.cp(File.join(source, file), target)
    end
    append_requires(File.join(@dir, "lib", "lain.rb"), requires.map { |req| %(require_relative "#{name}/#{req}") })
  end

  private

  def apply(cap)
    cap.files.grep(%r{^lib/}).each { |path| File.delete(File.join(@dir, path)) }
    cap.edits.each { |path, markers| drop_lines(path, markers) if path.start_with?("lib/") }
  end

  # Only a whole line the row records verbatim -- a `require_relative`. Anything
  # else in `edits` is a site a human has to think about, and this object's
  # claim is only that the LOAD survives.
  def drop_lines(path, markers)
    full = File.join(@dir, path)
    kept = File.readlines(full).reject { |line| markers.include?(line.strip) }
    File.delete(full)
    File.write(full, kept.join)
  end

  # `cp -al` HARDLINKS every file into the copy, so an in-place append (`File.open(path,
  # "a")`) writes through to the REAL file `BootWithout` was built to leave alone --
  # `install`'s first version did exactly that and corrupted the real `lib/lain.rb` for
  # every OTHER example that ran after it, in the same process and the next. `drop_lines`
  # above already gets this right by unlinking first; this is the same shape for an
  # append instead of a line removal.
  def append_requires(path, lines)
    content = File.read(path)
    File.delete(path)
    File.write(path, content + lines.map { |line| "#{line}\n" }.join)
  end
end

RSpec.describe "the deletion map", :seam do
  let(:map) { DeletionMap::CAPABILITIES }

  # Anti-vacuity, and it takes two guards rather than one. Every example that
  # ITERATES the map goes through {#testable}, which asserts what it is about to
  # visit; and the per-row boot examples below are GENERATED from the same list,
  # so narrowing it fails here instead of quietly producing five fewer examples.
  def testable
    expect(DeletionMap::TESTABLE.map(&:key)).to eq(DeletionMap::KEYS)
    DeletionMap::TESTABLE
  end

  it "covers every row the two plans declare deletable" do
    expect(map.map(&:key)).to eq(DeletionMap::KEYS + ["epic_gate"])
    expect(testable.size).to eq(DeletionMap::KEYS.size)
  end

  # `plan` is a bare String, so the two named here are a closed set rather than
  # a convention: a THIRD value on a new row would fall outside every table
  # block below with nothing to notice it. Adding a plan to this map is a
  # deliberate act that changes this line.
  it "carries rows from exactly the two plans that decided them" do
    expect(map.map(&:plan).uniq).to contain_exactly(DeletionMap::REVIEW_SURFACE, DeletionMap::VERIFIED_DELETIONS)
  end

  # Would have caught: the two lua modules named without their numeric prefixes.
  # The plan a row cites is checked with the rest: a row whose reasoning has
  # been renamed out from under it hands the next reader a verdict and no way
  # to find out why.
  it "names no path the tree has not got" do
    missing = map.flat_map { |cap| (cap.paths + [cap.plan]).reject { |path| DeletionMap::ROOT.join(path).file? } }

    expect(missing).to be_empty,
                       "the map names files that do not exist: #{missing.inspect}. A row whose paths have " \
                       "drifted deletes nothing and leaves the capability behind."
  end

  # Would have caught: four rows that omitted the `require` line their unit is
  # loaded by. A marker is a literal because that is the only thing that finds a
  # site naming no constant -- a require PATH, a role symbol, a manual stanza.
  it "names, for every edit site, a marker still present in that file" do
    stale = map.flat_map do |cap|
      cap.edits.flat_map do |path, markers|
        body = DeletionMap::ROOT.join(path).read
        markers.reject { |marker| body.include?(marker) }.map { |marker| "#{cap.key}: #{path} -> #{marker}" }
      end
    end

    expect(stale).to be_empty,
                     "the map records edit sites whose marker has moved: #{stale.inspect}. The site is either " \
                     "gone (drop it) or respelled (fix the marker) -- either way the row no longer describes " \
                     "the edit somebody has to make."
  end

  # The claim most likely to fail: a capability whose constants are
  # defined somewhere its row does not name cannot be deleted by that row.
  it "puts every file a capability's constants are DEFINED in on that capability's own file list" do
    testable.each do |cap|
      undeclared = TreeSweep.defining(cap) - cap.own

      expect(TreeSweep.defining(cap)).not_to be_empty, "#{cap.key} defines none of its own constants"
      expect(undeclared).to be_empty,
                            "#{cap.key}'s constants are defined in files its row does not name: " \
                            "#{undeclared.inspect}. A row that does not delete the definition does not " \
                            "delete the capability."
    end
  end

  # It would have caught the GitHub-submit row's three-that-were-ten.
  # EXACT equality, not a subset: an unlisted consumer is a site nobody will
  # delete, and a listed one that no longer names the capability is a row
  # claiming a cost it has stopped paying.
  it "is named in code only by its own files, its listed consumers, and the rows it forces" do
    testable.each do |cap|
      allowed = cap.own + cap.consumers +
                DeletionMap.dependents(cap).flat_map { |dep| dep.own + dep.consumers }
      unlisted = (TreeSweep.naming(cap) - allowed).sort
      stale = (cap.consumers - TreeSweep.naming(cap)).sort

      expect(unlisted).to be_empty,
                          "a file outside #{cap.key}'s row names it in CODE: #{unlisted.inspect}. Add it to " \
                          "`consumers` if it is a legitimate new one, AND to the chunk's deletion map -- a " \
                          "whole-line comment is already exempt."
      expect(stale).to be_empty, "#{cap.key} lists consumers that no longer name it: #{stale.inspect}"
    end
  end

  # The asymmetry, asserted rather than described: a lua module has NO require
  # line (the runtime loader globs the directory), every Ruby unit under `lib/` has
  # exactly one, and the row must name the file it lives in.
  it "records the one require site of every Ruby unit it deletes, and none for a lua one" do
    testable.each do |cap|
      cap.own.grep(%r{^lib/.*\.rb$}).each do |unit|
        requiring = TreeSweep.requiring(unit)

        expect(requiring.size).to be <= 1, "#{unit} is required from more than one place: #{requiring.inspect}"
        # `cap.own` as well as `cap.edited`: a unit's own index (`prefill.rb`
        # requires `prefill/finding`) goes in the same deletion, so that require
        # site is inside the row rather than beside it.
        expect(cap.edited + cap.own).to include(*requiring),
                                        "#{cap.key} deletes #{unit} without recording the `require_relative` " \
                                        "in #{requiring.inspect} -- a dangling require is a LoadError, not a " \
                                        "missing feature"
      end

      lua_requires = cap.own.grep(/\.lua$/).select { |lua| TreeSweep.requiring(lua).any? }

      expect(lua_requires).to be_empty, "the runtime loader globs that directory: #{lua_requires.inspect}"
    end
  end

  # The plan document is what a human reads before deciding a thing is cheap to
  # drop, and it is the copy that was wrong both times. Pinned to this map from
  # the side that matters: a file somebody has to delete which the section does
  # not mention is a cost the reader is not told about.
  #
  # Only the review surface's OWN rows, and that is the honest scope rather
  # than an oversight: it is the one plan that ships a file-level table to be
  # pinned against. The rows carrying another plan are pinned by this spec
  # alone, with `plan` naming where their reasoning lives -- so a second table
  # somewhere else would earn a second block like this one, and until then a
  # reader should not read this example as covering the whole map.
  describe "the chunk plan's own table" do
    let(:rows) { map.select { |cap| cap.plan == DeletionMap::REVIEW_SURFACE } }

    let(:section) do
      plan = DeletionMap::ROOT.join(DeletionMap::REVIEW_SURFACE).read
      plan[/^## Deletion map$.*?(?=^## )/m]
    end

    it "is where it says it is" do
      expect(section).not_to be_nil, "no `## Deletion map` section in #{DeletionMap::REVIEW_SURFACE}"
      expect(section.scan(/^\| /).size).to be >= 7
    end

    it "names every file the rows it owns delete" do
      expect(rows.map(&:key)).to eq(%w[thread docent submit github_pr epic_gate])

      unmentioned = rows.flat_map(&:own).reject { |path| section.include?(File.basename(path)) }

      expect(unmentioned).to be_empty,
                             "the plan's deletion map does not mention: #{unmentioned.inspect}. That is the " \
                             "defect this card exists for -- the table said three sites where the tree had ten."
    end

    it "names no path the tree has not got" do
      # A leading dot is a scratch artifact (a handback note), never a tree path.
      cited = section.scan(%r{`(\w[\w./-]*\.(?:rb|lua|md|txt))`}).flatten.uniq
      missing = cited.reject { |path| Dir[DeletionMap::ROOT.join("**", path)].any? }

      expect(cited).not_to be_empty
      expect(missing).to be_empty,
                         "the plan's deletion map cites paths that do not exist: #{missing.inspect}"
    end
  end

  # The core claim, in the affordable form. See this file's header for what this
  # does NOT prove and where the full delete-and-run lives.
  describe "booting without a capability" do
    DeletionMap::TESTABLE.each do |cap|
      it "still loads with #{cap.key} and everything it forces removed" do
        tree = BootWithout.new([cap] + DeletionMap.dependents(cap))
        booted = tree.boot

        expect(booted.ok).to be(true), "removing #{cap.key} left the tree unbootable:\n#{booted.output}"
      ensure
        tree&.remove
      end
    end

    # The control, and it is what says the example above is measuring
    # anything -- but not against a real row. Not every `forces:` is this
    # shape: `thread` -> `docent` and `github_pr` -> `submit` were checked
    # directly against `BootWithout` with only the forcing capability's own
    # files removed, and both boot CLEAN -- their `forces:` records a product
    # decision (a pane's messages have to become something; a source and its
    # write path are owned together), not a load-time read. `disclosure` ->
    # `disclosure_sweep` IS this shape, and is the only row that is: the sweep
    # reads both arms into `ARMS` while its class body runs. That is still not
    # a subject for the control, because a row is deletable by definition --
    # `diagnostics` -> `prefill` was the class-body coupling this control used
    # to borrow, and the day it was executed the control broke. So it gets its
    # own subject, INSTALLED rather than
    # shipped: `spec/fixtures/deletability_control/` holds `Forcer` and
    # `Dependent`, and `Dependent` reads `Forcer::VALUE` while ITS OWN class
    # body runs -- but neither is ever part of `lib/`, because a pair that
    # exists only to be deleted in a test is exactly the permanently-dead
    # production code this whole plan removes. `BootWithout#install` copies
    # both into the boot copy and requires only `dependent` -- omitting
    # `forcer`'s require is how this simulates its row having been executed,
    # without needing a second capability applied after the fact.
    it "does NOT load when a forced dependent is left behind" do
      fixture = DeletionMap::ROOT.join("spec/fixtures/deletability_control").to_s
      tree = BootWithout.new([])
      tree.install(fixture, requires: ["dependent"])
      booted = tree.boot

      # Two different failure shapes share this one boolean, so the message
      # naming Forcer is what tells them apart: a broken INSTALL (a missing
      # fixture file, a typo'd require) raises here, in this process, before
      # `boot` ever runs, rather than producing this `false`. Only a
      # NameError raised BY THE COPY, naming exactly the constant `Dependent`
      # reads and `dependent.rb` never got a chance to define, is the right
      # reason.
      expect(booted.ok).to be(false), "installing Dependent without Forcer was expected to break the boot"
      expect(booted.output).to include("Forcer")
    ensure
      tree&.remove
    end
  end
end
