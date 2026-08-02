# frozen_string_literal: true

# {RpcThread::Listener}'s own contract, plain Ruby -- no editor needed. The
# round trip that actually WIRES a listener into a live nvim session is the
# :nvim group's job (neovim_spec.rb, neovim_request_spec.rb,
# neovim_runtime_spec.rb); this file pins the abstract base's refusal and
# {Listener::Null}'s no-op answers on their own (T34).
RSpec.describe Lain::Frontend::Neovim::RpcThread::Listener do
  subject(:listener) { described_class.new }

  describe "the abstract base" do
    it "refuses RPC-thread death" do
      expect { listener.died }.to raise_error(NotImplementedError, /must implement #died/)
    end

    it "refuses a resend" do
      expect { listener.resend(["line"]) }.to raise_error(NotImplementedError, /must implement #resend/)
    end

    it "refuses a compose write" do
      expect { listener.compose_written(["line"], 1) }
        .to raise_error(NotImplementedError, /must implement #compose_written/)
    end

    it "refuses a compose abandon" do
      expect { listener.compose_abandoned(1) }
        .to raise_error(NotImplementedError, /must implement #compose_abandoned/)
    end
  end
end

RSpec.describe Lain::Frontend::Neovim::RpcThread::Listener::Null do
  subject(:null) { described_class.new }

  it "answers every hand-off as a silent no-op" do
    expect(null.died).to be_nil
    expect(null.resend(["line"])).to be_nil
    expect(null.compose_written(["line"], 3)).to be_nil
    expect(null.compose_abandoned(3)).to be_nil
  end

  it "is the RpcThread default, so a caller wiring none of the four gets a real duck" do
    rpc = Lain::Frontend::Neovim::RpcThread.new(socket_path: "/nonexistent")

    expect(rpc.instance_variable_get(:@listener)).to be_a(described_class)
  ensure
    rpc&.stop
  end
end

# The outbound door, on its own: queue-and-wake is one act, and what a refused
# post answers is one policy. Both were copied five times inside RpcThread
# before this object existed, and the three refusing copies had already drifted
# into two different answers for one fact.
RSpec.describe Lain::Frontend::Neovim::RenderInlet do
  let(:wakes) { [] }
  let(:waker) { -> { wakes << :woke } }

  it "wakes the loop for every post and answers that it landed" do
    inlet = described_class.new(waker:, capacity: 8)

    expect(inlet.post_render(["a"])).to be_nil
    expect(inlet.post_view("lain://timeline", ["b"])).to be_nil
    expect(inlet.open_compose(["draft"], 3)).to be_nil
    expect(inlet.open_review("/epics/alpha/epic.md", 7, "alpha")).to be_nil
    expect(inlet.review_refused("generation 7 is not open")).to be_nil
    expect(wakes.size).to eq(5)
  end

  # An editor that stopped draining and an editor that died are ONE fact from
  # a caller's side: nobody is taking this. The three non-blocking opens
  # therefore answer the same notice -- open_review said DETACHED while
  # review_refused said nil, which asserted a distinction nothing acted on.
  it "refuses all three opens with one notice when the queue is full" do
    inlet = described_class.new(waker:, capacity: 1)
    inlet.post_render(["fills the one slot"])

    expect(inlet.open_compose(["draft"], 1)).to eq(Lain::Frontend::Neovim::Compose::DETACHED)
    expect(inlet.open_review("/epics/alpha/epic.md", 1, "alpha")).to eq(Lain::Frontend::Neovim::Compose::DETACHED)
    expect(inlet.review_refused("nobody will read this")).to eq(Lain::Frontend::Neovim::Compose::DETACHED)
  end

  it "refuses all three opens with the same notice once the loop is gone" do
    inlet = described_class.new(waker:, capacity: 8)
    inlet.close

    expect(inlet.open_compose(["draft"], 1)).to eq(Lain::Frontend::Neovim::Compose::DETACHED)
    expect(inlet.open_review("/epics/alpha/epic.md", 1, "alpha")).to eq(Lain::Frontend::Neovim::Compose::DETACHED)
    expect(inlet.review_refused("nobody will read this")).to eq(Lain::Frontend::Neovim::Compose::DETACHED)
  end

  # The blocking posts keep raising: a background renderer meeting a dead
  # queue is {Neovim#post}'s to rescue, and swallowing it here would hide the
  # RPC thread's death from the one place that reports it.
  it "lets a render post meet the closed queue rather than answering a notice" do
    inlet = described_class.new(waker:, capacity: 8)
    inlet.close

    expect { inlet.post_render(["a"]) }.to raise_error(ClosedQueueError)
  end

  it "hands the loop everything queued, in order" do
    inlet = described_class.new(waker:, capacity: 8)
    session = instance_double(Neovim::Session)
    client = instance_double(Neovim::Client, session:)
    allow(session).to receive(:notify)
    inlet.open_review("/epics/alpha/epic.md", 7, "alpha")

    inlet.drain(client)

    expect(session).to have_received(:notify).with("nvim_exec_lua",
                                                   Lain::Frontend::Neovim::RenderQueue::OPEN_REVIEW,
                                                   ["/epics/alpha/epic.md", 7, "alpha"])
  end
end

# The editor's command rail, from the consumer's side. Private to the frontend,
# so it is reached the way its consumer reaches it: through #command_inbox.
# Nothing here attaches -- RpcThread touches nvim only in #start.
RSpec.describe "Lain::Frontend::Neovim#command_inbox" do
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
end

RSpec.describe Lain::Frontend::Neovim::RenderQueue do
  it "sends a review-open render command down the sole RPC owner" do
    queue = described_class.new
    session = instance_double(Neovim::Session)
    client = instance_double(Neovim::Client, session:)
    allow(session).to receive(:notify)

    queue.post_review("/epics/alpha/epic.md", 7, "alpha")
    queue.drain(client)

    expect(session).to have_received(:notify).with("nvim_exec_lua", described_class::OPEN_REVIEW,
                                                   ["/epics/alpha/epic.md", 7, "alpha"])
  end
end
