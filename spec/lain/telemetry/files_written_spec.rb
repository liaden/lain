# frozen_string_literal: true

RSpec.describe Lain::Telemetry::FilesWritten do
  subject(:record) { described_class.new(role: "lain", paths: ["lib/a.rb", "frugirl/research.md"]) }

  it "carries the role that wrote and the display paths" do
    expect(record).to have_attributes(role: "lain", paths: ["lib/a.rb", "frugirl/research.md"])
  end

  it "journals under its own type with every field" do
    expect(record.to_journal).to include("type" => "files_written", "role" => "lain",
                                         "paths" => ["lib/a.rb", "frugirl/research.md"])
  end

  it "is shareable across Ractors, like every other journaled value" do
    expect(described_class.new(role: +"lain", paths: [+"lib/a.rb"])).to be_deeply_frozen
  end
end
