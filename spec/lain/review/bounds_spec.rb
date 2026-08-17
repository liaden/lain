# frozen_string_literal: true

require "pathname"
require "ripper"

# Every fixture here is a REAL {Lain::Review::Changeset} over a hand-built diff
# String, never a double of one. The subject is arithmetic on counts, so a
# generated git repository would buy nothing and cost the suite a new wall-time
# floor (T30's table); but a double of `Changeset` would let the fixture answer
# counts the real parser never produces, which is exactly how a bound spec
# passes without the bound working. A synthetic diff String is both: real
# parser, no subprocess.
#
# The one deliberate double is the short-circuit probe, where the ASSERTION is
# that a message is never sent.
RSpec.describe Lain::Review::Bounds do
  # 5 rendered lines per file: 4 header lines + 1 `@@` + `body_lines` body.
  # {Bounds::Size} counts the `@@` and the body and NOT the four header lines,
  # so a file here is `body_lines + 1` rendered lines by the object's own unit.
  def file_section(path, body_lines)
    body = Array.new(body_lines) { |i| i.even? ? "-old#{i}" : "+new#{i}" }
    <<~HEAD + "#{body.join("\n")}\n"
      diff --git a/#{path} b/#{path}
      index 1111111..2222222 100644
      --- a/#{path}
      +++ b/#{path}
      @@ -1,#{body_lines} +1,#{body_lines} @@
    HEAD
  end

  def commit_record(sha:, paths:)
    numstat = paths.map { |path| Lain::Review::Source::FileStat.new(path: -path, added: 1, deleted: 1) }
    Lain::Review::Source::Commit.new(sha:, subject: "s #{sha}", body: "", numstat: numstat.freeze)
  end

  def fake_source(diff:, commits:)
    DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                    diff: diff.b, commits: commits.freeze,
                                    base_ref: "b" * 40, head_ref: "h" * 40))
  end

  def paths_for(file_count) = Array.new(file_count) { |i| format("f%04d.rb", i) }

  def rendered_lines_of(files) = Lain::Review::Bounds::Size.of(files).lines

  # The grouping the two commit-scoped checks and `/critique` chunking read,
  # named once here rather than restated at each call.
  def walk = Lain::Review::Partition::STRATEGIES.fetch(:commits)

  # Files that RAISE when their hunks are read, and answer their own size the
  # way a source-supplied file does. The only doubles in the file, and they are
  # here because the assertion is that a message is never sent -- which no real
  # object can report on itself, and which a RECORDER only reports rather than
  # enforces. A recorder leaves the green run resting on the recorder; a raised
  # exception cannot be scored as a pass by anything.
  def unchunkable_files(count:, rendered_lines:)
    Array.new(count) do
      instance_double(Lain::Review::Source::ChangedFile, rendered_lines:).tap do |file|
        allow(file).to receive(:hunks) { raise "a bounded presentation read a file's hunks" }
      end
    end
  end

  # `supports?` answers true so applicability never short-circuits the candidate
  # walk -- these probes are about hunk reads, not about grouping. `partitions`
  # defaults to empty, which makes the refusal's ADVICE measure nothing, so a
  # probe over it isolates the DECISION; a probe that wants the advice measured
  # hands over groups of its own.
  def unchunkable_view(count:, rendered_lines: 1, partitions: [])
    instance_double(Lain::Review::Changeset,
                    files: unchunkable_files(count:, rendered_lines:),
                    partitions:, supports?: true)
  end

  # A group of unchunkable files, for the advice half: {Bounds#cumulative_advice}
  # measures each candidate's groups, and this is what it measures.
  def unchunkable_group(count:, rendered_lines:)
    Lain::Review::Partition.new(label: "g", files: unchunkable_files(count:, rendered_lines:).freeze)
  end

  # A changeset described commit by commit, each commit a list of per-file
  # body-line counts: `[[2, 2], [400]]` is two small files in c0 and one large
  # one in c1. Every path belongs to exactly one commit's numstat, so T7's
  # attribution is unambiguous and no scope is blanked.
  def named_files(spec)
    spec.each_with_index.map do |sizes, ci|
      sizes.each_with_index.map { |body, fi| [format("c%<ci>02df%<fi>03d.rb", ci:, fi:), body] }
    end
  end

  def changeset_from(spec)
    named = named_files(spec)
    diff = named.flatten(1).map { |path, body| file_section(path, body) }.join
    commits = named.each_with_index.map do |pairs, ci|
      commit_record(sha: "c#{ci}", paths: pairs.map(&:first))
    end
    Lain::Review::Changeset.new(source: fake_source(diff:, commits:))
  end

  # `commit_count` commits, each naming a DISJOINT slice of the paths, so T7's
  # last-writer-wins attribution gives every commit a non-empty scope. The
  # merge case -- where it does not -- is built separately and on purpose.
  def changeset_of(file_count:, commit_count: 1, body_lines: 2)
    paths = paths_for(file_count)
    diff = paths.map { |path| file_section(path, body_lines) }.join
    per = (file_count / commit_count.to_f).ceil
    commits = paths.each_slice(per).with_index.map { |slice, i| commit_record(sha: "c#{i}", paths: slice) }
    Lain::Review::Changeset.new(source: fake_source(diff:, commits:))
  end

  # The measured merge shape, reproduced through T7's REAL attribution rather
  # than asserted about: `--diff-merges=first-parent` re-reports everything the
  # merge brought in, so the merge's numstat names the side branch's files too
  # and last-writer-wins hands them ALL to it. Two of three scopes come back
  # empty (`changeset.rb`, "What a consumer may and may not claim").
  def changeset_with_merge(file_count: 9, body_lines: 2)
    paths = paths_for(file_count)
    diff = paths.map { |path| file_section(path, body_lines) }.join
    third = file_count / 3
    commits = [commit_record(sha: "c0", paths: paths.first(third)),
               commit_record(sha: "c1", paths: paths[third...(third * 2)]),
               commit_record(sha: "merge", paths:)]
    Lain::Review::Changeset.new(source: fake_source(diff:, commits:))
  end

  # `dir`'s share of a directory-keyed fixture: `sizes.size` paths under
  # `dir/`, each `[path, body_lines]`. Shared by the two directory fixtures
  # below so neither repeats the naming scheme.
  def dir_files(dir, sizes)
    sizes.each_with_index.map { |body, i| [format("%<dir>s/f%<i>03d.rb", dir:, i:), body] }
  end

  # A changeset whose files sit in DISTINCT directories but all belong to ONE
  # commit -- so grouping BY COMMIT cannot narrow it at all (one group, the
  # whole changeset again) while grouping BY DIRECTORY can. `dirs` maps a
  # directory name to a list of per-file body-line counts, e.g.
  # `{"a" => [2, 2], "b" => [2, 2]}` -- two files of 2 body lines each, in
  # each of two directories, all attributed to the one commit.
  def changeset_by_directory(dirs)
    named = dirs.flat_map { |dir, sizes| dir_files(dir, sizes) }
    diff = named.map { |path, body| file_section(path, body) }.join
    commits = [commit_record(sha: "c0", paths: named.map(&:first))]
    Lain::Review::Changeset.new(source: fake_source(diff:, commits:))
  end

  # ONE commit per directory, each owning exactly that directory's files --
  # built so {Partition::ByCommit} and {Partition::ByDirectory} produce the
  # SAME two groups by two different roads. Whichever one `#advice` names is
  # settled purely by {Bounds::NARROWING_CANDIDATES} registry ORDER, since fit
  # cannot distinguish them. `dirs` maps a directory name (also its commit's
  # sole content) to a list of per-file body-line counts.
  def changeset_commits_matching_directories(dirs)
    groups = dirs.map { |dir, sizes| dir_files(dir, sizes) }
    diff = groups.flatten(1).map { |path, body| file_section(path, body) }.join
    commits = groups.each_with_index.map { |files, i| commit_record(sha: "c#{i}", paths: files.map(&:first)) }
    Lain::Review::Changeset.new(source: fake_source(diff:, commits:))
  end

  describe "the defaults, and the evidence for each" do
    # The one literal kept as a literal, because the number is not ours to
    # retune: GitHub stops SERVING a combined diff past 300 files (research
    # S3.7), so for {Source::GithubPr} it is an API fact, and tuicr#475
    # independently settled on the same ceiling (S4.2). A pin against an
    # external constant is what a pin is for.
    it "sets the file ceiling where two independent sources put it" do
      expect(described_class::DEFAULT_MAX_FILES).to eq(300)
    end

    # DERIVED, so the derivation is what gets asserted rather than the digits:
    # S3.7 measured 80,800 rendered lines over 800 files -- 101 lines per file --
    # and the invariant the doc states is that both ceilings fire at the same
    # changeset SIZE (a line ceiling far above the implied one is dead code, one
    # far below makes the file ceiling unreachable).
    #
    # The tolerance is 2%, not a comfortable 10%. With DEFAULT_MAX_FILES pinned
    # as a literal four lines up, this relation has one fixed end, so a loose
    # band degenerates into a WEAKER version of the `eq(30_000)` it replaced --
    # measured: at 10% both 28_000 and 32_500 pass where the literal failed. 2%
    # admits [29_694, 30_906], which the rounding from 30,300 needs and nothing
    # else does, so any retune has to be deliberate.
    it "sets the rendered-line ceiling consistently with the file one at work-scale density" do
      implied = described_class::DEFAULT_MAX_FILES * 101

      expect(described_class::DEFAULT_MAX_LINES).to be_within(0.02 * implied).of(implied)
    end

    # Anchored on the constraint the doc names -- a context window -- and NOT
    # on S3.7's 2,727, which is the mean of a synthetic uniform generator
    # (`bigdiff_stacked` emits identical commits) and so has no tail to sit
    # above. A ceiling at mean + 47% refuses the tail of every real changeset.
    #
    # The literal comes FIRST and stays: the derivation below is a range, and a
    # range wide enough to survive the doc's own 3.0-4.0 bytes/token estimate is
    # too wide to pin the number. Measured: on the derivation alone, 6_000 and
    # 7_700 both pass -- a 14% cut and a 10% rise invisible to the whole suite,
    # where `eq(7_000)` catches both. So they are two assertions, not one: the
    # literal says WHICH number, the derivation says WHY that number and fails
    # if the window it was derived from moves out from under it.
    #
    # The POLICY is "at most half the smallest window a bench arm might run",
    # and the smallest window is read from {ContextWindow} rather than copied
    # here, so the two cannot drift silently apart. ~45 bytes per rendered line
    # at ~3.5 bytes/token is the doc's own estimate; the lower bound is what
    # keeps the upper one honest, since a ceiling small enough to clear it
    # trivially is a ceiling that stopped being derived from a window at all.
    it "sets the critique ceiling from the smallest window a bench arm might run" do
      expect(described_class::DEFAULT_MAX_CRITIQUE_LINES).to eq(7_000)

      smallest_window = Lain::ContextWindow.default.window_tokens("claude-haiku-4-5")
      tokens = described_class::DEFAULT_MAX_CRITIQUE_LINES * 45 / 3.5

      expect(tokens).to be < (smallest_window / 2.0)
      expect(tokens).to be > (smallest_window / 4.0)
    end

    it "leaves the measured per-commit view far inside the critique ceiling" do
      expect(described_class::DEFAULT_MAX_CRITIQUE_LINES).to be > (2_727 * 2)
    end

    it "takes Budget's shape: coerced, frozen, and readable" do
      bounds = described_class.new(max_files: "7", max_lines: "8", max_critique_lines: "9")

      expect([bounds.max_files, bounds.max_lines, bounds.max_critique_lines]).to eq([7, 8, 9])
      expect(bounds).to be_frozen
    end

    it "refuses a ceiling that is not a number, rather than coercing it to zero" do
      expect { described_class.new(max_files: "many") }.to raise_error(ArgumentError)
    end
  end

  # The registry's whole point, checked where both readers are in scope: these
  # are plain objects with identity equality, so a registry that minted a fresh
  # strategy per read would leave the two constants neither `equal?` nor `==` --
  # and the first code to compare or cache a resolved scope would fail silently.
  describe "the strategy it groups by" do
    it "holds the registry's own instance, the same one the session's join holds" do
      expect(described_class::COMMIT_STRATEGY).to equal(Lain::Review::Session::MarkedChangeset::WALK)
    end

    it "reads it out of the registry rather than constructing a second one" do
      expect(described_class::COMMIT_STRATEGY).to equal(Lain::Review::Partition::STRATEGIES.fetch(:commits))
    end
  end

  # A4's own registry: every strategy a cumulative refusal may recommend
  # narrowing to, minus the strategy that IS the cumulative view.
  describe "the candidates a cumulative refusal may narrow to" do
    it "holds every registered strategy except the whole-changeset one" do
      expect(described_class::NARROWING_CANDIDATES)
        .to eq(Lain::Review::Partition::STRATEGIES.values - [Lain::Review::Partition::STRATEGIES.fetch(:cumulative)])
    end

    it "excludes the whole-changeset strategy itself" do
      expect(described_class::NARROWING_CANDIDATES)
        .not_to include(Lain::Review::Partition::STRATEGIES.fetch(:cumulative))
    end
  end

  describe "the scope vocabulary" do
    # The registry IS the vocabulary now, so this is a COMPLETENESS law rather
    # than an equality against a second list: every strategy a human can name
    # must have a check here, because {Session#present} sends the resolved
    # scope straight through and a missing one is a KeyError deep in a refusal
    # path. `include` rather than `eq` so a scope this object can bound but
    # nobody has registered is not itself a failure.
    it "derives its scopes from the strategy registry rather than restating them" do
      expect(described_class::SCOPE_CHECKS.keys).to include(*Lain::Review::Partition::STRATEGIES.keys)
    end

    it "names the commit walk in the registry's own spelling" do
      expect(Lain::Review::Partition::STRATEGIES.fetch(:commits).name).to eq(described_class::COMMIT_WALK)
    end

    # Deriving a method NAME from a vocabulary is only half a dependency: add a
    # strategy to the registry and the miss is a NoMethodError at call time,
    # deep in a refusal path, rather than here.
    it "has a real private method behind every derived name" do
      expect(described_class::SCOPE_CHECKS.values)
        .to all(satisfy { |name| described_class.private_method_defined?(name) })
    end

    it "fails loudly on a scope nobody declared" do
      expect { described_class.new.check_presentation!(changeset_of(file_count: 1), scope: :cumulatve) }
        .to raise_error(KeyError)
    end
  end

  describe "Size, and the unit it counts in" do
    it "counts a hunk's body plus its @@ header, per file" do
      size = described_class::Size.of(changeset_of(file_count: 3, body_lines: 4).files)

      expect(size.files).to eq(3)
      expect(size.lines).to eq(3 * (4 + 1))
    end

    it "counts a hunkless file as one file and no lines" do
      size = described_class::Size.of([Lain::Review::Source::ChangedFile.new(
        old_path: "a.bin", new_path: "a.bin", binary: true, hunks: []
      )])

      expect([size.files, size.lines]).to eq([1, 0])
    end
  end

  # AC 1. Both sides of both ceilings, and "just" means off by one.
  describe "#check_presentation! at scope: :cumulative" do
    it "passes a changeset exactly at the file ceiling" do
      bounds = described_class.new(max_files: 4, max_lines: 10_000)

      expect { bounds.check_presentation!(changeset_of(file_count: 4), scope: :cumulative) }.not_to raise_error
    end

    it "refuses one file past it" do
      bounds = described_class.new(max_files: 4, max_lines: 10_000)

      expect { bounds.check_presentation!(changeset_of(file_count: 5), scope: :cumulative) }
        .to raise_error(described_class::TooLarge)
    end

    it "passes a changeset exactly at the rendered-line ceiling" do
      bounds = described_class.new(max_files: 1_000, max_lines: 12)

      expect { bounds.check_presentation!(changeset_of(file_count: 4, body_lines: 2), scope: :cumulative) }
        .not_to raise_error
    end

    it "refuses one rendered line past it" do
      bounds = described_class.new(max_files: 1_000, max_lines: 11)

      expect { bounds.check_presentation!(changeset_of(file_count: 4, body_lines: 2), scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /12 rendered lines/)
    end

    it "names the file count, the ceiling, and the commit walk" do
      work = changeset_of(file_count: 800, commit_count: 30)

      expect { described_class.new.check_presentation!(work, scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /\b800 files\b.*\b300\b.*scope: commits/m)
    end

    # Schneeman's finding: advice that sends a human down a path which also
    # refuses is worse than no advice. One commit of 40,001 lines has no
    # narrower presentation, so the refusal must not pretend otherwise.
    it "does not offer the commit walk when the commit walk would refuse too" do
      bounds = described_class.new(max_files: 10, max_lines: 12)

      expect { bounds.check_presentation!(changeset_from([[20]]), scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /no scope that presents/)
    end

    it "still offers the commit walk when the commit walk actually fits" do
      bounds = described_class.new(max_files: 10, max_lines: 11)

      expect { bounds.check_presentation!(changeset_from([[2, 2], [2, 2]]), scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /scope: commits/)
    end

    # The MIXED walk, which is the whole reason the advice is conditioned: one
    # oversized commit among fitting ones. Both examples above use walks where
    # every scope agrees, so `all?` and `any?` are indistinguishable there --
    # this is the case where `any?` resumes sending a human down a walk that
    # refuses.
    it "withholds the commit walk when only SOME commits fit" do
      bounds = described_class.new(max_files: 10, max_lines: 12)

      expect { bounds.check_presentation!(changeset_from([[2, 2], [20]]), scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /no scope that presents/)
    end

    # AC 1 (A4): the axis is real once a SECOND strategy can be the one a
    # refusal recommends. One commit owns every file, so grouping by commit
    # cannot narrow anything -- the walk is one group, the whole changeset
    # again -- while grouping by directory splits it into two that both fit.
    it "recommends the directory partitioning when the commit walk cannot narrow but directories can" do
      bounds = described_class.new(max_files: 2, max_lines: 100)
      changeset = changeset_by_directory("a" => [2, 2], "b" => [2, 2])

      expect { bounds.check_presentation!(changeset, scope: :cumulative) }
        .to raise_error(described_class::TooLarge) { |error|
          expect(error.message).to include("present it per directory (scope: by_directory) instead")
          expect(error.message).not_to match(/commit/i)
        }
    end

    # The property A3 and A4 each assumed the other owned. A4 defers the
    # `#supports?` filter to {Session#present} -- but that filters the RESOLVED
    # scope, and this walk runs on the CUMULATIVE path, where the resolved
    # scope is `:cumulative` and every candidate is consulted regardless.
    # {Partition::ByCommit} is first, so a source with no walk died in
    # `ownership` with a `NoMethodError` naming neither the scope asked for nor
    # the source that could not serve it.
    #
    # `lain survey` is what makes this reachable rather than theoretical: a
    # corpus source answers no `#commits` and `survey` defaults to `cumulative`.
    describe "a candidate the source cannot be grouped by" do
      # `diff`, `base_ref` and `head_ref` and nothing else -- a Data genuinely
      # does not answer `#commits`, which is what keeps this from being a
      # double that merely says so.
      #
      # Wrapped in {DiffSource} for the port's model-value half (`#files` and
      # `#identity`) and for nothing else: the wrapper is a `SimpleDelegator`,
      # so `respond_to?(:commits)` still reaches the Data and still answers
      # false, which is the property this group rests on. The Data cannot
      # include `Source::Diffed` itself -- a Data instance is frozen, so the
      # module's `@files ||=` memo raises `FrozenError` on first read.
      def commitless_changeset(dirs)
        named = dirs.flat_map { |dir, sizes| dir_files(dir, sizes) }
        diff = named.map { |path, body| file_section(path, body) }.join
        data = Data.define(:diff, :base_ref, :head_ref)
                   .new(diff: diff.b, base_ref: "b" * 40, head_ref: "h" * 40)
        Lain::Review::Changeset.new(source: DiffSource.over(data))
      end

      it "refuses with a measured sentence rather than dying inside the walk" do
        bounds = described_class.new(max_files: 2, max_lines: 100)

        raised = begin
          bounds.check_presentation!(commitless_changeset("a" => [2, 2], "b" => [2, 2]), scope: :cumulative)
        rescue StandardError => e
          e
        end

        expect(raised).to be_a(described_class::TooLarge)
      end

      # The candidate is SKIPPED, not merely survived: the directory grouping
      # sits behind the commit walk in registry order, so it can only be
      # recommended if the walk was passed over rather than tried.
      it "falls through to the next candidate the source CAN be grouped by" do
        bounds = described_class.new(max_files: 2, max_lines: 100)

        expect { bounds.check_presentation!(commitless_changeset("a" => [2, 2], "b" => [2, 2]), scope: :cumulative) }
          .to raise_error(described_class::TooLarge, /present it per directory \(scope: by_directory\) instead/)
      end

      it "offers no narrowing when the only candidates left also refuse" do
        bounds = described_class.new(max_files: 10, max_lines: 12)

        expect { bounds.check_presentation!(commitless_changeset("a" => [20], "b" => [20]), scope: :cumulative) }
          .to raise_error(described_class::TooLarge, /no scope that presents this changeset whole/)
      end
    end

    # AC 2 (A4): the measured-advice property one level up from a single
    # strategy -- when EVERY candidate refuses, not just the commit walk, the
    # refusal still offers no narrowing rather than a strategy-specific one
    # that would also refuse.
    it "offers no narrowing when every candidate strategy also refuses" do
      bounds = described_class.new(max_files: 10, max_lines: 12)
      changeset = changeset_by_directory("a" => [20], "b" => [20])

      expect { bounds.check_presentation!(changeset, scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /no scope that presents this changeset whole/)
    end

    # Pins the ORDERING itself, not just NARROWING_CANDIDATES' own structure:
    # two commits, each owning exactly one directory, so BY COMMIT and BY
    # DIRECTORY produce the identical two groups and BOTH fit. Only registry
    # order decides -- {Partition::ByCommit} is tried first -- so this is
    # "first fit, not best fit" as an observed sentence, not an inference from
    # {Bounds::NARROWING_CANDIDATES}'s own definition.
    it "recommends the FIRST candidate that fits, not the best one, when more than one does" do
      bounds = described_class.new(max_files: 3, max_lines: 100)
      changeset = changeset_commits_matching_directories("a" => [2, 2], "b" => [2, 2])

      expect { bounds.check_presentation!(changeset, scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /scope: commits/)
    end

    # Two sides of one probe, same five files, only the ceiling differs -- and
    # BOTH sides must now come back clean, which is the change. The refusal was
    # already cheap because the file guard short-circuits; the SUCCESS was not,
    # because the line guard summed `file.hunks` over every file it had just
    # agreed to present.
    it "decides the file ceiling without reading a single hunk" do
      expect { described_class.new(max_files: 4).check_presentation!(unchunkable_view(count: 5), scope: :cumulative) }
        .to raise_error(described_class::TooLarge)
    end

    it "presents a view inside both ceilings without reading a single hunk" do
      view = unchunkable_view(count: 50, rendered_lines: 10)

      expect { described_class.new.check_presentation!(view, scope: :cumulative) }.not_to raise_error
    end

    # The negative above passes against a line guard that reads nothing AND
    # against one that measures nothing at all, so the ceiling has to be shown
    # still firing off the same source-known sizes.
    it "refuses on the line ceiling off the sizes the files answer, still reading no hunk" do
      view = unchunkable_view(count: 50, rendered_lines: 10)

      expect { described_class.new(max_lines: 499).check_presentation!(view, scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /500 rendered lines/)
    end

    # The AC that keeps the promise honestly stated: the promise is about the
    # DECISION, and the MESSAGE is composed by measuring each candidate's groups.
    # That measurement now runs off the same per-file sizes, so this composes a
    # full refusal sentence -- advice included -- over files that raise if read.
    it "composes the advice by measuring partitions, and measures them without hunks either" do
      view = unchunkable_view(count: 5, rendered_lines: 4,
                              partitions: [unchunkable_group(count: 2, rendered_lines: 4)])

      expect { described_class.new(max_files: 4, max_lines: 100).check_presentation!(view, scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /5 files, over the ceiling of 4 -- \S/)
    end
  end

  # AC 5 and 6. The ceiling that is not a number, and the one that is by default.
  describe "an unbounded ceiling" do
    it "is infinity, which answers the whole comparison duck a number does" do
      expect(described_class::UNBOUNDED).to eq(Float::INFINITY)
    end

    it "presents what a number would refuse" do
      bounds = described_class.new(max_files: described_class::UNBOUNDED)

      expect { bounds.check_presentation!(unchunkable_view(count: 600), scope: :cumulative) }.not_to raise_error
    end

    it "survives the coercion every other ceiling goes through" do
      bounds = described_class.new(max_files: described_class::UNBOUNDED,
                                   max_lines: described_class::UNBOUNDED,
                                   max_critique_lines: described_class::UNBOUNDED)

      expect([bounds.max_files, bounds.max_lines, bounds.max_critique_lines])
        .to eq([described_class::UNBOUNDED] * 3)
    end

    # The failure {Bounds} exists to prevent is a view that got through: an
    # absent argument must be a NUMBER, so a ceiling nobody configured refuses
    # what an unbounded one presents.
    it "is never what an absent ceiling defaults to" do
      expect { described_class.new.check_presentation!(unchunkable_view(count: 600), scope: :cumulative) }
        .to raise_error(described_class::TooLarge, /600 files/)
    end

    it "does not make every non-number acceptable" do
      expect { described_class.new(max_files: "many") }.to raise_error(ArgumentError)
    end

    # The constant is ONE object, so `equal?` would pass every example above and
    # fail only the ceiling a caller COMPUTED -- which is how an unbounded
    # ceiling will actually arrive once a flag parses one. Infinity is not a
    # flonum, so `1.0/0` is a different object with the same value.
    it "recognises a computed infinity, not merely the one constant" do
      bounds = described_class.new(max_files: 1.0 / 0)

      expect { bounds.check_presentation!(unchunkable_view(count: 600), scope: :cumulative) }.not_to raise_error
    end

    # `value == UNBOUNDED` asks the ARGUMENT, so an object that answers true to
    # everything became an unbounded ceiling with the coercion never run. The
    # comparison has to be the one infinity itself makes.
    it "is not fooled by an argument that merely claims to equal it" do
      liar = Class.new { def ==(_other) = true }.new

      expect { described_class.new(max_files: liar) }.to raise_error(TypeError)
    end
  end

  # AC 2, and the reason it needs more than "nothing raised".
  describe "#check_presentation! at scope: :commits" do
    subject(:changeset) { changeset_of(file_count: 800, commit_count: 30) }

    it "presents 800 files across 30 commits with no refusal, at bounds the cumulative view fails" do
      bounds = described_class.new(max_files: 300, max_lines: 30_000)

      expect { bounds.check_presentation!(changeset, scope: :cumulative) }
        .to raise_error(described_class::TooLarge)
      expect { bounds.check_presentation!(changeset, scope: :commits) }.not_to raise_error
    end

    # Without this, "each commit presents without refusal" is satisfied by a
    # walk whose scopes are all empty -- true and useless at the same time.
    it "covers every file across the walk, with no empty scope" do
      scopes = changeset.partitions(walk)

      expect(scopes.size).to eq(30)
      expect(scopes.sum { |scope| scope.files.size }).to eq(800)
      expect(scopes.map { |scope| scope.files.size }).to all(be_positive)
    end

    # The subject comes from the group's DETAIL, not from `"commit #{sha}"` --
    # a refusal that says "commit" in prose is one no other grouping could make
    # honest, and every strategy names its own groups. The commit walk's detail
    # puts the sha back, because a subject alone cannot be looked up.
    it "refuses the ONE commit that is over, naming it by subject AND sha" do
      merged = changeset_with_merge(file_count: 9)
      bounds = described_class.new(max_files: 4, max_lines: 10_000)

      expect { bounds.check_presentation!(merged, scope: :commits) }
        .to raise_error(described_class::TooLarge, /\As merge \(commit merge\) is 9 files, over the ceiling of 4 --/)
    end

    # The half a subject alone cannot carry: two commits can share one, and a
    # reader told their review is too large has to be able to reach the commit.
    it "names a sha a reader can look the commit up by" do
      merged = changeset_with_merge(file_count: 9)

      expect { described_class.new(max_files: 4).check_presentation!(merged, scope: :commits) }
        .to raise_error(described_class::TooLarge, /commit merge/)
    end

    # The hazard stated rather than hidden: two of three scopes are empty, so a
    # merge-blanked walk "presents" only because there is nothing in it.
    it "pins the merge blanking that makes an empty scope possible" do
      scopes = changeset_with_merge(file_count: 9).partitions(walk)

      expect(scopes.map { |scope| scope.files.size }).to eq([0, 0, 9])
    end

    it "offers no alternative for a single commit, because there is none narrower" do
      bounds = described_class.new(max_files: 4, max_lines: 10_000)

      expect { bounds.check_presentation!(changeset_with_merge(file_count: 9), scope: :commits) }
        .to raise_error(described_class::TooLarge, /narrowest/)
    end
  end

  # AC 3.
  describe "#each_critique_chunk" do
    subject(:changeset) { changeset_of(file_count: 90, commit_count: 30) }

    it "yields one chunk per commit" do
      chunks = described_class.new.each_critique_chunk(changeset).to_a

      expect(chunks.map(&:label)).to eq(changeset.partitions(walk).map(&:label))
    end

    it "drops nothing: the chunks' files are the changeset's files" do
      chunks = described_class.new.each_critique_chunk(changeset).to_a

      expect(chunks.flat_map { |chunk| chunk.files.map(&:path) }.sort)
        .to eq(changeset.files.map(&:path).sort)
    end

    it "yields an empty commit rather than skipping it" do
      chunks = described_class.new.each_critique_chunk(changeset_with_merge(file_count: 9)).to_a

      expect(chunks.map { |chunk| chunk.files.size }).to eq([0, 0, 9])
    end

    # {Changeset#each_anchor}'s promise, kept one level up: holding the
    # enumerator walks no commits. `#partitions` is where the grouping happens,
    # so "was it called" is the observable -- and the second half proves the
    # size block is wired to it rather than to a constant.
    it "walks no commits when no block is given" do
      walks = 0
      view = instance_double(Lain::Review::Changeset)
      allow(view).to receive(:partitions) do
        walks += 1
        changeset.partitions(walk)
      end

      enumerator = described_class.new.each_critique_chunk(view)

      expect(enumerator).to be_a(Enumerator)
      expect(walks).to eq(0)
      expect(enumerator.size).to eq(30)
      expect(walks).to eq(1)
    end

    # A frozen Bounds cannot memoize on itself, so asking an Enumerator for its
    # size and then iterating it used to pack the whole changeset twice --
    # `Changeset#files` memoizes, but neither the grouping, the packing walk nor
    # its per-file guard does.
    it "packs once however many times the enumerator is asked" do
      walks = 0
      view = instance_double(Lain::Review::Changeset)
      allow(view).to receive(:partitions) do
        walks += 1
        changeset.partitions(walk)
      end

      enumerator = described_class.new.each_critique_chunk(view)

      expect(enumerator.size).to eq(30)
      expect(enumerator.to_a.size).to eq(30)
      expect(walks).to eq(1)
    end

    it "packs a commit exactly at the critique ceiling into one chunk" do
      bounds = described_class.new(max_critique_lines: 9)

      expect { |probe| bounds.each_critique_chunk(changeset_of(file_count: 3, body_lines: 2), &probe) }
        .to yield_control.once
    end

    # The panel's finding, and the behaviour that makes the old refusal message
    # false: the FILE is a boundary git supplies below the commit, so a commit
    # one line over splits instead of refusing.
    it "splits a commit one rendered line over the ceiling, rather than refusing" do
      bounds = described_class.new(max_critique_lines: 8)
      chunks = bounds.each_critique_chunk(changeset_of(file_count: 3, body_lines: 2)).to_a

      expect(chunks.size).to eq(2)
      expect(chunks.map { |chunk| chunk.files.size }).to eq([2, 1])
      expect(chunks.map { |chunk| chunk.detail.sha }.uniq).to eq(["c0"])
    end

    # UNSORTED on purpose. `pack` promises "greedy, in the diff's own order",
    # and a sorted comparison cannot see a reversal -- it agrees with any
    # permutation that happens to contain the right paths.
    it "keeps every chunk within the ceiling, and every file exactly once in DIFF ORDER" do
      bounds = described_class.new(max_critique_lines: 10)
      changeset = changeset_from([[2, 2, 2, 2], [4, 4]])
      chunks = bounds.each_critique_chunk(changeset).to_a

      expect(chunks.map { |chunk| rendered_lines_of(chunk.files) }).to all(be <= 10)
      expect(chunks.flat_map { |chunk| chunk.files.map(&:path) })
        .to eq(changeset.files.map(&:path))
    end

    # The one place a refusal is still honest, and the sentence now says why.
    it "refuses only when ONE FILE alone is over, naming the path and the ceiling" do
      bounds = described_class.new(max_critique_lines: 8)

      expect { bounds.each_critique_chunk(changeset_from([[20]])) { nil } }
        .to raise_error(described_class::TooLarge, /c00f000\.rb.*\b21\b.*\b8\b.*smallest chunk/m)
    end

    it "does not claim a commit is the smallest chunk" do
      bounds = described_class.new(max_critique_lines: 8)

      expect { bounds.each_critique_chunk(changeset_from([[20]])) { nil } }
        .to raise_error(described_class::TooLarge, /a file is the smallest chunk/)
    end

    # Half-yielded work is not "handled": by the time the refusal lands, the
    # earlier chunks would already be at the model.
    it "refuses before yielding anything at all when a LATER commit holds the big file" do
      over = changeset_from([[2, 2], [2], [40]])
      seen = []

      expect { described_class.new(max_critique_lines: 10).each_critique_chunk(over) { |c| seen << c } }
        .to raise_error(described_class::TooLarge)
      expect(seen).to be_empty
    end

    # AC 3 at the card's literal scale, which the first cut never ran: 810
    # files, 81,810 rendered lines, 30 commits, at the DEFAULT bounds.
    it "chunks the work-scale changeset one chunk per commit, dropping nothing" do
      work = changeset_of(file_count: 810, commit_count: 30, body_lines: 100)
      chunks = described_class.new.each_critique_chunk(work).to_a

      expect(rendered_lines_of(work.files)).to eq(81_810)
      expect(chunks.size).to eq(30)
      expect(chunks.sum { |chunk| chunk.files.size }).to eq(810)
    end

    # The panel's counterexample to the old ceiling: a legitimately large single
    # file that no context window has any trouble with must not be refused.
    it "accepts a 5,001-line single-file commit at the default ceiling" do
      expect { described_class.new.each_critique_chunk(changeset_of(file_count: 1, body_lines: 5_000)) { nil } }
        .not_to raise_error
    end
  end

  # AC 4, as a sweep rather than one case: nothing is ever truncated.
  describe "nothing is silently truncated" do
    it "refuses every presentation it cannot show whole, at every scope" do
      bounds = described_class.new(max_files: 4, max_lines: 12, max_critique_lines: 8)
      oversized = [changeset_of(file_count: 5), changeset_of(file_count: 4, body_lines: 4),
                   changeset_of(file_count: 20, commit_count: 4), changeset_with_merge(file_count: 9)]

      oversized.each do |changeset|
        Lain::Review::Partition::STRATEGIES.each_key do |scope|
          expect { bounds.check_presentation!(changeset, scope:) }
            .to raise_error(described_class::TooLarge)
        end
      end
    end

    # The AC as stated, for the path that now SPLITS: over any bound, critique
    # either covers every file exactly once or raises. There is no third
    # outcome, and a dropped file is what the third outcome would look like.
    it "either covers every file exactly once or names a refusal, whatever the bound" do
      candidates = [changeset_of(file_count: 5), changeset_of(file_count: 4, body_lines: 4),
                    changeset_of(file_count: 20, commit_count: 4), changeset_with_merge(file_count: 9),
                    changeset_from([[2, 2], [40]]), changeset_from([[1]])]

      [1, 3, 8, 12, 41, 10_000].each do |ceiling|
        bounds = described_class.new(max_critique_lines: ceiling)
        candidates.each do |changeset|
          covered = begin
            bounds.each_critique_chunk(changeset).flat_map { |chunk| chunk.files.map(&:path) }
          rescue described_class::TooLarge
            changeset.files.map(&:path)
          end
          expect(covered).to match_array(changeset.files.map(&:path))
        end
      end
    end

    it "handles the whole of a changeset under every bound" do
      bounds = described_class.new(max_files: 4, max_lines: 12, max_critique_lines: 12)
      changeset = changeset_of(file_count: 4, commit_count: 2)

      Lain::Review::Partition::STRATEGIES.each_key do |scope|
        expect { bounds.check_presentation!(changeset, scope:) }.not_to raise_error
      end
      expect(bounds.each_critique_chunk(changeset).sum { |chunk| chunk.files.size }).to eq(4)
    end
  end

  # T31c's actual deliverable is a COUNT, and a count is the one thing prose
  # cannot hold: this guard used to be called from {Lain::CLI::Review#present}
  # and was moved onto {Lain::Review::Session#present} so that every surface is
  # bounded by one caller rather than by whichever command remembered to ask. A
  # second caller added later would restore the two-places-enforce-one-ceiling
  # shape and nothing anywhere would go red.
  #
  # Pinned mechanically, `spec/output_discipline_spec.rb`'s way: Ripper over the
  # syntax tree, never a grep, because the files that discuss this guard discuss
  # it at length in comments -- {Lain::CLI::Review}'s class doc still names it,
  # and must, since that is where the follow-up this card discharged was written.
  describe "how many places in lib/ enforce a presentation ceiling" do
    guard = "check_presentation!"

    def lib_root = Pathname(__dir__).join("..", "..", "..", "lib").expand_path

    # Every `@ident` node spelling the guard, MINUS the one a `def` names --
    # what is left is a call. `node.drop(2)` on a `:def` skips both the keyword
    # and the method name, so {Bounds}' own definition is not counted as a use
    # of itself.
    define_method(:guard_lines) do |node, found|
      return unless node.is_a?(Array)

      found << node[2].first if node[0] == :@ident && node[1] == guard
      (node[0] == :def ? node.drop(2) : node).each { |child| guard_lines(child, found) }
    end

    def call_sites_in(source)
      sexp = Ripper.sexp(source)
      raise "could not parse the source under test" if sexp.nil?

      [].tap { |found| guard_lines(sexp, found) }
    end

    # Ripper over all 465 files costs more than this question is worth, so the
    # raw text is the SIEVE and the syntax tree is the ANSWER: a file that never
    # spells the word cannot call it, and every file that does is then parsed.
    define_method(:call_sites) do
      lib_root.glob("**/*.rb").filter_map do |file|
        source = file.read
        sites = source.include?(guard) ? call_sites_in(source) : []
        [file.relative_path_from(lib_root).to_s, sites] unless sites.empty?
      end.to_h
    end

    it "is called from exactly one place, so one ceiling has one enforcer" do
      expect(call_sites.keys).to eq(["lain/review/session.rb"])
    end

    it "is called ONCE there, not once per scope or once per surface" do
      expect(call_sites.fetch("lain/review/session.rb").size).to eq(1)
    end

    # Guards the guard, `output_discipline_spec.rb`'s way: the scanner reads the
    # syntax tree, so the word in a comment, in a String literal and in the
    # `def` that declares it are all invisible to it -- and all three of those
    # are present in `lib/` as it stands.
    it "counts neither a comment, a string literal, nor the definition itself (self-test)" do
      source = <<~RUBY
        # {Review::Bounds#check_presentation!} is called somewhere else now
        WORDS = "check_presentation! is not called by this literal"
        def check_presentation!(view, scope:) = nil
        def elsewhere(view, scope:) = bounds.check_presentation!(view, scope:)
      RUBY

      expect(call_sites_in(source).size).to eq(1)
    end
  end
end
