# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../.rubocop/lain"

# CopHelper and ExpectOffense are included in this group alone: rubocop/rspec/support
# includes them in every group of whichever parallel worker loads this file.
RSpec.describe RuboCop::Cop::Lain::GitFixtureScrub do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }
  let(:ruby_version) { 3.2 }
  let(:cop) { described_class.new(config) }

  it "flags a git spawn with no environment, and says what to pass" do
    offenses = expect_offense(<<~RUBY, "spec/x_spec.rb")
      Open3.capture3("git", "status")
            ^^^^^^^^ Spawning `git` without `SeedRepo::SCRUB` inherits [...]
    RUBY

    expect(offenses.map(&:message)).to all(include("SeedRepo::SCRUB", "GIT_DIR"))
  end

  it "flags a popen of an argv array, a bare string spawn and a hand-rolled environment" do
    expect_offense(<<~RUBY)
      IO.popen(["git", "ls-files"], &:readlines)
         ^^^^^ Spawning `git` without `SeedRepo::SCRUB` inherits [...]
      system("git", "init")
      ^^^^^^ Spawning `git` without `SeedRepo::SCRUB` inherits [...]
      system({ "GIT_DIR" => nil }, "git", "init")
      ^^^^^^ Spawning `git` without `SeedRepo::SCRUB` inherits [...]
    RUBY
  end

  it "flags a safe-navigation spawn too" do
    expect_offense(<<~RUBY)
      Open3&.capture3("git", "x")
             ^^^^^^^^ Spawning `git` without `SeedRepo::SCRUB` inherits [...]
    RUBY
  end

  it "accepts a scrub constant, bare or merged, in either form" do
    expect_no_offenses(<<~RUBY)
      Open3.capture3(SeedRepo::SCRUB, "git", "status")
      system(SCRUB, "git", "init")
      IO.popen(SeedRepo::SCRUB.merge("A" => "b"), ["git", "ls-files"])
    RUBY
  end

  it "ignores a spawn of another program, and a call that is not a spawn" do
    expect_no_offenses(<<~RUBY)
      system("ls", "-l")
      run("git", "status")
      `git status`
    RUBY
  end
end
