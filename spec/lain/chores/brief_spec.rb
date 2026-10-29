# frozen_string_literal: true

RSpec.describe Lain::Chores::Brief do
  def item(line) = Lain::Chores::Item.parse(line)

  it "asks for the chore and a commit of it" do
    brief = described_class.for(item("- [ ] add a spec for Foo#bar"))

    expect(brief).to include("add a spec for Foo#bar").and match(/\bcommit\b/)
  end

  it "runs the research skill on a research item" do
    expect(described_class.for(item("- [ ] [research] compare x and y"))).to eq("/research compare x and y")
  end

  it "briefs an item under any other tag as a plain chore" do
    expect(described_class.for(item("- [ ] [docs] tidy the README"))).to include("tidy the README", "commit")
  end
end
