# frozen_string_literal: true

require "prism"

# A commit hook in a linked worktree exports GIT_DIR, and a fixture's bare
# `git init` under it reinitializes the worktree's admin dir as a BARE repository
# in the config every worktree shares; a fixture's `update-index` rewrites that
# worktree's index. On main the hook exports no GIT_DIR, so nothing shows until
# a commit is made from a worktree. A git call that takes no environment first
# inherits the hook's, so every one passes `SeedRepo::SCRUB`. A call site must show the scrub
# constant itself, so an env built from it elsewhere is not seen.
module GitFixtureScrub
  # Backticks, %x and Open3.pipeline* are not scanned.
  SPAWNERS = %i[popen capture2 capture2e capture3 popen2 popen2e popen3 system spawn].freeze

  # Each spawn of git that does not carry a scrub constant as its environment.
  class Finder < Prism::Visitor
    attr_reader :unscrubbed

    def initialize
      super
      @unscrubbed = []
    end

    def visit_call_node(node)
      @unscrubbed << node.location.start_line if SPAWNERS.include?(node.name) && unscrubbed_git?(node)
      super
    end

    private

    def unscrubbed_git?(node)
      arguments = node.arguments&.arguments.to_a
      env, program = arguments.first.then { |first| literal_program?(first) ? [nil, first] : [first, arguments[1]] }
      git_program?(program) && !scrubbed?(env)
    end

    def literal_program?(arg) = arg.is_a?(Prism::StringNode) || arg.is_a?(Prism::ArrayNode)

    def git_program?(arg)
      arg = arg.elements.first if arg.is_a?(Prism::ArrayNode)
      arg.is_a?(Prism::StringNode) && arg.unescaped == "git"
    end

    def scrubbed?(env) = !env.nil? && constant_names(env).any? { |name| name.end_with?("SCRUB") }

    def constant_names(node)
      own = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode) ? [node.name.to_s] : []
      own + node.compact_child_nodes.flat_map { |child| constant_names(child) }
    end
  end

  def self.lines(source)
    Finder.new.tap { |finder| Prism.parse(source).value.accept(finder) }.unscrubbed
  end

  def self.violations(root)
    Dir.glob("**/*.rb", base: root).sort.flat_map do |path|
      lines(File.read(File.join(root, path))).map { |line| "spec/#{path}:#{line}" }
    end
  end
end

RSpec.describe "git fixtures in spec/" do
  it "pass an environment to every git they spawn" do
    expect(GitFixtureScrub.violations(__dir__)).to be_empty
  end

  describe "the scan" do
    def lines(source) = GitFixtureScrub.lines(source)

    it "reports a popen of an argv array with no environment" do
      expect(lines(%(IO.popen(["git", "ls-files"], &:readlines)))).to eq([1])
    end

    it "reports a hand-rolled environment hash" do
      expect(lines(%(system({ "GIT_DIR" => nil }, "git", "init")))).to eq([1])
    end

    it "reports a bare string spawn" do
      expect(lines(%(system("git", "init")))).to eq([1])
    end

    it "accepts a scrub constant, bare or merged, in either form" do
      source = <<~RUBY
        system(SeedRepo::SCRUB, "git", "init")
        IO.popen(SeedRepo::SCRUB.merge("A" => "b"), ["git", "ls-files"])
      RUBY

      expect(lines(source)).to be_empty
    end

    it "ignores a spawn of another program" do
      expect(lines(%(system("ls", "-l")))).to be_empty
    end
  end
end
