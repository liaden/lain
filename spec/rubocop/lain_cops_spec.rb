# frozen_string_literal: true

require "open3"
require "rubocop"
require_relative "../../.rubocop/lain"

# What a Lain cop cannot say about itself: that its config scopes it to real files,
# that its exemptions are the reviewed ones, and that no file opts out inline.
module LainCops
  ROOT = File.expand_path("../..", __dir__)

  # Each entry is a place a rule is broken on purpose, so a new one edits this file
  # as well as .rubocop.yml and shows up in review twice.
  EXEMPTIONS = {
    "Lain/TerminalOutput" => ["lib/lain/frontend/**/*", "lib/lain/daemon/spawner.rb"]
  }.freeze

  # An inline directive naming a Lain cop, the whole department, or every cop.
  INLINE_ESCAPE = "rubocop:(disable|todo)[^#]*[ ,](Lain(/|,| |$)|all( |,|$))"
  RUBY_PATHS = %w[*.rb *.rake *.gemspec Gemfile Rakefile exe/* bin/*].freeze

  module_function

  def cops = RuboCop::Cop::Registry.global.select { |cop| cop.department == :Lain }

  # RuboCop keeps a cop's Include as written and makes its Exclude absolute.
  def relative(patterns) = Array(patterns).map { |pattern| pattern.delete_prefix("#{ROOT}/") }

  def git(*) = Open3.capture2(SeedRepo::SCRUB, "git", *, chdir: ROOT).first
end

RSpec.describe "the Lain cops" do
  let(:config) { RuboCop::ConfigLoader.configuration_from_file(File.join(LainCops::ROOT, ".rubocop.yml")) }
  let(:tracked) { LainCops.git("ls-files").lines(chomp: true) }

  it "pins an exemption list for exactly the registered cops" do
    expect(LainCops.cops.map(&:cop_name)).to match_array(LainCops::EXEMPTIONS.keys)
  end

  # One example per guarantee, so a new cop changes no example count.
  it "enables every Lain cop and scopes each to at least 1 tracked file", :aggregate_failures do
    LainCops.cops.each do |cop|
      globs = LainCops.relative(config.for_cop(cop)["Include"])
      scanned = tracked.any? { |path| globs.any? { |glob| RuboCop::PathUtil.match_path?(glob, path) } }

      expect(config.cop_enabled?(cop.cop_name)).to be(true), "#{cop.cop_name} is disabled"
      expect(scanned).to be(true), "#{cop.cop_name}'s Include #{globs} matches no tracked file"
    end
  end

  it "exempts only what each Lain cop's pinned list names", :aggregate_failures do
    LainCops.cops.each do |cop|
      excluded = LainCops.relative(config.for_cop(cop)["Exclude"])

      expect(cop.cop_name => excluded).to eq(cop.cop_name => LainCops::EXEMPTIONS[cop.cop_name])
    end
  end

  it "has no tracked file opting out of a Lain cop inline" do
    escapes = LainCops.git("grep", "-n", "-E", LainCops::INLINE_ESCAPE, "--", *LainCops::RUBY_PATHS)

    expect(escapes).to be_empty, "Add the file to .rubocop.yml's Exclude with its reason instead:\n#{escapes}"
  end
end
