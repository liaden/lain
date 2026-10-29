# frozen_string_literal: true

require "pathname"

# The config.rb section of docs/commands.md is the only place a user learns
# the DSL, and Ruby in prose rots silently: a renamed verb or a refused key
# leaves an example that no one runs. Each block is evaluated as the user's
# file would be, against every verb the project file accepts.
RSpec.describe "docs/commands.md Configuration (config.rb) examples" do
  doc = Pathname.new(File.expand_path("..", __dir__)).join("docs/commands.md").read
  section = doc[/^## Configuration \(config\.rb\)\n(.*?)(?=^## |\z)/m, 1].to_s
  theme = section[/^### theme\n(.*?)(?=^### |\z)/m, 1].to_s
  user_blocks = theme.scan(/^```ruby\n(.*?)^```$/m).flatten
  blocks = section.scan(/^```ruby\n(.*?)^```$/m).flatten - user_blocks

  it "finds the section and some examples in it" do
    expect(blocks.size).to be > 3
  end

  blocks.each_with_index do |source, index|
    it "evaluates example #{index + 1} without raising" do
      expect { Lain::Config::Builder.evaluate(source, path: "docs/commands.md") }.not_to raise_error
    end
  end

  it "finds an example in the theme subsection" do
    expect(user_blocks).not_to be_empty
  end

  user_blocks.each_with_index do |source, index|
    it "evaluates theme example #{index + 1} as the user's config.rb" do
      expect { Lain::Config::Builder.evaluate(source, path: "docs/commands.md", verbs: Lain::Config::Builder::USER_VERBS) }
        .not_to raise_error
    end

    it "refuses theme example #{index + 1} in a project's config.rb" do
      expect { Lain::Config::Builder.evaluate(source, path: "docs/commands.md") }
        .to raise_error(Lain::Config::Refusal, /belongs in the user's config\.rb/)
    end
  end

  it "shows a registration for every middleware area" do
    areas = blocks.flat_map { |source| source.scan(/^\s+(model|tool|turn|repl|http)\b/).flatten.map(&:to_sym) }
    expect(areas.uniq).to match_array(Lain::Config::Middleware::AREAS)
  end

  it "names the user-level trust command" do
    expect(section).to include("lain trust --user")
  end
end
