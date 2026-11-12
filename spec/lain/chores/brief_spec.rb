# frozen_string_literal: true

RSpec.describe Lain::Chores::Brief do
  def item(line) = Lain::Chores::Item.parse(line)

  it "asks for the chore and a commit of it" do
    brief = described_class.for(item("- [ ] add a spec for Foo#bar"))

    expect(brief).to include("add a spec for Foo#bar").and match(/\bcommit\b/)
  end

  it "runs the research skill on a research item, and asks for the report committed so the drain can land it" do
    brief = described_class.for(item("- [ ] [research] compare x and y"))

    expect(brief).to start_with("/research compare x and y\n")
    expect(brief.lines.drop(1).join).to match(/\bcommit\b/i).and match(/\breport\b/).and match(/\bland\b/)
  end

  it "briefs an item under any other tag as a plain chore" do
    expect(described_class.for(item("- [ ] [docs] tidy the README"))).to include("tidy the README", "commit")
  end
end
