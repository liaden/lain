# frozen_string_literal: true

require "async"

# T13: /inbox at `you>` delegates ENTIRELY to Command::Env's `replies` reader
# (the SAME HumanReplies#drain_at_prompt human_replies_spec.rb covers) -- this
# command owns only the argument-free call, never a second listing/answer
# path or a second rendering of what the drain already showed through @tty.
#
# The last example documents the T13 escalation instead of asserting a fix:
# StatusFeed's inbox_count is Projection-parity-pinned (see
# status_feed_spec.rb and Frontend::Neovim::InboxView's parity spec) to
# retire ONLY on a committed :turn's causal_parents, and that :turn Event
# never reaches the live tee in production (status_feed.rb's class doc, T13
# note) -- so answering here, exactly like answering at `human>`, does NOT
# retire the count by itself. Hand-back flags this as the known constraint
# rather than forking a second counter or breaking the parity spec.
RSpec.describe Lain::CLI::Command::Inbox do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:tty_output) { StringIO.new }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: tty_output, input: StringIO.new,
                            history_path: File.join(@dir, "history"))
  end
  let(:status_feed) { Lain::StatusFeed.new(path: File.join(@dir, "state.json")) }
  let(:store) { Lain::Store.new }
  let(:parent) { Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }]) }
  let(:ask_human) { Lain::Tools::AskHuman.new(parent:, observer: ->(event) { status_feed << event }) }
  let(:questions) { Async::Queue.new }
  let(:conductor) { double("conductor") }
  let(:replies) { Lain::CLI::HumanReplies.new(tty:, conductor:, ask_human:, questions:) }
  let(:command) { described_class.new }

  def env_with(replies:, status: Lain::CLI::Command::Env::NullStatus)
    Lain::CLI::Command::Env.new(
      status:, sessions: instance_double(Lain::CLI::Sessions),
      approvals: Lain::CLI::Command::Env::NullApprovals, supervisor: Lain::Supervisor::Null,
      replies:, fork_point: Lain::CLI::Command::Env::NullForkPoint,
      tmux_surface: instance_double(Lain::CLI::TmuxSurface), agent: double("agent"),
      policy_switch: Lain::CLI::Command::Env::NullPolicySwitch,
      model_switch: Lain::CLI::Command::Env::NullModelSwitch, chronicle: Lain::CLI::Chronicle::Null.new
    )
  end

  it "runs the same drain UX HumanReplies exposes for human> -- TTY renders it, the command adds nothing" do
    Sync do
      ask_human.ask("two pending?")
      questions.enqueue("two pending?")
      allow(conductor).to receive(:read_reply).and_return("yes")

      text = command.call("", env_with(replies:))

      # nil: the drain already delivered the listing + read through @tty
      # (asserted below); a returned String here would render a second,
      # redundant confirmation over the one the drain just printed.
      expect(text).to be_nil
      expect(tty_output.string).to include("two pending?")
      expect(ask_human.last_answer.body["answer"]).to eq("yes")
    end
  end

  it "answers honestly (via the TTY drain's own empty-state render) when nothing is pending" do
    text = command.call("", env_with(replies:))

    expect(text).to be_nil
    expect(tty_output.string).to include("no questions pending")
  end

  # AC ("answered items retire from StatusFeed's count"), as delivered: the
  # A message DOES reach the live StatusFeed (same ChainWriter observer the
  # Q rode), but per Projection/InboxView parity it is lineage, not
  # consumption, so the count is UNCHANGED right after the reply -- matching
  # exactly what typing the same answer at `human>` would do. Retiring in
  # real time needs a live :turn signal StatusFeed cannot see at its
  # construction point (see the class doc's T13 note); escalated in the
  # hand-back, not solved here by diverging from the parity spec.
  it "does not retire on the reply alone -- the pre-existing, escalated gap, unchanged by this card" do
    Sync do
      ask_human.ask("q1?")
      expect(status_feed.state["inbox_count"]).to eq(1)
      questions.enqueue("q1?")
      allow(conductor).to receive(:read_reply).and_return("42")

      command.call("", env_with(replies:, status: status_feed))

      expect(status_feed.state["inbox_count"]).to eq(1)
    end
  end

  it "answers a one-line usage, and the command file itself never prints (only TTY, the exempted frontend, does)" do
    text = :unset
    expect { text = command.call("", env_with(replies:)) }.not_to output.to_stdout
    expect(text).to be_nil
    expect(command.usage).to start_with("/inbox")
  end
end
