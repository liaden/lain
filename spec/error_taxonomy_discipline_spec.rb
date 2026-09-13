# frozen_string_literal: true

require "pathname"

# Five `StandardError` classes escaped `exe/lain`'s `rescue Lain::Error` sites and now
# descend from it; no single one of the five is this spec's subject, hence
# spec/*_discipline_spec.rb rather than a mirrored lib/ path. `Declarative::DeclarationError`
# is a sixth candidate that stays outside on purpose -- see the ruling in `declarative.rb`.
#
# The second half of this file is the RATCHET over the whole taxonomy, and it is
# here for the same reason: its subject is every error class at once.
#
# THE RULE IT ENFORCES. A failure mode earns its own class only when something
# tells it apart from its siblings -- a caller that rescues it by name, an
# `is_a?`, a `declare raising:` target, a list something folds over, a `.name`
# written as data, or a spec that asserts on it. A class that is only ever
# RAISED is a name doing no work: whatever it meant belongs in the sentence,
# where the person reading the failure will actually see it.
#
# Why it is mechanical rather than a review habit: 89 classes were deleted under
# this rule in one pass, and nothing but a scan stops the same 89 growing back
# one commit at a time. A `raise` is deliberately NOT evidence -- that is the
# failure happening, not a caller distinguishing it.
module ErrorTaxonomyDiscipline
  ROOT = Pathname(__dir__).parent

  # What makes a superclass an error's. Deliberately a spelling test rather than
  # `<= Exception`: the scan reads source, so nothing is loaded and a class whose
  # file never loads in this process is still counted.
  ERROR_ISH = /(?:Error|Refusal|Refused|Violation|Exception|Interrupt|Timeout|NotAPartition)\b/
  CONST = /(?:[A-Z][A-Za-z0-9_]*::)*[A-Z][A-Za-z0-9_]*/

  Declaration = Data.define(:full, :name, :superclass, :file, :line) do
    def to_s = "#{full} (#{file}:#{line})"
  end

  # Classes the rule would take that are here anyway, each with the reason.
  # THE LIST MAY ONLY SHRINK: the example below fails on an entry that has since
  # earned cover, so nothing rots into a permanent exemption.
  #
  # None of these was introduced by the pass that wrote this scan -- they are the
  # debt it found and did not take on. Every one is raised and never told apart.
  TOLERATED = {
    "Lain::CLI::Command::Pin::Refusal" =>
      "six raise sites in /pin and /unpin, no caller and no spec that names it",
    "Lain::CLI::Command::Rewind::Refusal" =>
      "the same shape one command over; /rewind's own refusals are read as sentences",
    "Lain::CLI::Epic::UnreadableHome" =>
      "carries a body that composes its sentence, so its name is not the only thing it holds",
    "Lain::CLI::HumanReplies::Reply::UnknownArm" =>
      "two raise sites over a closed set of arms; nothing reads the class back",
    "Lain::CLI::Worktrees::NotARepository" =>
      "two raise sites in `lain worktrees gc`; the isolation backend's same-named sibling IS rescued",
    "Lain::Grader::TestHarness::Adapter::Unparseable" =>
      "one raise site inside the rspec adapter",
    "Lain::Isolation::SelfSync::Failed" =>
      "several raise sites over git subprocesses, all read as messages",
    "Lain::Provider::HTTP::ConfigurationError" =>
      "vendored from ruby_llm 1.16.0 -- deleting it forks the vendor, see the file header",
    "Lain::Provider::HTTP::InvalidRoleError" =>
      "vendored from ruby_llm 1.16.0, same reason",
    "Lain::Review::Partition::Strategy::Incomplete" =>
      "one raise site naming what a candidate strategy failed to answer",
    "Lain::Review::Session::NotWidened" =>
      "one raise site; its own doc explains the placement, not a discrimination"
  }.freeze

  # This file names classes in {TOLERATED} as string literals, and a scan that
  # read itself would hand each of them the very cover the entry records them as
  # lacking. {OutputDiscipline} skips itself for the same reason.
  SELF = "spec/#{File.basename(__FILE__)}".freeze

  # One instance, built once, memoising into its own ivars -- the scan is three
  # reads of the tree and the suite must not pay for it per example. An instance
  # rather than the module, so nothing memoises onto a class.
  class Scan
    def declarations = @declarations ||= Dir.glob(ROOT.join("lib/**/*.rb")).flat_map { declared_in(_1) }

    def by_full = @by_full ||= declarations.to_h { [_1.full, _1] }

    def declared_in(path)
      rel = Pathname(path).relative_path_from(ROOT).to_s
      stack = []
      File.readlines(path).each_with_index.filter_map do |line, index|
        opened = opens(line)
        unwind(stack, opened || line.match(/^(\s*)end\s*$/))
        found = opened && declaration(opened, stack, rel, index)
        stack.push([opened[2], opened[1].length]) if opened && opened[4].nil?
        found
      end
    end

    def opens(line) = line.match(/^(\s*)(?:class|module)\s+([A-Za-z0-9_:]+)(?:\s*<\s*(#{CONST}))?\s*(;\s*end\s*)?$/o)

    def declaration(opened, stack, rel, index)
      return nil unless opened[3]&.match?(ERROR_ISH)

      Declaration.new(full: (stack.map(&:first) + [opened[2]]).join("::"), name: opened[2],
                      superclass: opened[3], file: rel, line: index + 1)
    end

    def unwind(stack, marker)
      stack.pop while marker && stack.any? && stack.last.last >= marker[1].length
    end

    # Ruby's own lookup, innermost namespace outward. A short-name sweep is wrong
    # here and quietly so: `Unknown`, `Refused` and `MissingFixture` each name
    # several unrelated classes, and the wrong one answers.
    def lexical(token, namespace)
      parts = namespace.to_s.split("::")
      found = parts.length.downto(0).lazy
                   .map { (parts.first(_1) + [token]).join("::") }
                   .find { by_full.key?(_1) }
      found || (token if by_full.key?(token))
    end

    # The namespace in force on each line, by indentation -- the same walk
    # `declared_in` does, kept separate because this one answers for EVERY line.
    def namespaces(lines)
      stack = []
      lines.map do |line|
        opened = line.match(/^(\s*)(?:class|module)\s+([A-Za-z0-9_:]+)/) unless line.match?(/;\s*end\s*$/)
        unwind(stack, opened)
        here = opened ? (stack.map(&:first) + [opened[2]]).join("::") : stack.map(&:first).join("::")
        stack.push([opened[2], opened[1].length]) if opened
        unwind(stack, line.match(/^(\s*)end\s*$/))
        here
      end
    end

    def library_evidence = @library_evidence ||= gather(["lib/**/*.rb", "exe/*"]) { |*args| library_hits(*args) }

    def spec_evidence = @spec_evidence ||= gather(["spec/**/*.rb"]) { |*args| spec_hits(*args) }

    def gather(globs)
      found = Hash.new { |held, key| held[key] = [] }
      Dir.glob(globs.map { ROOT.join(_1) }).each do |path|
        rel = Pathname(path).relative_path_from(ROOT).to_s
        yield(File.readlines(path), rel).each { |full, where| found[full] << where } unless rel == SELF
      end
      found
    end

    # Every mention in running code that is not the declaration and not a bare
    # `raise`: a named rescue, an `is_a?`, a `raising:` target, an alias, a
    # `.name` written as data, membership in a list a caller folds over.
    def library_hits(lines, rel)
      scopes = namespaces(lines)
      lines.each_with_index.flat_map do |line, index|
        quiet = line.strip.start_with?("#") || line.match?(/^\s*class\s/) ||
                (line.match?(/\braise[( ]/) && !line.match?(/\brescue\b/))
        quiet ? [] : line.scan(CONST).filter_map { |token| pair(lexical(token, scopes[index]), rel, index) }
      end
    end

    # `described_class::Foo` resolves through the MIRROR -- the lib file this
    # spec file is named for -- never through the nesting of `describe` blocks.
    # Walking that nesting was tried and mis-resolved doubly-nested subjects,
    # and the mirror is the rule this suite keeps anyway.
    def spec_hits(lines, rel)
      mirrored = rel.sub(%r{\Aspec/}, "lib/").sub(/_spec\.rb\z/, ".rb")
      subject = declarations.select { _1.file == mirrored }
      running = lines.each_with_index.reject { |line, _| line.strip.start_with?("#") }
      running.flat_map do |line, index|
        line.scan(/(?:described_class|#{CONST})(?:::#{CONST})?/o)
            .flat_map { |token| named_by(token, subject).map { |full| pair(full, rel, index) } }
      end
    end

    def named_by(token, subject)
      return [token] if by_full.key?(token)
      return [] unless token.start_with?("described_class::")

      leaf = token.split("::").last
      subject.select { _1.name == leaf }.map(&:full)
    end

    def pair(full, rel, index) = full && [full, "#{rel}:#{index + 1}"]

    # A base is discriminated on by every subclass that names it.
    def bases
      @bases ||= declarations.filter_map { _1.superclass && lexical(_1.superclass, parent_of(_1.full)) }.uniq
    end

    def parent_of(full) = full.split("::")[0..-2].join("::")

    def discriminated?(declaration)
      library_evidence[declaration.full].any? || spec_evidence[declaration.full].any? ||
        bases.include?(declaration.full)
    end

    def undiscriminated = declarations.reject { discriminated?(_1) }
  end

  SCAN = Scan.new
end

RSpec.describe "Lain::Error taxonomy" do
  # `const_get`, not `::`, because `Unjudged` is `private_constant`.
  def rooted
    [
      Lain::Middleware::GuardTestLayout.const_get(:Unjudged),
      Lain::Shell::Pipeline::Timeout,
      Lain::Tools::WebFetch::ByteCap::Reached,
      Lain::Tools::WebFetch::ByteCap::Refused,
      Lain::Frontend::LineEditor::KeyTaken
    ]
  end

  it "roots every renderer-reachable error under the project's error root" do
    expect(rooted).to all(be < Lain::Error)
    expect(Lain::Error.subclasses).to include(*rooted)
  end

  it "keeps the declaration-time programmer error outside the render boundary" do
    expect(Lain::Declarative::DeclarationError.ancestors).not_to include(Lain::Error)
  end

  it "carries no shadow at the two sites the root qualification was dropped from" do
    # `WorkerId::Refused` and `Types::CoercionError` dropped their `::Lain::Error` qualifier;
    # that's safe only if no module in their lexical scope defines its own `Error`.
    [Lain::Isolation::WorkerId, Lain::Isolation, Lain::Declarative::Types, Lain::Declarative].each do |namespace|
      expect(namespace.const_defined?(:Error, false)).to be(false)
    end

    expect(Lain::Isolation::WorkerId::Refused.superclass).to eq(Lain::Error)
    expect(Lain::Declarative::Types::CoercionError.superclass).to eq(Lain::Error)
  end

  describe "the ratchet over every declared error class" do
    let(:scan) { ErrorTaxonomyDiscipline::SCAN }

    it "finds the taxonomy at all, so a silent zero cannot pass as a clean sweep" do
      expect(scan.declarations.size).to be > 200
      expect(scan.declarations.map(&:file)).to include("lib/lain/tool.rb")
    end

    it "gives every error class a caller or a spec that tells it from its siblings" do
      stranded = scan.undiscriminated.reject { ErrorTaxonomyDiscipline::TOLERATED.key?(_1.full) }

      expect(stranded).to be_empty, lambda {
        "these error classes are raised and never told apart -- nothing rescues them by name, " \
          "no `is_a?` or `declare raising:` reaches them, no subclass extends them and no spec " \
          "asserts on them. Put the reason in the sentence and raise a class that survives, or " \
          "give one of them a caller:\n#{stranded.map { "  #{_1}" }.join("\n")}"
      }
    end

    it "keeps no tolerated entry for a class that has since earned a caller" do
      earned = ErrorTaxonomyDiscipline::TOLERATED.keys.select { scan.discriminated?(scan.by_full.fetch(_1)) }

      expect(earned).to be_empty, lambda {
        "these are discriminated on now, so drop them from TOLERATED rather than leaving an " \
          "exemption that reads as a standing allowance:\n#{earned.map { "  #{_1}" }.join("\n")}"
      }
    end

    it "keeps no tolerated entry for a class that no longer exists" do
      expect(ErrorTaxonomyDiscipline::TOLERATED.keys - scan.by_full.keys).to be_empty
    end

    it "keeps the contract violation, which the rule's first clause alone would take" do
      # Nothing in lib/ rescues it by name -- only the generic arm at
      # `effect/handler/live.rb` -- so the spec assertions ARE the whole of its
      # cover, and a rule counting only rescues would delete it. That this
      # example holds while the one above passes is the proof the clause is
      # needed; any rule that takes this class is wrong.
      violation = scan.by_full.fetch("Lain::Tool::ContractViolation")

      expect(scan.library_evidence[violation.full]).to be_empty
      expect(scan.spec_evidence[violation.full]).not_to be_empty
      expect(scan.undiscriminated).not_to include(violation)
    end
  end
end
