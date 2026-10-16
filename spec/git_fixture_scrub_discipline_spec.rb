# frozen_string_literal: true

require "prism"

# A commit hook in a linked worktree exports GIT_DIR, and a fixture's bare
# `git init` under it reinitializes the worktree's admin dir as a BARE repository
# in the config every worktree shares; a fixture's `update-index` rewrites that
# worktree's index. On main the hook exports no GIT_DIR, so nothing shows until
# a commit is made from a worktree. A git call that takes no environment first
# inherits the hook's, so every one passes `SeedRepo::SCRUB`.
module GitFixtureScrub
  SPAWNERS = %i[capture2 capture2e capture3 popen2 popen2e popen3 system spawn].freeze

  # Each spawn of git whose first argument is the program rather than an environment.
  class Finder < Prism::Visitor
    attr_reader :unscrubbed

    def initialize
      super
      @unscrubbed = []
    end

    def visit_call_node(node)
      @unscrubbed << node.location.start_line if inherits_environment?(node)
      super
    end

    private

    def inherits_environment?(node)
      first = node.arguments&.arguments&.first
      SPAWNERS.include?(node.name) && first.is_a?(Prism::StringNode) && first.unescaped == "git"
    end
  end

  def self.violations(root)
    Dir.glob("**/*.rb", base: root).sort.flat_map do |path|
      finder = Finder.new
      Prism.parse_file(File.join(root, path)).value.accept(finder)
      finder.unscrubbed.map { |line| "spec/#{path}:#{line}" }
    end
  end
end

RSpec.describe "git fixtures in spec/" do
  it "pass an environment to every git they spawn" do
    expect(GitFixtureScrub.violations(__dir__)).to be_empty
  end
end
