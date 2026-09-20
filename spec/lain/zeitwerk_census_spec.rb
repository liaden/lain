# frozen_string_literal: true

# `load`, not `require_relative`: the subject lives at `bin/zeitwerk-census`
# with no `.rb` extension, and Ruby's `require` family resolves a feature by
# trying known suffixes rather than falling back to the literal path. The file
# only defines a module and a CLI block guarded by `$PROGRAM_NAME == __FILE__`,
# which is false under rspec. `spec/lain/spec_census_spec.rb` does the same for
# the same reason.
load File.expand_path("../../bin/zeitwerk-census", __dir__)

require "tmpdir"

# What is asserted here is the CLASSIFIER and the RATCHET, against fixture
# Hashes shaped like a probe's output -- never a count against this repository's
# own tree. The whole-tree answer costs three child boots and ~4s, which is
# `bin/zeitwerk-census`'s job and not a per-suite price; the one thing a
# whole-tree run can legitimately fail on, a finding nobody has seen before, is
# its `--check` ratchet.
#
# The probe itself is deliberately absent from this file. It installs a
# `Module#const_missing` and evals `lib/lain.rb`, neither of which a process
# that has already required lain can do -- which is the argument for this being
# a script and not a spec, restated as a fact about what this file can reach.
RSpec.describe ZeitwerkCensus do
  def run(order, hits: [], fails: [])
    { "order" => order, "hits" => hits, "fails" => fails }
  end

  def hit(const, from:, defined_in:) = { "const" => const, "from" => from, "defined_in" => defined_in }

  def fail_entry(file, message, klass: "Zeitwerk::NameError", blamed: nil)
    { "file" => file, "class" => klass, "message" => message, "blamed" => blamed }
  end

  def missing(file, cpath) = "expected file #{file} to define constant #{cpath}, but didn't"

  describe ".findings" do
    it "reads a const_missing hit as a load-time orphan reference" do
      found = described_class::Classify.findings(
        [run("forward", hits: [hit("Lain::Price", from: "lain/bench/sweep.rb:70", defined_in: "lain/price_book.rb")])]
      )

      expect(found.map(&:shape)).to eq([:reference])
      expect(found.first.name).to eq("Lain::Price")
      expect(found.first.where).to eq("lain/bench/sweep.rb:70 -> lain/price_book.rb [forward]")
    end

    # The site a name is WRITTEN at and the load-time body that reaches it are
    # often different files -- a keyword default is the case that made this
    # necessary -- and a reader who is only shown the first looks at code that
    # runs at call time and cannot see why it fires at boot.
    it "names the load-time site beside the writing site when they differ" do
      kwarg_default = hit("Lain::Mode::LayerSet", from: "lain/mode.rb:30", defined_in: "lain/mode/layer.rb")
      found = described_class::Classify.findings(
        [run("forward", hits: [kwarg_default.merge("at" => "lain/cli/command/mode.rb:53")])]
      )

      expect(found.first.where).to eq("lain/mode.rb:30 via lain/cli/command/mode.rb:53 -> lain/mode/layer.rb [forward]")
    end

    # The file that FAILED to define the constant is the finding; the file being
    # required when Zeitwerk noticed is a cascade and would send a reader to the
    # wrong place.
    it "names the file Zeitwerk blamed, not the file being required" do
      found = described_class::Classify.findings(
        [run("forward", fails: [fail_entry("lain/tools/ast_search.rb", missing("lain/structural.rb", "Lain::Structural"))])]
      )

      expect(found.map(&:shape)).to eq([:namespace])
      expect(found.first.name).to eq("lain/structural.rb")
    end

    it "demotes a failure inside an already-flagged namespace's subtree to a cascade" do
      found = described_class::Classify.findings(
        [run("reverse",
             fails: [fail_entry("lain/provider/http.rb", missing("lain/provider/http.rb", "Lain::Provider::HTTP")),
                     fail_entry("lain/provider/http/tools.rb", "uninitialized constant Anthropic::Tools",
                                klass: "NameError")])]
      )

      expect(found.map { [_1.shape, _1.name] })
        .to contain_exactly([:namespace, "lain/provider/http.rb"], [:cascade, "lain/provider/http/tools.rb"])
    end

    # A cascade surfaces wherever the load happened to reach, and the eager
    # load is not a file at all -- so a subtree match against the failing SITE
    # reddens the gate on a consequence of a finding already listed.
    it "demotes a cascade that surfaced at the eager load, which is under no subtree" do
      index = fail_entry("lain/provider/http.rb", missing("lain/provider/http.rb", "Lain::Provider::HTTP"))
      behind = fail_entry(
        "(eager_load)", "uninitialized constant Anthropic::Chat",
        klass: "NameError", blamed: "lain/provider/http/providers/anthropic/chat.rb"
      )
      found = described_class::Classify.findings([run("reverse", fails: [index, behind])])

      expect(found.map { [_1.shape, _1.name] })
        .to contain_exactly([:namespace, "lain/provider/http.rb"],
                            [:cascade, "lain/provider/http/providers/anthropic/chat.rb"])
    end

    # One fact, one line: a reader who sees both budgets one more fix than
    # there is.
    it "demotes a reference naming the very constant a flagged namespace fails to define" do
      found = described_class::Classify.findings(
        [run("forward",
             hits: [hit("Lain::Provider::HTTP", from: "lain/provider/ollama/transport.rb:28",
                                                defined_in: "lain/provider/http/error.rb")],
             fails: [fail_entry("lain/provider/http.rb", missing("lain/provider/http.rb", "Lain::Provider::HTTP"))])]
      )

      expect(found.map(&:shape)).to contain_exactly(:cascade, :namespace)
    end

    it "reports a failure it cannot place as unclassified rather than sweeping it" do
      found = described_class::Classify.findings(
        [run("forward", fails: [fail_entry("lain/agent.rb", "stack level too deep", klass: "SystemStackError")])]
      )

      expect(found.map(&:shape)).to eq([:unclassified])
      expect(found.first.where).to eq("SystemStackError: stack level too deep at lain/agent.rb [forward]")
    end

    # Both orders see most findings. Keeping the first sighting is what makes
    # the `[forward]`/`[reverse]` tag mean "the order this was FIRST seen in".
    it "keeps one finding per name across the two load orders" do
      sighting = hit("Lain::Epic::STAGES", from: "lain/arm/ladder.rb:24", defined_in: "lain/epic/stage.rb")
      found = described_class::Classify.findings([run("forward", hits: [sighting]), run("reverse", hits: [sighting])])

      expect(found.size).to eq(1)
      expect(found.first.where).to end_with("[forward]")
    end

    # The reverse pass exists for exactly this: a reference the sorted order
    # happens to satisfy is invisible until the order is turned around.
    it "carries a finding only the reverse order saw" do
      lucky = hit("Lain::Epic::MalformedGraph", from: "lain/epic/intake.rb:44", defined_in: "lain/epic/graph.rb")
      found = described_class::Classify.findings([run("forward"), run("reverse", hits: [lucky])])

      expect(found.map(&:name)).to eq(["Lain::Epic::MalformedGraph"])
    end
  end

  # The stripper is what makes "the manifest is gone" true rather than mostly
  # true. It missed indented requires for one round, which left four files
  # under `review/partition/` never probed manifest-free while the census still
  # printed a banner saying every internal require was removed.
  describe ".place" do
    it "removes an indented require_relative, not only a column-0 one" do
      Dir.mktmpdir("zeitwerk-census-spec-") do |dir|
        source = File.join(dir, "index.rb")
        File.write(source, "module Foo\n  require_relative \"foo/bar\"\nend\n")
        ZeitwerkCensus::Survey.place(source, File.join(dir, "stripped.rb"))

        expect(File.read(File.join(dir, "stripped.rb"))).to eq("module Foo\nend\n")
      end
    end
  end

  describe described_class::Census do
    def census(found, known, ratchet: true)
      described_class.new(:reference, "title", found.map { ZeitwerkCensus::Finding.new(:reference, _1, "where") },
                          known, ratchet)
    end

    it "is over when a finding is not in the allowlist" do
      expect(census(%w[Lain::New], %w[Lain::Old])).to be_over
    end

    # Failing on good news makes the guard adversarial to whoever just fixed
    # something, so a name the allowlist still carries and the tree no longer
    # produces is reported and not failed on.
    it "is not over when the allowlist names something already fixed" do
      subject = census([], %w[Lain::Old])

      expect(subject).not_to be_over
      expect(subject.stale).to eq(%w[Lain::Old])
    end

    it "never fails a report-only shape" do
      expect(census(%w[Lain::New], [], ratchet: false)).not_to be_over
    end
  end

  describe described_class::CLI do
    def census(shape, found, known, ratchet: true)
      ZeitwerkCensus::Census.new(shape, "title", found.map { ZeitwerkCensus::Finding.new(shape, _1, "where") },
                                 known, ratchet)
    end

    # A silent pass is a guard nobody trusts, so every shape prints a verdict
    # whether or not it has anything to say.
    it "prints an ok line naming the count for a census at its allowlist" do
      expect(described_class.verdict(census(:reference, %w[Lain::Known], %w[Lain::Known])))
        .to eq("ok   reference: 1 known")
    end

    it "names each stale entry in the ok line so the allowlist can shrink" do
      expect(described_class.verdict(census(:reference, [],
                                            %w[Lain::Old]))).to include("Lain::Old", "delete those lines")
    end

    # A failing ratchet that prints only a number gives a reader no baseline to
    # diff the new entry out of, and no statement of what they may do about it.
    it "prints the new entries and both legal answers when the ratchet trips" do
      text = described_class.verdict(census(:namespace, %w[lain/new.rb], []))

      expect(text).to start_with("FAIL namespace: 1 not in the allowlist")
      expect(text).to include("lain/new.rb", "ZeitwerkCensus::Known", "its own commit")
    end
  end
end
