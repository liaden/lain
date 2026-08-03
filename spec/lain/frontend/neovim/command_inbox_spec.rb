# frozen_string_literal: true

# The editor's command rail, from the consumer's side. Reached the way its
# consumer reaches it -- through #command_inbox -- because that is the whole
# claim: ONE object holds both directions of the one conversation. Nothing here
# attaches; RpcThread touches nvim only in #start.
#
# Moved out of rpc_thread_spec.rb when the class moved out of neovim.rb (T12
# re-work): its own file, beside its own object.
RSpec.describe Lain::Frontend::Neovim::CommandInbox do
  subject(:inbox) { frontend.command_inbox }

  let(:frontend) { Lain::Frontend::Neovim.new(channel: Lain::Channel.new, socket_path: "/nonexistent.sock") }

  it "says an editor is attached, which is the whole of the question a consumer asks" do
    expect(inbox).to be_attached
  end

  it "forwards a non-blocking pop to the queue the RPC thread fills" do
    expect { inbox.pop(true) }.to raise_error(ThreadError)

    frontend.instance_variable_get(:@rpc).command_inbox.push(["reply", ["yes"]])

    expect(inbox.pop(true)).to eq(["reply", ["yes"]])
  end

  # The refusal leg: a done gesture the consumer could not honour goes BACK to
  # the editor, over the render rail, because that is where the gesture came
  # from. Two objects for one conversation is what this adapter exists to spare
  # every consumer.
  it "sends a refusal back over the render rail" do
    session = instance_double(Neovim::Session)
    client = instance_double(Neovim::Client, session:)
    allow(session).to receive(:notify)

    inbox.review_refused("review generation 7 is not open")
    frontend.instance_variable_get(:@rpc).instance_variable_get(:@inlet).drain(client)

    expect(session).to have_received(:notify).with("nvim_exec_lua",
                                                   Lain::Frontend::Neovim::RenderQueue::REVIEW_REFUSED,
                                                   ["review generation 7 is not open"])
  end

  # The third direction (T12): an answer lain produced ITSELF, from the editor's
  # write, joining the same rail rather than a private path only it knows about.
  it "puts a locally answered question set on the same rail, as [verb, one array of args]" do
    answers = Lain::Question::AnswerSet.new(
      questions: Lain::Question::Set.new(questions: [Lain::Question.new(id: "q", body: "why?")])
    )

    inbox.answered("blake3:c0ffee", answers)

    expect(inbox.pop(true)).to eq(["question_answered", ["blake3:c0ffee", answers]])
  end
end
