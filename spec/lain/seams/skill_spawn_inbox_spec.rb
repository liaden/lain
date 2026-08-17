# frozen_string_literal: true

require "json"
require "stringio"
require "timeout"
require "tmpdir"

# T1. A human question -- an `ask_human` or a parked approval -- can now be
# raised from a frame {Repl#respond} never enters. A role-bound line
# (`@role[/skill]`) is answered by {Middleware::SkillDispatch}, which SHORT-
# CIRCUITS: it spawns a persona'd subagent, runs it to a final result, and sets
# `env[:response]` without ever calling downstream. That whole child run happens
# inside {Repl#dispatch}, so a reply surface whose lifetime is one `respond`
# call is not running while the child asks -- the question lands on the queue,
# nothing drains it, and the dispatching fiber (the one that parks) never
# returns to the prompt.
#
# Every example here drives the REAL assembly -- {CLI::Wiring#run}, the real
# Repl, the real HumanReplies and its real fibers -- over a {Provider::Mock} and
# a StringIO terminal. An `instance_double(HumanReplies)` would answer the
# question this file exists to ask (which frames the surfaces are live in) with
# whatever the double was told, which is exactly how the defect hid.
#
# The timeouts are load-bearing: an unserved question parks the child forever,
# so the failure shape without them is a hung suite rather than a red example.
# The run's real terminal, counting how many reads are PARKED on it at once.
#
# The one stdin is the contended resource, and every reader reaches it here:
# the `you>` prompt, the `human> ` reply, and an approval's `[y/N]` all come
# through {Lain::Frontend::TTY#prompt}. Two of them in flight at the same
# instant is the wedge this card exists to remove, arrived at from either side
# -- a surface that outlives its line, or a second surface opened over one.
#
# The park is what makes the count mean anything: a StringIO returns instantly,
# so two readers could be spawned and never be observed to overlap.
class CountingTTY < Lain::Frontend::TTY
  PARK = 0.02

  def initialize(**)
    super
    @in_flight = 0
    @peak = 0
  end

  attr_reader :peak

  def prompt(text = "> ")
    @in_flight += 1
    @peak = [@peak, @in_flight].max
    Async::Task.current.sleep(PARK)
    super
  ensure
    @in_flight -= 1
  end
end

RSpec.describe "a human question raised while a skill spawn is dispatched", :seam do
  # The exe's own backend with its provider replaced -- repl_spec's shape, and
  # the reason nothing here touches the network.
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:)
        super(options)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  let(:backend_options) { { provider: "ollama", model: nil, max_tokens: 64 } }

  def backend_over(provider) = offline_backend_class.new(backend_options, mock: provider)

  def mock_for(*responses) = Lain::Provider::Mock.new(responses:)

  def asks_human(question)
    { "type" => "tool_use", "id" => "tu_ask", "name" => "ask_human", "input" => { "question" => question } }
  end

  def runs(command)
    { "type" => "tool_use", "id" => "tu_bash", "name" => "bash", "input" => { "command" => command } }
  end

  def tool_call(block) = Lain::Response.new(content: [block], stop_reason: :tool_use)
  def settled(text) = Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn)

  # The whole chat, assembled by {CLI::Wiring} and driven by the lines the human
  # "typed" -- `you>` reads and `human>` reads come off the same StringIO, in
  # order, exactly as one keyboard serves both prompts.
  def run_chat(input, dir:, provider:, seconds: 20)
    output = StringIO.new
    tty_factory = lambda do |channel:, **|
      @tty = CountingTTY.new(channel:, output:, input: StringIO.new(input),
                             history_path: File.join(dir, "history"))
    end
    wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new, tty_factory:,
                                   status_feed: instance_double(Lain::StatusFeed))
    Timeout.timeout(seconds) { wiring.run(backend: backend_over(provider), resumed: nil, nvim: nil) }
    wiring.conductor.close(reason: :exit)
    output.string
  end

  # What the model was sent LAST -- the turn carrying the tool_result, which is
  # where an answer that actually reached the parked child shows up.
  def last_payload(provider) = JSON.generate(provider.last_request.cache_payload)

  describe "a question from a human-typed skill spawn" do
    let(:provider) { mock_for(tool_call(asks_human("which file")), settled("the researcher is done")) }

    it "prints the arrival note and a human> prompt, and the typed answer resolves the question" do
      Dir.mktmpdir do |dir|
        output = run_chat("@researcher[/critique] describe this file\nthe README\nquit\n", dir:, provider:)

        expect(output).to include("which file", "human> ", "the researcher is done")
        expect(last_payload(provider)).to include("the README")
      end
    end

    it "returns to the you> prompt afterwards, so the conversation is not wedged" do
      Dir.mktmpdir do |dir|
        talking = mock_for(tool_call(asks_human("which file")), settled("still talking"))
        output = run_chat("@researcher[/critique] describe this file\nthe README\nhello?\nquit\n",
                          dir:, provider: talking)

        expect(output.scan("you> ").size).to be >= 3
      end
    end
  end

  # The other surface set {Repl#respond} used to own alone. `bash` is the one
  # capability in the base set that answers `requires_approval?`, and
  # `accept_edits` gates it through the queue -- so a child that runs one parks
  # on a pending nothing was watching.
  describe "a gated tool inside a skill spawn" do
    let(:provider) { mock_for(tool_call(runs("printf lain-t1-approved")), settled("the dev is done")) }

    it "offers the approval, and a granted one lets the tool run" do
      Dir.mktmpdir do |dir|
        output = run_chat("@dev[/critique] run it\ny\nquit\n", dir:, provider:)

        expect(output).to include("approve bash")
        expect(last_payload(provider)).to include("lain-t1-approved")
      end
    end
  end

  # The guard on the widening, and it is a CONCURRENCY claim rather than a count
  # of rendered prompts. Two reads that ran back to back print exactly what two
  # that overlapped print, and only the second is a wedge -- so this counts how
  # many reads are parked on the one terminal at the same instant, over the real
  # {CLI::Wiring} assembly, with a real park inside each read.
  #
  # It fails for either shape of the defect: a surface that OUTLIVES its line
  # (the conversation-scoped answer_loop the card refuses, which would sit on
  # stdin while the next `you>` prompt reads it) and a second surface opened
  # OVER one (the `/inbox` race, whose falsifiable form is in repl_spec, where a
  # backlog can be constructed -- questions reach one agent serially, so a seam
  # example cannot make two arrive at once).
  #
  # An earlier edition asserted `scan("human> ").size == 1`, which cannot fail
  # for the case that matters: with one question and one agent, a second surface
  # parks on an empty queue and prints nothing.
  describe "a question raised during an ordinary turn" do
    let(:provider) { mock_for(tool_call(asks_human("which file")), settled("settled")) }

    it "never has two reads parked on the one terminal at once" do
      Dir.mktmpdir do |dir|
        run_chat("please ask me\nthe README\nquit\n", dir:, provider:)

        expect(@tty.peak).to eq(1)
      end
    end

    it "still delivers the human's answer to the parked question" do
      Dir.mktmpdir do |dir|
        output = run_chat("please ask me\nthe README\nquit\n", dir:, provider:)

        expect(output).to include("which file", "human> ")
        expect(last_payload(provider)).to include("the README")
      end
    end
  end
end
