# frozen_string_literal: true

require "timeout"

# The changeset review as the EDITOR's two answering writes see it (T11): the
# far side of {Lain::Frontend::Neovim#bind_changeset_review}, recording what
# reached it and answering whatever verdict an example asked for. The same duck
# {Lain::CLI::HumanReplies} binds for the acked gestures -- a wiring binds one
# object to both rails -- so this records only the two messages this rail sends.
class RecordingReviewWrites
  def initialize(refusal: nil)
    @refusal = refusal
    @wrote = []
  end

  attr_reader :wrote

  def wrote_annotation(note)
    @wrote << [:annotation, note]
    @refusal
  end

  def wrote_verdict(verdict)
    @wrote << [:verdict, verdict]
    @refusal
  end
end

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

    it "refuses a review annotate write" do
      expect { listener.review_annotated({ "side" => "new" }) }
        .to raise_error(NotImplementedError, /must implement #review_annotated/)
    end

    it "refuses a review verdict write" do
      expect { listener.review_verdict_given("approve") }
        .to raise_error(NotImplementedError, /must implement #review_verdict_given/)
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

  # {UNANSWERABLE}'s reason, one surface over: both review writes ANSWER, so nil
  # from a Null would clear 'modified' and report the human's note recorded by a
  # frontend that has nowhere to put it.
  it "refuses both review writes rather than claiming they were recorded" do
    expect(null.review_annotated({ "side" => "new" })).to eq(described_class::UNREVIEWABLE)
    expect(null.review_verdict_given("approve")).to eq(described_class::UNREVIEWABLE)
    expect(described_class::UNREVIEWABLE).to include("no review surface")
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

  # T11's three review entry points are the same door, one capability wider:
  # a queue push and a wake, answering nil when it landed.
  let(:revisions) { { "old" => "base0", "new" => "head1" } }

  it "wakes the loop for every post and answers that it landed" do
    inlet = described_class.new(waker:, capacity: 16)

    expect(inlet.post_render(["a"])).to be_nil
    expect(inlet.post_view("lain://timeline", ["b"])).to be_nil
    expect(inlet.open_compose(["draft"], 3)).to be_nil
    expect(inlet.open_question(["## `q` (choose one)"], "blake3:c0ffee")).to be_nil
    expect(inlet.open_review("/epics/alpha/epic.md", 7, "alpha")).to be_nil
    expect(inlet.review_refused("generation 7 is not open")).to be_nil
    expect(inlet.set_review(["  M lib/lain/agent.rb"], 3)).to be_nil
    expect(inlet.open_changeset("lib/lain/agent.rb", ["was"], 12, revisions)).to be_nil
    expect(inlet.set_thread("anchor-1", ["why this way?"])).to be_nil
    expect(inlet.review_focus).to be_nil
    expect(wakes.size).to eq(10)
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
      refusal: inlet.review_refused("nobody will read this"),
      sidebar: inlet.set_review(["  M lib/lain/agent.rb"], 3),
      changeset: inlet.open_changeset("lib/lain/agent.rb", ["was"], 12, revisions),
      thread: inlet.set_thread("anchor-1", ["why this way?"]),
      focus: inlet.review_focus }
  end

  def own_words
    { compose: Lain::Frontend::Neovim::Compose::DETACHED,
      question: Lain::Frontend::Neovim::QuestionView::DETACHED,
      review: described_class::REVIEW_DETACHED,
      refusal: described_class::UNREPORTED,
      sidebar: described_class::SIDEBAR_DETACHED,
      changeset: described_class::CHANGESET_DETACHED,
      thread: described_class::THREAD_DETACHED,
      focus: described_class::FOCUS_DETACHED }
  end

  it "refuses every open in its own words when the queue is full" do
    inlet = described_class.new(waker:, capacity: 1)
    inlet.post_render(["fills the one slot"])

    expect(refusals(inlet)).to eq(own_words)
  end

  it "refuses every open in its own words once the loop is gone" do
    inlet = described_class.new(waker:, capacity: 8)
    inlet.close

    expect(refusals(inlet)).to eq(own_words)
  end

  # Each sentence names the surface the human was actually using, which is the
  # whole reason the refusal is a parameter rather than one shared default.
  #
  # Counted AGAINST THE TABLE rather than against a literal: a rail added here
  # joins the law by itself, where a hardcoded count is a number somebody has to
  # remember to bump -- and one that was not bumped reads as "still distinct"
  # while saying nothing about the sentence just added.
  it "gives every surface a distinct sentence" do
    expect(own_words.values.uniq.size).to eq(own_words.size)
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
  # T17/F17, and the lua-side `checked_lines` (47_diff, 51_thread) is the
  # convention this matches: `nvim_buf_set_lines` refuses an item containing a
  # newline, and every render here rides `nvim_exec_lua` as a NOTIFY, so the
  # refusal reaches nobody -- the buffer simply stops. A view that breaks the
  # one-line-per-record contract is therefore REFUSED BY NAME, on its own row,
  # rather than laundered into something that reads as the view's own work.
  describe "the one-line-per-record contract" do
    def sent(queue)
      session = instance_double(Neovim::Session)
      allow(session).to receive(:notify)
      queue.drain(instance_double(Neovim::Client, session:))
      session
    end

    it "refuses a multi-line item by name, on its own row, so the rest of the buffer still lands" do
      queue = described_class.new
      queue.post_view("lain://inbox", ["ok", "researcher  3s  which db?\nand why?"])

      expect(sent(queue)).to have_received(:notify).with(
        "nvim_exec_lua", described_class::SET_VIEW,
        ["lain://inbox", ["ok", "[lain://inbox line 2: a rendering broke the one-line-per-record contract]"]]
      )
    end

    # The repair may not be worse than the defect: these bytes reach the views
    # from disk (a manifest path, a reminder), `String#match?` and `String#split`
    # both RAISE on them, and a raise here reaches Neovim#drain's rescue and
    # takes every view dark -- at attach, when it is `prime` that raises.
    it "passes invalid UTF-8 through untouched rather than raising the drain thread down" do
      queue = described_class.new
      queue.post_view("lain://workspace", [(+"reminder caf\xE9 here").force_encoding(Encoding::UTF_8)])

      expect(sent(queue)).to have_received(:notify).with(
        "nvim_exec_lua", described_class::SET_VIEW,
        ["lain://workspace", [(+"reminder caf\xE9 here").force_encoding(Encoding::UTF_8)]]
      )
    end

    # Nothing produces nil lines today; the arity contract below relies on it
    # staying possible to send one, so the check must not be what breaks it.
    it "leaves a nil rendering alone, so the stamp's arity contract is undisturbed" do
      queue = described_class.new
      queue.post_view("lain://timeline", nil)

      expect(sent(queue)).to have_received(:notify).with("nvim_exec_lua", described_class::SET_VIEW,
                                                         ["lain://timeline", nil])
    end
  end

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

  # The sidebar is a SINGLETON in the review's own tabpage, so the lua half
  # names its own buffer and there is no `name` argument to disambiguate one
  # from another -- the difference from {SET_VIEW}, which serves five.
  it "sends a review-sidebar render carrying the lines and the rendering's stamp" do
    queue = described_class.new
    session = instance_double(Neovim::Session)
    client = instance_double(Neovim::Client, session:)
    allow(session).to receive(:notify)

    queue.post_review_sidebar(["  M lib/lain/agent.rb"], 3)
    queue.drain(client)

    expect(session).to have_received(:notify).with("nvim_exec_lua", described_class::SET_REVIEW,
                                                   [["  M lib/lain/agent.rb"], 3])
  end

  # Ruby runs git, never the editor: the old side arrives as LINES this side
  # already read, and the revisions ride along because only Ruby knows which
  # two commits the pair is showing.
  it "sends a changeset open carrying the path, the old side's lines, the target line and both revisions" do
    queue = described_class.new
    session = instance_double(Neovim::Session)
    client = instance_double(Neovim::Client, session:)
    allow(session).to receive(:notify)

    queue.post_changeset("lib/lain/agent.rb", ["was"], 12, { "old" => "base0", "new" => "head1" })
    queue.drain(client)

    expect(session).to have_received(:notify).with(
      "nvim_exec_lua", described_class::OPEN_CHANGESET,
      ["lib/lain/agent.rb", ["was"], 12, { "old" => "base0", "new" => "head1" }]
    )
  end

  it "sends a thread render keyed by the anchor id rather than a line" do
    queue = described_class.new
    session = instance_double(Neovim::Session)
    client = instance_double(Neovim::Client, session:)
    allow(session).to receive(:notify)

    queue.post_thread("anchor-1", ["why this way?"])
    queue.drain(client)

    expect(session).to have_received(:notify).with("nvim_exec_lua", described_class::SET_THREAD,
                                                   ["anchor-1", ["why this way?"]])
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

  # T11's acked half. A mark is a hand-off nothing on this thread answers, so it
  # takes {#acknowledge}'s path exactly as `reply` does: the editor has its
  # answer before any consumer has looked at the command.
  it "acks a review mark and only then routes it" do
    dispatch("review_mark", [4, "reviewed", 3])

    expect(session).to have_received(:respond).with(7, true, nil)
    expect(rpc.command_inbox.pop(true)).to eq(["review_mark", [4, "reviewed", 3]])
  end

  it "acks a review open and a docent question the same way" do
    dispatch("review_open", [4, 3])
    dispatch("review_ask", ["anchor-1", "why this way?"])

    expect(rpc.command_inbox.pop(true)).to eq(["review_open", [4, 3]])
    expect(rpc.command_inbox.pop(true)).to eq(["review_ask", ["anchor-1", "why this way?"]])
  end

  # T11's answered half, and the reason it is answered: a note whose side lain
  # cannot read must fail the `:w`, so the buffer stays modified and the human's
  # words are still theirs to fix.
  it "fails an annotate write naming the side it could not read, and never records it" do
    allow(listener).to receive(:review_annotated)

    dispatch("review_annotate", [annotation("side" => "both")])

    expect(session).to have_received(:respond).with(7, nil, a_string_matching(%r{side must be one of old/new.*both}))
    expect(listener).not_to have_received(:review_annotated)
    expect { rpc.command_inbox.pop(true) }.to raise_error(ThreadError)
  end

  it "answers an annotate write with the verdict its listener returned" do
    allow(listener).to receive(:review_annotated).and_return(nil)

    dispatch("review_annotate", [annotation])

    expect(listener).to have_received(:review_annotated).with(annotation)
    expect(session).to have_received(:respond).with(7, true, nil)
  end

  def annotation(overrides = {})
    { "path" => "lib/lain/agent.rb", "side" => "new", "line" => 12,
      "anchor_text" => "  @store.write(input)", "text" => "why this way?",
      "kind" => "question", "revision" => "d4e5f6", "drifted" => false }.merge(overrides)
  end

  # `NotImplementedError` IS NOT A `StandardError` -- it is a `ScriptError`, and
  # `rescue StandardError` walks straight past it. On the answered path that
  # means the editor is never answered AT ALL, which is the >20s frozen nvim
  # this rescue was written to prevent, reached by the one exception class the
  # rescue could not see. This card widened that surface from one abstract
  # listener method to three, all three on the answered path.
  it "answers the editor even when the listener raises something that is not a StandardError" do
    expect(NotImplementedError.ancestors).not_to include(StandardError)
    allow(listener).to receive(:review_annotated).and_raise(NotImplementedError, "abstract")

    expect { dispatch("review_annotate", [annotation]) }.to raise_error(NotImplementedError)

    expect(session).to have_received(:respond).with(7, nil, a_string_matching(/NotImplementedError.*untouched/m))
  end

  it "does the same for a bare ScriptError, and still lets the death be loud" do
    allow(listener).to receive(:review_verdict_given).and_raise(ScriptError, "nope")

    expect { dispatch("review_verdict", ["approve"]) }.to raise_error(ScriptError)

    expect(session).to have_received(:respond).with(7, nil, a_string_matching(/ScriptError/))
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

  # T11 made it three; T16's settled batch makes it four. The split is wire
  # semantics, not routing convenience: these are the gestures lain can REFUSE,
  # so their route's return value has to be the response.
  it "names the writes whose route answers the editor" do
    %w[question review_annotate review_verdict review_notes].each { |verb| expect(router).to be_answers(verb) }
    %w[reply resend compose compose_abandon question_abandon review_done
       review_open review_mark review_ask].each do |verb|
      expect(router).not_to be_answers(verb)
    end
  end

  describe "an annotate write's wire shape" do
    def annotation(overrides = {})
      { "path" => "lib/lain/agent.rb", "side" => "new", "line" => 12,
        "anchor_text" => "  @store.write(input)", "text" => "why this way?",
        "kind" => "question", "revision" => "d4e5f6", "drifted" => false }.merge(overrides)
    end

    def answer(note) = router.answer(["review_annotate", [note]])

    it "hands a readable note to the listener and returns its verdict" do
      allow(listener).to receive(:review_annotated).and_return(nil)

      expect(answer(annotation)).to be_nil
      expect(listener).to have_received(:review_annotated).with(annotation)
    end

    it "refuses a kind outside the vocabulary, naming what arrived" do
      expect(answer(annotation("kind" => "nit"))).to match(%r{kind must be one of note/question/blocker.*"nit"})
    end

    # The failure this check exists for, and it is not hypothetical: a nil value
    # removes its key from a lua table entirely, and the hole reaching a
    # listener raises on the RPC thread -- which {RpcThread#answer} answers and
    # then RE-RAISES, killing the session over one bookkeeping slip.
    it "refuses a note the wire dropped a key from, rather than letting it raise on this thread" do
      allow(listener).to receive(:review_annotated)

      expect(answer(annotation.except("anchor_text", "text"))).to include("anchor_text, text")
      expect(listener).not_to have_received(:review_annotated)
    end

    # A blank line in a diff IS an anchorable position, so the key's PRESENCE is
    # what is checked; the human's own words are the part nobody can
    # reconstruct, so those are checked for content.
    it "keeps a blank anchor line and refuses a note with nothing in it" do
      allow(listener).to receive(:review_annotated).and_return(nil)

      expect(answer(annotation("anchor_text" => ""))).to be_nil
      expect(answer(annotation("text" => "    "))).to include("nothing in it")
    end

    it "refuses a payload that is not a table at all" do
      expect(router.answer(["review_annotate", ["just a string"]])).to include("must arrive as a table")
    end

    # THE FLAT-POSITIONAL SHAPE, which is what this guard is actually for.
    # `runtime/65_review.lua:75-79` records a verb sending flat positionals and
    # everything after the first being dropped on the floor; T14, T15 and T18
    # write the next three lua halves, so this is the mistake they are most
    # likely to make. A bare String or Integer where the one array belongs used
    # to raise NoMethodError INSIDE the guard whose whole purpose is that the
    # wire can never raise -- and {RpcThread#answer} answers that and re-raises,
    # ending the session over a lua typo.
    it "refuses flat positionals in every verb rather than raising inside the guard" do
      allow(listener).to receive(:review_annotated)
      allow(listener).to receive(:review_verdict_given)

      %w[review_annotate review_verdict review_notes].each do |verb|
        [annotation, "why this way?", 12, nil].each do |flat|
          expect(router.answer([verb, flat])).to include("ONE array"), "#{verb} with #{flat.inspect}"
        end
      end
      expect(listener).not_to have_received(:review_annotated)
      expect(listener).not_to have_received(:review_verdict_given)
    end

    # THE TWO MEMBERS THIS BOUNDARY USED TO DROP ON THE FLOOR (T16). It hands on
    # exactly {KEYS} -- which is right, and is why a member the editor sends and
    # the list does not name vanishes with no refusal and no warning. `revision`
    # is the diff the human was LOOKING at, and it is the only thing that makes
    # "authored against one diff, submitted against another" detectable at all;
    # `drifted` is the editor's measurement, and only the editor holds the buffer
    # it compares against. Both were sent and both were silently stripped.
    it "carries the revision and the measurement through, rather than dropping them" do
      taken = nil
      allow(listener).to receive(:review_annotated) { |note| taken = note }

      answer(annotation("revision" => " d4e5f6 ", "drifted" => true))

      expect(taken).to include("revision" => "d4e5f6", "drifted" => true)
    end

    it "refuses a note that names no revision, so no note can name no diff" do
      expect(answer(annotation("revision" => "   "))).to include("names no revision")
    end

    # `drifted` is REFUSED, never coerced. {Review::AnnotationPlaced} gives it no
    # default precisely so a caller that never compared cannot journal "did not
    # drift", and a truthiness test here would hand that default straight back: a
    # dropped key is nil is false, which is the answer most notes give and so the
    # one nobody would question. `"false"` is the sharp case -- a wire that
    # stringified the boolean sends a value that is TRUE to anything loose.
    it "refuses a measurement that is not a measurement, and never coerces one" do
      allow(listener).to receive(:review_annotated)

      expect(answer(annotation.except("drifted"))).to include("drifted")
      ["false", "true", nil, 0, 1].each do |given|
        expect(answer(annotation("drifted" => given))).to include("must be true or false"), given.inspect
      end
      expect(answer(annotation("drifted" => true))).to be_nil
      expect(listener).to have_received(:review_annotated).once
    end

    # `line` is the one member with a DOMAIN rather than a vocabulary, and it
    # was checked only for its key's presence. Downstream `WireInteger.read`
    # RAISES on each of these, from inside a listener, which the RPC thread
    # answers and then re-raises -- so leaving it open moved the obligation
    # silently to T13/T19/T20 and turned it into a session death when they meet
    # it. The domain is {Review::Anchor}'s, asked here rather than restated.
    it "refuses a line that names no position, and never hands it on" do
      allow(listener).to receive(:review_annotated)

      ["abc", 0, -3, nil, 1.5].each do |line|
        expect(answer(annotation("line" => line))).to include("positive Integer"), line.inspect
      end
      expect(listener).not_to have_received(:review_annotated)
    end

    it "refuses a note naming no file, the same way it refuses one with no words" do
      expect(answer(annotation("path" => "   "))).to include("must name the file")
    end

    # The verdict verb has always handed on a `Wire.token`-normalized value
    # while the annotation handed on the RAW note, which worked only because
    # {Review::AnnotationPlaced} re-tokens everything. Normalizing at the ONE
    # boundary makes that record's normalization idempotent instead of the only
    # thing standing between a `" new "` off the wire and a side nothing
    # recognises.
    it "hands on the note normalized, stripping tokens and never the text" do
      taken = nil
      allow(listener).to receive(:review_annotated) { |note| taken = note }

      answer(annotation("side" => " new ", "path" => " lib/lain/agent.rb ",
                        "anchor_text" => "  @store.write(input)  "))

      expect(taken).to eq(annotation("anchor_text" => "  @store.write(input)  "))
    end

    # An extra key is either noise or a version skew, and passing one through
    # would let a later reader act on a field this boundary never judged.
    it "hands on exactly the declared keys, never a field it did not judge" do
      taken = nil
      allow(listener).to receive(:review_annotated) { |note| taken = note }

      answer(annotation("severity" => "blocker-ish"))

      expect(taken.keys).to eq(Lain::Frontend::Neovim::ReviewWrite::KEYS)
    end
  end

  # T16's `:LainNoteDone`: one settling gesture carrying every note the human
  # placed, answered once.
  describe "a settled review's wire shape" do
    def note(overrides = {})
      { "path" => "lib/lain/agent.rb", "side" => "new", "line" => 12,
        "anchor_text" => "  @store.write(input)", "text" => "why this way?",
        "kind" => "question", "revision" => "d4e5f6", "drifted" => false }.merge(overrides)
    end

    def answer(*notes) = router.answer(["review_notes", [notes]])

    # ORDER IS THE OUTPUT: the journal's order is the only record of which note
    # the human wrote first, so the deliveries happen in the order the payload
    # carried and 40/12/25 is chosen so any positional sort reads differently.
    it "hands every note on in placement order and answers once" do
      taken = []
      # The block must answer nil: a listener's return value IS the write's
      # verdict, so a stub leaking its accumulator would read as a refusal.
      allow(listener).to receive(:review_annotated) { |given| taken.push(given["line"]) && nil }

      expect(answer(note("line" => 40), note("line" => 12), note("line" => 25))).to be_nil
      expect(taken).to eq([40, 12, 25])
    end

    # A BATCH IS ONE GESTURE, so a refusal has to leave the whole gesture
    # untaken. Half a review recorded, with a refusal covering the rest, is the
    # one outcome a human cannot act on -- they cannot tell which half to
    # retype. The malformed note is LAST here, which is the ordering a loop over
    # the per-note guard would get wrong while passing every other example.
    it "judges every note before delivering any, so a late refusal takes nothing" do
      allow(listener).to receive(:review_annotated)

      expect(answer(note, note, note("kind" => "nit"))).to include("kind must be one of")
      expect(listener).not_to have_received(:review_annotated)
    end

    it "refuses a note the wire dropped its measurement from, however deep in the batch" do
      allow(listener).to receive(:review_annotated)

      expect(answer(note, note.except("drifted"))).to include("drifted")
      expect(listener).not_to have_received(:review_annotated)
    end

    # An empty settle is a real gesture -- a human who read the diff and had
    # nothing to say -- and is answered as taken rather than refused.
    it "takes an empty batch rather than refusing it" do
      expect(answer).to be_nil
    end

    # The shape a lua half gets by dropping ONE pair of braces: the arguments are
    # an array, but they hold a bare note where the batch belongs. It reads as a
    # single-note write, so it would be half-accepted rather than refused, and
    # `{flat}` cannot see it -- the arguments really are an array.
    it "refuses a bare note where the array of notes belongs" do
      allow(listener).to receive(:review_annotated)

      [note, "why this way?", 12, nil].each do |unbatched|
        expect(router.answer(["review_notes", [unbatched]])).to include("must be the ARRAY of notes"),
                                                                unbatched.inspect
      end
      expect(listener).not_to have_received(:review_annotated)
    end

    # The listener's own refusal is the write's verdict, and the FIRST one stops
    # the batch: a human is told one thing to go fix, not a list.
    it "answers the first refusal its listener gives" do
      allow(listener).to receive(:review_annotated).and_return(nil, "no review is open", "nor this one")

      expect(answer(note, note, note)).to eq("no review is open")
      expect(listener).to have_received(:review_annotated).twice
    end
  end

  describe "a verdict write's wire shape" do
    it "hands a known verdict to the listener and returns its answer" do
      allow(listener).to receive(:review_verdict_given).and_return("3 hunks are still unreviewed")

      expect(router.answer(["review_verdict", ["approve"]])).to eq("3 hunks are still unreviewed")
      expect(listener).to have_received(:review_verdict_given).with("approve")
    end

    # The vocabulary is one member wide on purpose ({Lain::Review::VERDICTS}),
    # and widening it is a decision taken there, not a string the editor can
    # start sending.
    it "refuses a verdict outside the vocabulary, naming what arrived" do
      allow(listener).to receive(:review_verdict_given)

      expect(router.answer(["review_verdict", ["request-changes"]])).to match(/must be approve.*request-changes/)
      expect(listener).not_to have_received(:review_verdict_given)
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

# The FRONTEND's half of the answered pair, which is the half a live session
# actually wires. {Listener::Null} answers the duck above, but production builds
# {Neovim}'s own FrontendListener -- and a listener inheriting the abstract base's
# NotImplementedError would raise on the RPC thread, where {RpcThread#answer}
# answers the editor and then RE-RAISES, ending the session over one note. Both
# halves or neither: that is the seam this chunk's waves are built to keep in one
# card, and it is exercised here through a REAL {Neovim} rather than a double,
# because what is being pinned is the object production assembles.
#
# The frontend is never STARTED -- the socket does not exist -- so no editor is
# spawned and nothing here reaches lua. That is deliberate: the lua half of
# `set_review`/`open_changeset`/`set_thread` arrives in T14, T15 and T18, and a
# spec that needed it would be reaching into their scope.
RSpec.describe Lain::Frontend::Neovim, "the review write seam" do
  subject(:frontend) { described_class.new(channel: Lain::Channel.new, socket_path: "/nonexistent.sock") }

  let(:review) { RecordingReviewWrites.new }
  let(:session) { instance_double(Neovim::Session, respond: nil) }
  let(:connection) { instance_double(Neovim::Connection, flush: nil) }
  let(:client) { instance_double(Neovim::Client, session:) }
  let(:rpc) { frontend.instance_variable_get(:@rpc) }

  before do
    rpc.instance_variable_set(:@client, client)
    rpc.instance_variable_set(:@connection, connection)
  end

  def dispatch(*arguments)
    rpc.send(:dispatch,
             instance_double(Neovim::Message::Request, id: 7, method_name: "lain_command", arguments:))
  end

  def annotation(overrides = {})
    { "path" => "lib/lain/agent.rb", "side" => "new", "line" => 12,
      "anchor_text" => "  @store.write(input)", "text" => "why this way?",
      "kind" => "question", "revision" => "d4e5f6", "drifted" => false }.merge(overrides)
  end

  it "carries a note from the editor to the bound review and answers that it was taken" do
    frontend.bind_changeset_review(review)

    dispatch("review_annotate", [annotation])

    expect(review.wrote).to eq([[:annotation, annotation]])
    expect(session).to have_received(:respond).with(7, true, nil)
  end

  it "carries a verdict the same way" do
    frontend.bind_changeset_review(review)

    dispatch("review_verdict", ["approve"])

    expect(review.wrote).to eq([[:verdict, "approve"]])
    expect(session).to have_received(:respond).with(7, true, nil)
  end

  # The review's OWN refusal, not the wire's: the note is well-formed and this
  # review still cannot take it. That answer is the write's verdict, so the
  # buffer stays modified with the human's words in it.
  it "fails the write with the refusal the review itself gave" do
    frontend.bind_changeset_review(RecordingReviewWrites.new(refusal: "that hunk is not in this changeset"))

    dispatch("review_annotate", [annotation])

    expect(session).to have_received(:respond).with(7, nil, "that hunk is not in this changeset")
  end

  # THE HOLE THIS CARD CLOSED. Before the frontend answered these, an annotate
  # arriving at a real session hit the abstract base's NotImplementedError on the
  # RPC thread -- an editor answered and then a dead thread. A live editor with
  # no review open is the ORDINARY state of a session, not an error in it.
  it "refuses both writes when no review is open, rather than raising on the RPC thread" do
    expect { dispatch("review_annotate", [annotation]) }.not_to raise_error
    expect { dispatch("review_verdict", ["approve"]) }.not_to raise_error

    expect(session).to have_received(:respond)
      .with(7, nil, Lain::Frontend::Neovim::NoReviewWrites::UNOPENED).twice
  end

  # Why the listener holds a bound ACCESSOR rather than the review itself: a
  # human opens a review mid-run, long after the frontend attached. A held
  # reference would be the Null for the life of the session and every note would
  # be refused with a sentence about a review that IS open.
  it "sees a review bound after the frontend was built, and unbound again" do
    dispatch("review_annotate", [annotation])
    frontend.bind_changeset_review(review)
    dispatch("review_annotate", [annotation])
    frontend.bind_changeset_review(nil)
    dispatch("review_annotate", [annotation])

    expect(review.wrote.size).to eq(1)
    expect(session).to have_received(:respond)
      .with(7, nil, Lain::Frontend::Neovim::NoReviewWrites::UNOPENED).twice
  end

  # The wire read runs BEFORE the listener, so a malformed note never reaches
  # the review at all -- the whole reason {Neovim::ReviewWrite} sits where it
  # does, restated at the seam a live session actually uses.
  it "never lets a malformed note reach the review" do
    frontend.bind_changeset_review(review)

    dispatch("review_annotate", [annotation("side" => "both")])

    expect(review.wrote).to be_empty
    expect(session).to have_received(:respond).with(7, nil, a_string_matching(/side must be one of/))
  end

  # The two Nulls say two different things, and the difference is what a human
  # would do about it: no review surface wired at all is a defect in the wiring;
  # no review open is Tuesday.
  it "distinguishes no review OPEN from no review surface wired at all" do
    expect(Lain::Frontend::Neovim::NoReviewWrites::UNOPENED)
      .not_to eq(Lain::Frontend::Neovim::RpcThread::Listener::Null::UNREVIEWABLE)
    expect(Lain::Frontend::Neovim::NoReviewWrites::UNOPENED).to include("no review is open")
  end

  # T31a: the same rail, with the object a production wiring actually binds to
  # it. Every example above proves the rail CARRIES a write; these prove what is
  # at the end of it, because until this card the answer was
  # {Lain::Frontend::Neovim::NoReviewWrites} in every process that ever ran --
  # `bind_changeset_review` had no caller anywhere in `lib/` or `exe/`.
  describe "with the real Review::Handover bound to it" do
    def diff
      <<~DIFF
        diff --git a/a.rb b/a.rb
        index 1111111..2222222 100644
        --- a/a.rb
        +++ b/a.rb
        @@ -1,3 +1,3 @@ def alpha
         one
        -two
        +TWO
      DIFF
    end

    def walk
      [Lain::Review::Source::Commit.new(
        sha: -("c" * 40), subject: -"the work", body: "",
        numstat: [Lain::Review::Source::FileStat.new(path: -"a.rb", added: 1, deleted: 1)].freeze
      )].freeze
    end

    def changeset
      source = DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                               diff: diff.b, commits: walk,
                                               base_ref: -("b" * 40), head_ref: -("h" * 40)))
      Lain::Review::Changeset.new(source:)
    end

    let(:io) { StringIO.new }
    let(:review_session) do
      Lain::Review::Session.open(changeset:, journal: Lain::Journal.new(io:), source: "local_branch",
                                 surface: Lain::Review::Surface::Null.new,
                                 policy: Lain::Review::Verdict::Policy::Permissive.new)
    end

    def records_of(type) = Lain::Journal.records(io.string.lines, type:).to_a

    before { frontend.bind_changeset_review(Lain::Review::Handover.new(session: review_session)) }

    it "settles the session with the verdict the editor wrote, and tells it the write took" do
      dispatch("review_verdict", ["approve"])

      expect(review_session.verdict).to eq("approve")
      expect(session).to have_received(:respond).with(7, true, nil)
    end

    # The measurement crosses the wire and is journaled as it arrived. The
    # anchor text here is exactly what the diff's new side reads at that line,
    # so a handover measuring drift ITSELF would journal false; only a
    # forwarding one journals what the editor sent.
    it "journals a note with the editor's own drift measurement, not one computed here" do
      dispatch("review_annotate", [annotation("path" => "a.rb", "line" => 3, "anchor_text" => "TWO",
                                              "drifted" => true)])

      expect(records_of("annotation_placed").map { |record| record["drifted"] }).to eq([true])
      expect(session).to have_received(:respond).with(7, true, nil)
    end

    # The rail's rule, against the real object: a second verdict is refused in
    # WORDS, so the human's `:w` fails and their editor session survives it.
    it "fails a second verdict's write rather than raising on the RPC thread" do
      dispatch("review_verdict", ["approve"])

      expect { dispatch("review_verdict", ["approve"]) }.not_to raise_error
      expect(session).to have_received(:respond).with(7, nil, a_string_matching(/already judged/))
    end
  end
end
