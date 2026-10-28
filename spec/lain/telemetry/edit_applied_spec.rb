# frozen_string_literal: true

RSpec.describe Lain::Telemetry::EditApplied do
  subject(:record) { described_class.new(path: "lib/a.rb", removed: ["old"], added: %w[new more], hidden: 0) }

  it "carries the path and the lines each way" do
    expect(record).to have_attributes(path: "lib/a.rb", removed: ["old"], added: %w[new more], hidden: 0)
  end

  it "journals under its own type with every field" do
    expect(record.to_journal).to include("type" => "edit_applied", "path" => "lib/a.rb", "removed" => ["old"],
                                         "added" => %w[new more], "hidden" => 0)
  end

  it "is shareable across Ractors, even when built from mutable strings" do
    expect(described_class.new(path: +"lib/a.rb", removed: [+"old"], added: [+"new"], hidden: 0)).to be_deeply_frozen
  end
end
