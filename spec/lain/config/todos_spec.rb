# frozen_string_literal: true

RSpec.describe Lain::Config::Todos do
  it "defaults to TODOS.md" do
    expect(described_class.empty.file).to eq("TODOS.md")
  end

  it "reads a declared file name" do
    expect(described_class.from({ "file" => "CHORES.md" }, path: "/p/config.rb:1").file).to eq("CHORES.md")
  end

  it "refuses an unknown key, naming it" do
    expect { described_class.from({ "path" => "x" }, path: "/p/config.rb:2") }
      .to raise_error(Lain::Config::Refusal, %r{\A/p/config\.rb:2: .*"path".*known keys: file})
  end

  ["sub/CHORES.md", "../CHORES.md", "", ".", "..", 3].each do |bad|
    it "refuses #{bad.inspect}, which is not a bare file name" do
      expect { described_class.from({ "file" => bad }, path: nil) }
        .to raise_error(Lain::Config::Refusal, /file must be a bare file name/)
    end
  end

  it "refuses a non-table, naming the table and the file's line" do
    expect { described_class.from("x", path: "/p/config.rb:1") }
      .to raise_error(Lain::Config::Refusal,
                      %r{`todos`.*must be a table.*/p/config.rb:1|/p/config.rb:1.*`todos`.*must be a table}m)
  end
end
