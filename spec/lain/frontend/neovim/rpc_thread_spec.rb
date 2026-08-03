# frozen_string_literal: true

require "timeout"

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

    it "refuses a question write" do
      expect { listener.question_written(["line"], "blake3:x") }
        .to raise_error(NotImplementedError, /must implement #question_written/)
    end

    it "refuses a question abandon" do
      expect { listener.question_abandoned("blake3:x") }
        .to raise_error(NotImplementedError, /must implement #question_abandoned/)
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
    expect(null.question_abandoned("blake3:x")).to be_nil
  end

  # The ONE hand-off a Null cannot answer with silence. `bufhidden = "hide"`
  # means a lain://question buffer OUTLIVES the attach that made it, so a write
  # really can arrive at a frontend wiring no view -- and nil there means "taken"
  # to the editor, which clears 'modified' and drops the human's text as saved.
  it "refuses a question write rather than claiming it was taken" do
    expect(null.question_written(["line"], "blake3:x")).to eq(described_class::UNANSWERABLE)
    expect(described_class::UNANSWERABLE).to include("no question")
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
    expect(inlet.open_question(["## `q` (choose one)"], "blake3:c0ffee")).to be_nil
    expect(inlet.open_review("/epics/alpha/epic.md", 7, "alpha")).to be_nil
    expect(inlet.review_refused("generation 7 is not open")).to be_nil
    expect(wakes.size).to eq(6)
  end

  # An editor that stopped draining and an editor that died are ONE fact from a
  # caller's side: nobody is taking this. What each open ANSWERS is not one
  # sentence, though -- a human trying to answer a question was being told
  # "composing needs an attached editor", and the same defect was one caller
  # over on the review open. The refusal is now the caller's own word, and there
  # is no default to inherit the wrong one from.
  def refusals(inlet)
    { compose: inlet.open_compose(["draft"], 1),
      question: inlet.open_question(["## `q` (choose one)"], "blake3:c0ffee"),
      review: inlet.open_review("/epics/alpha/epic.md", 1, "alpha"),
      refusal: inlet.review_refused("nobody will read this") }
  end

  def own_words
    { compose: Lain::Frontend::Neovim::Compose::DETACHED,
      question: Lain::Frontend::Neovim::QuestionView::DETACHED,
      review: described_class::REVIEW_DETACHED,
      refusal: described_class::UNREPORTED }
  end

  it "refuses all four opens in their own words when the queue is full" do
    inlet = described_class.new(waker:, capacity: 1)
    inlet.post_render(["fills the one slot"])

    expect(refusals(inlet)).to eq(own_words)
  end

  it "refuses all four opens in their own words once the loop is gone" do
    inlet = described_class.new(waker:, capacity: 8)
    inlet.close

    expect(refusals(inlet)).to eq(own_words)
  end

  # The four sentences are four, and each names the surface the human was
  # actually using -- which is the whole reason the refusal is a parameter.
  it "gives every surface a distinct sentence" do
    expect(own_words.values.uniq.size).to eq(4)
  end

  # {QuestionView} posts from INSIDE its own lock, so a blocking push here
  # would hold that lock against a full queue -- and the same lock is what the
  # editor's write takes. A blocking `push` passes every end-to-end spec in the
  # repo, so the flag is pinned where it can actually be observed: a full queue
  # must ANSWER, in bounded time, rather than park this thread.
  it "refuses a question open without ever blocking on a full queue" do
    inlet = described_class.new(waker:, capacity: 1)
    inlet.post_render(["fills the one slot"])

    answered = Timeout.timeout(2) { inlet.open_question(["## `q` (choose one)"], "blake3:c0ffee") }

    expect(answered).to eq(Lain::Frontend::Neovim::QuestionView::DETACHED)
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

  it "sends a question-open render command carrying the buffer, the document and the digest" do
    queue = described_class.new
    session = instance_double(Neovim::Session)
    client = instance_double(Neovim::Client, session:)
    allow(session).to receive(:notify)

    queue.post_question("lain://question", ["## `q` (choose one)"], "blake3:c0ffee")
    queue.drain(client)

    expect(session).to have_received(:notify).with(
      "nvim_exec_lua", described_class::SET_QUESTION,
      ["lain://question", ["## `q` (choose one)"], "blake3:c0ffee"]
    )
  end

  # The flag itself, at the object that carries it: every OTHER producer here is
  # a background thread that can afford back-pressure, and this one is not.
  it "raises rather than parking a producer when the queue is full" do
    queue = described_class.new(capacity: 1)
    queue.post_render(["fills the one slot"])

    expect { Timeout.timeout(2) { queue.post_question("lain://question", ["a"], "blake3:c0ffee") } }
      .to raise_error(ThreadError)
  end
end

# The inbound half's ONE ordering rule, and the only place in the frontend
# where a Ruby exception can freeze the human's editor. Driven through the
# private #dispatch with a stub client, because what is being pinned is
# precisely what reaches the SESSION and in what order -- an attach would
# only put a real socket between the assertion and the thing asserted.
RSpec.describe Lain::Frontend::Neovim::RpcThread, "#dispatch" do
  subject(:rpc) { described_class.new(socket_path: "/nonexistent.sock", listener:) }

  let(:listener) { Lain::Frontend::Neovim::RpcThread::Listener::Null.new }
  let(:session) { instance_double(Neovim::Session, respond: nil) }
  let(:connection) { instance_double(Neovim::Connection, flush: nil) }
  let(:client) { instance_double(Neovim::Client, session:) }

  before do
    rpc.instance_variable_set(:@client, client)
    rpc.instance_variable_set(:@connection, connection)
  end

  def request(*arguments)
    instance_double(Neovim::Message::Request, id: 7, method_name: "lain_command", arguments:)
  end

  def dispatch(*arguments) = rpc.send(:dispatch, request(*arguments))

  # The ACKED shape, restated here as the contrast: the answer goes out before
  # the route runs, so no hand-off can delay -- or fail -- the editor.
  it "acks an ordinary command and only then routes it" do
    dispatch("reply", ["yes"])

    expect(session).to have_received(:respond).with(7, true, nil)
    expect(rpc.command_inbox.pop(true)).to eq(["reply", ["yes"]])
  end

  it "answers a question write with the verdict its listener returned" do
    allow(listener).to receive(:question_written).and_return(nil)

    dispatch("question", ["## `q` (choose one)"], "blake3:c0ffee")

    expect(listener).to have_received(:question_written).with(["## `q` (choose one)"], "blake3:c0ffee")
    expect(session).to have_received(:respond).with(7, true, nil)
  end

  it "fails the write with the refusal its listener returned, and keeps it out of the inbox" do
    allow(listener).to receive(:question_written).and_return("line 6: nothing here is an option line")

    dispatch("question", ["garbage"], "blake3:c0ffee")

    expect(session).to have_received(:respond).with(7, nil, "line 6: nothing here is an option line")
    expect { rpc.command_inbox.pop(true) }.to raise_error(ThreadError)
  end

  # The hole this rescue closes, measured: with the answer running BEFORE the
  # ack, a raising listener left nvim blocked in `vim.rpcrequest` for >20s --
  # main loop frozen, the human unable to type -- and it only unblocked when
  # the whole session tore down. The editor gets an answer first, ALWAYS. The
  # raise still goes on to kill the thread, because a swallowed bug on this
  # path is the other way to lose a session quietly.
  it "answers the editor before letting a raising listener kill the thread" do
    allow(listener).to receive(:question_written).and_raise(NoMethodError, "undefined method 'foo' for nil")

    expect { dispatch("question", ["## `q` (choose one)"], "blake3:c0ffee") }.to raise_error(NoMethodError)

    expect(session).to have_received(:respond).with(7, nil, a_string_matching(/NoMethodError.*nothing was submitted/m))
  end

  it "refuses a request that is not a lain command at all" do
    other = instance_double(Neovim::Message::Request, id: 9, method_name: "nvim_buf_attach", arguments: [])

    rpc.send(:dispatch, other)

    expect(session).to have_received(:respond).with(9, nil, /unknown request nvim_buf_attach/)
  end
end

# The verb table, on its own: which commands are ACKED and which one ANSWERS.
RSpec.describe Lain::Frontend::Neovim::Router do
  subject(:router) { described_class.new(listener:) }

  let(:listener) { Lain::Frontend::Neovim::RpcThread::Listener::Null.new }

  it "names the question write as the one command whose route answers the editor" do
    expect(router).to be_answers("question")
    %w[reply resend compose compose_abandon question_abandon review_done].each do |verb|
      expect(router).not_to be_answers(verb)
    end
  end

  it "hands the write's verdict straight back from the listener" do
    allow(listener).to receive(:question_written).and_return("line 6: no")

    expect(router.answer(["question", ["garbage"], "blake3:c0ffee"])).to eq("line 6: no")
  end

  it "routes an abandon as an ordinary acked verb, carrying the digest" do
    allow(listener).to receive(:question_abandoned)

    router.call(["question_abandon", "blake3:c0ffee"])

    expect(listener).to have_received(:question_abandoned).with("blake3:c0ffee")
  end

  it "ignores a verb no route claims -- the editor's commands are not its to validate" do
    expect(router.call(["not_a_verb", []])).to be_nil
  end
end
