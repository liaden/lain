# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../.rubocop/lain"

# CopHelper and ExpectOffense are included in this group alone: rubocop/rspec/support
# includes them in every group of whichever parallel worker loads this file.
RSpec.describe RuboCop::Cop::Lain::SdkRequire do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }
  let(:ruby_version) { 3.2 }
  let(:cop) { described_class.new(config) }

  it "flags an SDK constant in a file that never requires the gem, and says what to add" do
    offenses = expect_offense(<<~RUBY, "spec/x_spec.rb")
      raise Anthropic::Errors::APIError, "x"
            ^^^^^^^^^^^^^^^^^ `Anthropic::Errors` is the anthropic SDK, which loads lazily, [...]
    RUBY

    expect(offenses.map(&:message)).to all(include('require "anthropic"'))
  end

  it "flags a string-named double, which would otherwise verify nothing" do
    expect_offense(<<~RUBY)
      instance_double("Anthropic::BedrockMantleClient")
                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `Anthropic::BedrockMantleClient` is the anthropic SDK, which loads lazily, [...]
    RUBY
  end

  it "reports once, on the first reference" do
    expect_offense(<<~RUBY)
      Anthropic::Client.new
      ^^^^^^^^^^^^^^^^^ `Anthropic::Client` is the anthropic SDK, which loads lazily, [...]
      Anthropic::Models::Message
    RUBY
  end

  it "accepts a file that requires the gem, wherever the require sits" do
    expect_no_offenses(<<~RUBY)
      Anthropic::Errors::APIError
      require "anthropic"
    RUBY
  end

  it "ignores a comment, and the project's own Anthropic constants" do
    expect_no_offenses(<<~RUBY)
      # Anthropic::Errors::APIError is raised by the SDK
      Lain::Provider::Anthropic::Client
      Provider::Anthropic::Errors
      Anthropic::Other
    RUBY
  end

  it "still reads a string literal holding bytes that are not UTF-8" do
    expect_offense(<<~'RUBY')
      bytes = "\xFF Anthropic::Errors"
              ^^^^^^^^^^^^^^^^^^^^^^^^ `\xFF Anthropic::Errors` is the anthropic SDK, [...]
    RUBY
  end
end
