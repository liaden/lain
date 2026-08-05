# frozen_string_literal: true

require "pathname"
require "tmpdir"

# The chunk's constraint, mechanised: parts of the review surface that do not
# work out must be EASY TO DELETE, and a plan that says so and a suite that
# proves it are different things.
#
# == Why a reference sweep alone is not the proof
#
# A sweep shows nothing points at a capability. It does not show the tree still
# LOADS without it, and the two failures are not the same shape: a dangling
# `require_relative` is a LoadError at boot, and a constant read in a class body
# (`Prefill`'s rank map derives from `Projection::Diagnostics`') is a NameError
# at boot -- neither of which any amount of grepping for a constant NAME finds,
# because the name is exactly what is gone. So each row here is also booted with
# its files removed.
#
# == And why the boot is not the whole proof either
#
# Booting is not running the suite. The full delete-and-run -- copy the tree,
# apply the whole row, `rake pspec`, score the example count -- is what actually
# means what §Intent claims, and it was performed by hand for every row at
# b3fbada (see `.handback-T25.md` for the counts). It is not shipped HERE
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
# all -- T6's loader globs the directory, so deleting the file is the whole edit
# -- while every **Ruby** unit has exactly one.

# One deletable capability, as one row of the map.
#
# `files` are deleted outright. `consumers` are files OUTSIDE the capability that
# name its constants in code and must be edited; the sweep pins that list
# exactly, so a new consumer is a red example rather than a silent extra site.
# `edits` are files that must change but do NOT name a constant -- a require
# path, a role symbol, a manual stanza -- so nothing but a literal marker can
# find them. `forces` is the nesting the plan records as data. `untestable`
# names, in words, why a row is exempt from the examples that need files.
Capability = Data.define(:key, :constants, :files, :consumers, :edits, :forces, :untestable) do
  def own = files
  def edited = edits.keys
  def paths = files + consumers + edits.keys
  def testable? = untestable.nil?
end

module DeletionMap
  # The rows. A Ruby unit's `require` line is spelled here as it appears in the
  # file, because a dangling `require_relative` is a LoadError rather than a
  # missing feature and only a literal finds it.
  CAPABILITIES = [
    Capability.new(
      key: "diagnostics",
      constants: %w[Diagnostics],
      files: ["lib/lain/frontend/neovim/runtime/49_diagnostics.lua", "lib/lain/review/projection/diagnostics.rb",
              "spec/lain/review/projection/diagnostics_spec.rb"],
      consumers: [],
      edits: {
        "lib/lain/review.rb" => ['require_relative "review/projection/diagnostics"'],
        # Found by DELETING, not by any sweep: the protocol history names the
        # three `__lain.` entry points this lua module publishes, and
        # `neovim_runtime_spec.rb`'s lockstep example asserts every name the
        # history gives against the live runtime. It is a COMMENT, so a scan
        # that strips comments -- the sweep below does -- cannot see it.
        "lib/lain/frontend/neovim.rb" => ["__lain.set_review_diagnostics"]
      },
      forces: %w[prefill], untestable: nil
    ),
    Capability.new(
      key: "prefill",
      constants: %w[Prefill],
      files: ["lib/lain/review/prefill.rb", "lib/lain/review/prefill/finding.rb",
              "lib/lain/review/prefill/sidecar.rb", "spec/lain/review/prefill_spec.rb"],
      consumers: [],
      edits: { "lib/lain/review.rb" => ['require_relative "review/prefill"'] },
      forces: [], untestable: nil
    ),
    Capability.new(
      key: "thread",
      constants: %w[ThreadView],
      files: ["lib/lain/frontend/neovim/runtime/51_thread.lua", "lib/lain/frontend/neovim/thread_view.rb",
              "spec/lain/frontend/neovim/thread_view_spec.rb"],
      # `#annotate` and `#thread` are the PORT's messages, so they survive the
      # pane and have to BECOME something -- deleting the pane is a rewrite here,
      # not a removal, which is the one thing the plan's "annotations still work"
      # does not say.
      consumers: ["lib/lain/review/surface/neovim.rb", "spec/lain/review/surface/neovim_spec.rb"],
      edits: {
        "lib/lain/frontend/neovim.rb" => ['require_relative "neovim/thread_view"', "__lain.set_thread"],
        "spec/lain/frontend/neovim_runtime_spec.rb" => ["LainReviewOpen LainNote LainNoteDone LainThread",
                                                        "set_review open_changeset set_thread"],
        "plugin/nvim/doc/lain.txt" => ["*:LainThread*", "*lain://thread*"]
      },
      forces: %w[docent], untestable: nil
    ),
    Capability.new(
      key: "docent",
      constants: %w[Docent],
      files: ["lib/lain/review/docent.rb", "lib/lain/prompt/templates/role/diff-docent.md",
              "spec/lain/review/docent_spec.rb"],
      consumers: ["lib/lain/cli/wiring/toolset_build.rb", "spec/lain/cli/wiring/toolset_build_spec.rb"],
      edits: {
        "lib/lain/review.rb" => ['require_relative "review/docent"'],
        # The catalog and the shipped templates are pinned equal in BOTH
        # directions, so a template without its catalog entry is a red spec and
        # a catalog entry without its roll-call name is another.
        "lib/lain/role/catalog.rb" => ["Role.new(name: :diff_docent"],
        "spec/lain/role_spec.rb" => [":merge_resolver, :diff_docent"]
      },
      forces: [], untestable: nil
    ),
    Capability.new(
      key: "submit",
      constants: %w[Submit REVIEW_SUBMIT submit_review],
      # T34 added the REACH -- the outbox, the verb and their specs; and
      # `endpoint.rb` builds only a review POST's own REST path, so it goes too.
      files: ["lib/lain/review/submit.rb", "lib/lain/review/submit/outbox.rb",
              "spec/lain/review/submit_spec.rb", "spec/lain/review/submit/outbox_spec.rb",
              "lib/lain/cli/command/review_submit.rb", "spec/lain/cli/command/review_submit_spec.rb",
              "lib/lain/forge/gh/endpoint.rb"],
      consumers: ["lib/lain/forge/gh.rb", "lib/lain/forge/gh/recorded.rb", "lib/lain/forge/intent.rb",
                  "lib/lain/forge/journaled.rb", "lib/lain/forge/reconcile.rb", "spec/lain/forge/gh_spec.rb",
                  "lib/lain/cli/command/surface.rb", "spec/lain/cli/command/review_spec.rb",
                  "spec/lain/forge/gh/recorded_spec.rb", "spec/support/shared_examples/gh_parity.rb"],
      edits: {
        "lib/lain/review.rb" => ['require_relative "review/submit"'],
        "lib/lain/forge/gh.rb" => ['require_relative "gh/endpoint"'],
        "lib/lain/cli/command.rb" => ['require_relative "command/review_submit"'],
        # Four sites the constant sweep is blind to: two spell the verb as the
        # wire STRING, one is the command set pinned as a LITERAL (the wiring
        # examples beside it go too), one is the keyword `/review` holds through.
        "lib/lain/cli/command/review.rb" => ["outbox:", "@outbox.hold"],
        "spec/lain/cli/command/surface_spec.rb" => ["review-submit"],
        "spec/lain/forge/intent_spec.rb" => ["promote pr_create pr_merge review_submit"],
        "spec/lain/forge/reconcile_spec.rb" => ['blind(action: "review_submit"']
      },
      forces: [], untestable: nil
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
      forces: %w[submit], untestable: nil
    ),
    Capability.new(
      key: "epic_gate",
      constants: [], files: [], consumers: [], edits: {}, forces: [],
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
  KEYS = %w[diagnostics prefill thread docent submit github_pr].freeze

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
# writing than one saying "T18's editor half"), CODE may not. T18's own
# deletability row reached that conclusion first and this generalises it.
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
# booted without it. Hardlinked, so nothing here can write through to the tree
# under test: an edited file is unlinked and rewritten, never opened in place.
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

  it "covers the seven rows the chunk's plan declares deletable" do
    expect(map.map(&:key)).to eq(DeletionMap::KEYS + ["epic_gate"])
    expect(testable.size).to eq(DeletionMap::KEYS.size)
  end

  # Would have caught: the two lua modules named without their numeric prefixes.
  it "names no path the tree has not got" do
    missing = map.flat_map { |cap| cap.paths.reject { |path| DeletionMap::ROOT.join(path).file? } }

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

  # AC 3, and the one most likely to fail: a capability whose constants are
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

  # AC 2, and it would have caught the GitHub-submit row's three-that-were-ten.
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
  # line (T6's loader globs the directory), every Ruby unit under `lib/` has
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

      expect(lua_requires).to be_empty, "T6's loader globs the runtime directory: #{lua_requires.inspect}"
    end
  end

  # The plan document is what a human reads before deciding a thing is cheap to
  # drop, and it is the copy that was wrong both times. Pinned to this map from
  # the side that matters: a file somebody has to delete which the section does
  # not mention is a cost the reader is not told about.
  describe "the chunk plan's own table" do
    let(:section) do
      plan = DeletionMap::ROOT.join("planning/specs/chunk-review-surface.md").read
      plan[/^## Deletion map$.*?(?=^## )/m]
    end

    it "is where it says it is" do
      expect(section).not_to be_nil, "no `## Deletion map` section in planning/specs/chunk-review-surface.md"
      expect(section.scan(/^\| /).size).to be >= 7
    end

    it "names every file the map deletes" do
      unmentioned = map.flat_map(&:own).reject { |path| section.include?(File.basename(path)) }

      expect(unmentioned).to be_empty,
                             "the plan's deletion map does not mention: #{unmentioned.inspect}. That is the " \
                             "defect this card exists for -- the table said three sites where the tree had ten."
    end

    it "names no path the tree has not got" do
      # A leading dot is a scratch artifact (`.handback-T25.md`), never a tree path.
      cited = section.scan(%r{`(\w[\w./-]*\.(?:rb|lua|md|txt))`}).flatten.uniq
      missing = cited.reject { |path| Dir[DeletionMap::ROOT.join("**", path)].any? }

      expect(cited).not_to be_empty
      expect(missing).to be_empty,
                         "the plan's deletion map cites paths that do not exist: #{missing.inspect}"
    end
  end

  # AC 1, in the affordable form. See this file's header for what this does NOT
  # prove and where the full delete-and-run lives.
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

    # The control, and it is what says the example above is measuring anything.
    # `Prefill`'s rank map derives from `Projection::Diagnostics`' while its
    # class body runs, so the nesting the map records is not documentation --
    # deleting the parent alone is a NameError at boot, with nothing to grep
    # for, because the name is exactly what is gone.
    it "does NOT load when a forced dependent is left behind" do
      tree = BootWithout.new([DeletionMap.fetch("diagnostics")])
      booted = tree.boot

      expect(booted.ok).to be(false), "deleting diagnostics without prefill was expected to break the boot"
      expect(booted.output).to include("Diagnostics")
    ensure
      tree&.remove
    end
  end
end
