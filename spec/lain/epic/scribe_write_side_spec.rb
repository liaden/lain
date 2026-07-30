# frozen_string_literal: true

require "pathname"

# T4 review, fix 3: "nothing else in lib may construct these records" is
# stated three times across scribe.rb and records.rb, and it is true today --
# but nothing kept it true. Mechanical enforcement, in the shape
# spec/output_discipline_spec.rb and spec/lain/event_spec.rb's "no Turn
# constant remains" already use for their own closed invariants: scan the
# source rather than trust a comment to stay accurate as the codebase grows.
#
# A textual scan, not an AST walk, because the invariant IS textual: the
# constructors are named exactly once, by name, the same way
# Refold::SLUG_TYPES names its record types by their JOURNAL_TYPE strings
# rather than by structural shape.
#
# T21 review, fix 4: the reachability half is read PER NAME. One alternation
# over every record type was satisfied by any single name still being present,
# so renaming `GraphRevision.new` in scribe.rb left both examples green and the
# placement guard for that record evaporated in silence -- which is the exact
# failure this second example exists to prevent. The refusal message is built
# from the same list, so a name added here cannot go unnamed in the diagnosis.
RSpec.describe "the epic tier's journal records have one writer" do
  def records = %w[IssueTransition StageTransition GraphRevision]

  def constructor_call(record) = /\b#{record}\.new\b/

  def lib_root = Pathname(__dir__).join("..", "..", "..", "lib").expand_path

  def scribe = lib_root.join("lain", "epic", "scribe.rb")

  def constructed_elsewhere(record)
    lib_root.glob("**/*.rb").reject { |file| file == scribe }
                            .select { |file| constructor_call(record).match?(file.read) }
                            .map { |file| "  #{record}.new in #{file.relative_path_from(lib_root)}" }
  end

  it "is called only from lib/lain/epic/scribe.rb" do
    offenders = records.flat_map { |record| constructed_elsewhere(record) }

    expect(offenders).to be_empty, lambda {
      "#{records.map { |record| "#{record}.new" }.join("/")} must be called only from " \
        "lib/lain/epic/scribe.rb -- the write-side guard is checked in exactly " \
        "one place. Found in:\n#{offenders.join("\n")}"
    }
  end

  it "confirms every constructor is still reachable, so a rename cannot silently pass this spec" do
    unreachable = records.reject { |record| constructor_call(record).match?(scribe.read) }

    expect(unreachable).to be_empty, lambda {
      "#{unreachable.join("/")} is constructed nowhere in scribe.rb any more -- the placement guard " \
        "above now guards nothing for it, silently"
    }
  end
end
