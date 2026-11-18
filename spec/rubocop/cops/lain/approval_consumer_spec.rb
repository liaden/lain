# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../.rubocop/lain"

# CopHelper and ExpectOffense are included in this group alone: rubocop/rspec/support
# includes them in every group of whichever parallel worker loads this file.
RSpec.describe RuboCop::Cop::Lain::ApprovalConsumer do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  let(:allowed) { { "lib/lain/x.rb" => ["questions"] } }
  let(:config) do
    RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false },
                        "Lain/ApprovalConsumer" => { "AllowedReceivers" => allowed })
  end
  let(:ruby_version) { 3.2 }
  let(:cop) { described_class.new(config) }

  it "flags a dequeue on a receiver nobody ruled on, naming it and saying what to do" do
    offenses = expect_offense(<<~RUBY, "lib/lain/x.rb")
      decide(parked.dequeue)
             ^^^^^^^^^^^^^^ `parked.dequeue` drains a queue nobody has ruled on. [...]
    RUBY

    expect(offenses.map(&:message)).to all(include("Queue#each", "AllowedReceivers"))
  end

  it "flags an instance variable and a receiver it cannot name" do
    expect_offense(<<~RUBY, "lib/lain/x.rb")
      loop { decide(@approvals.dequeue) }
                    ^^^^^^^^^^^^^^^^^^ `@approvals.dequeue` drains a queue nobody has ruled on. [...]
      queues.first&.dequeue(timeout: 0)
      ^^^^^^^^^^^^^^^^^^^^^ `(unreadable receiver).dequeue` drains a queue nobody has ruled on. [...]
    RUBY
  end

  it "clears a receiver ruled on for its own file only" do
    expect_no_offenses("questions.dequeue(timeout: 0)\n", "lib/lain/x.rb")
    expect_offense(<<~RUBY, "lib/lain/y.rb")
      questions.dequeue(timeout: 0)
      ^^^^^^^^^^^^^^^^^ `questions.dequeue` drains a queue nobody has ruled on. [...]
    RUBY
  end

  it "flags a namespaced constant as a receiver it cannot name" do
    expect_offense(<<~RUBY, "lib/lain/x.rb")
      Foo::Bar.dequeue
      ^^^^^^^^^^^^^^^^ `(unreadable receiver).dequeue` drains a queue nobody has ruled on. [...]
    RUBY
  end

  it "leaves a bare dequeue alone, since it drains no other object's queue" do
    expect_no_offenses("dequeue\ndequeue(timeout: 0)\n", "lib/lain/x.rb")
  end

  it "reads the syntax tree, so prose, strings and symbols are not consumers" do
    expect_no_offenses(<<~RUBY, "lib/lain/x.rb")
      # a comment about approvals.dequeue
      x = "@approvals.dequeue in a string"
      :dequeue
    RUBY
  end

  describe "through the real .rubocop.yml" do
    let(:root) { File.expand_path("../../../..", __dir__) }
    let(:config) { RuboCop::ConfigLoader.configuration_from_file(File.join(root, ".rubocop.yml")) }

    it "lets the approval surface that can ask a person drain its queue" do
      expect_no_offenses("loop { asked(queue.dequeue) }\n", File.join(root, "lib/lain/frontend/approval_policy.rb"))
    end

    # Each entry is a ruling that a dequeue site drains something other than a second
    # approval consumer, so a new one edits this file as well and shows up in review twice.
    it "rules on exactly the reviewed receivers" do
      expect(config.for_cop("Lain/ApprovalConsumer")["AllowedReceivers"]).to eq(
        "lib/lain/approval/parked/queue.rb" => ["@arrivals"],
        "lib/lain/frontend/approval_policy.rb" => ["queue"],
        "lib/lain/cli/human_replies.rb" => %w[@questions queue],
        "lib/lain/bench/approval_replay/stack.rb" => ["@replay_queue"]
      )
    end
  end
end
