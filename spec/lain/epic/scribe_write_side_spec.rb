# frozen_string_literal: true

require "pathname"

# T4 review, fix 3: "nothing else in lib may construct these records" is
# stated three times across scribe.rb and records.rb, and it is true today --
# but nothing kept it true. Mechanical enforcement, in the shape
# spec/output_discipline_spec.rb and spec/lain/event_spec.rb's "no Turn
# constant remains" already use for their own closed invariants: scan the
# source rather than trust a comment to stay accurate as the codebase grows.
#
# A textual scan, not an AST walk, because the invariant IS textual: the two
# constructors are named exactly once, by name, the same way
# Refold::SLUG_TYPES names its record types by their JOURNAL_TYPE strings
# rather than by structural shape.
RSpec.describe "Epic::IssueTransition / Epic::StageTransition have one writer" do
  def constructor_call = /\b(?:IssueTransition|StageTransition)\.new\b/

  def lib_root = Pathname(__dir__).join("..", "..", "..", "lib").expand_path

  it "is called only from lib/lain/epic/scribe.rb" do
    offenders = lib_root.glob("**/*.rb").select do |file|
      file.relative_path_from(lib_root).to_s != "lain/epic/scribe.rb" && constructor_call.match?(file.read)
    end

    expect(offenders).to be_empty, lambda {
      listing = offenders.map { |file| "  #{file.relative_path_from(lib_root)}" }.join("\n")
      "IssueTransition.new/StageTransition.new must be called only from " \
        "lib/lain/epic/scribe.rb -- the write-side guard is checked in exactly " \
        "one place. Found in:\n#{listing}"
    }
  end

  it "confirms the constructors are still reachable, so a rename cannot silently pass this spec" do
    expect(constructor_call.match?(lib_root.join("lain", "epic", "scribe.rb").read)).to be(true)
  end
end
