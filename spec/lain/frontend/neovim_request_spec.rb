# frozen_string_literal: true

require "fileutils"
require "json"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# 4-2.3: the one EDITABLE lain:// view. `lain://request` shows the pending
# request as pretty JSON; a human edits it in place and `:LainResend` feeds the
# edited buffer back as a fresh Telemetry::RequestSent -- journaled like any
# other request and diffed by {Buffers} against the original. Same real
# headless-nvim harness as the other :nvim specs (a SECOND, independent
# {#inspector} connection observes buffer state); see neovim_spec.rb's header.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-request-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    @nvim_pid = pid
    example.run
  ensure
    begin
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_f(socket)
  end

  let(:channel) { Lain::Channel.new }
  let(:journal) { Lain::Channel.new }

  def inspector
    @inspector ||= Neovim.attach_unix(@socket)
  end

  def buffer_lines(name)
    inspector.exec_lua(<<~LUA, [name])
      local name = ...
      local buf = vim.fn.bufnr(name)
      if buf == -1 then return {} end
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    LUA
  end

  def buffer_modifiable(name)
    inspector.exec_lua(<<~LUA, [name])
      local name = ...
      local buf = vim.fn.bufnr(name)
      if buf == -1 then return nil end
      return vim.bo[buf].modifiable
    LUA
  end

  def set_buffer(name, lines)
    inspector.exec_lua(<<~LUA, [name, lines])
      local name, lines = ...
      local buf = vim.fn.bufnr(name)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    LUA
  end

  # Editor effects arrive on the RPC thread, never synchronously with the push
  # that caused them -- and a resend crosses two more threads (RPC -> worker ->
  # drainer) before the diff lands, so polling is the only honest wait.
  def wait_until(timeout: 8)
    deadline = Time.now + timeout
    result = yield
    until result
      raise "timed out waiting for editor state" if Time.now > deadline

      sleep 0.02
      result = yield
    end
    result
  end

  # The next record journaled -- a BLOCKING pop with a deadline, not a
  # tight-poll drain: the resend is produced on the worker thread, and a
  # blocking pop wakes the instant it lands (the same shape neovim_spec.rb uses
  # for command_inbox), where a non-blocking drain in a busy poll loop can race
  # the push. In the unbridged describes only resends are journaled, so one pop
  # is the resent request; the T18 describes pop the full record sequence.
  def next_journaled
    Timeout.timeout(8) { journal.pop }
  end

  # Priming (see Neovim#prime_views) gives every view placeholder text from
  # attach, so a bare `.any?` wait would pass before the render under test
  # lands -- wait for the rendered JSON itself.
  def request_json_lines
    lines = buffer_lines("lain://request")
    lines if lines.first&.start_with?("{")
  end

  let(:payload) do
    { "model" => "a", "max_tokens" => 16,
      "messages" => [{ "role" => "user", "content" => "hi" }] }
  end

  def push_request(request_payload)
    channel.push(Lain::Telemetry::RequestSent.new(digest: "d", payload: request_payload, stream: true, extra: {}))
  end

  describe "lain://request is the one editable view" do
    it "renders the pending request as editable pretty JSON" do
      frontend = described_class.new(channel:, socket_path: @socket, journal:)

      frontend.run do
        push_request(payload)

        rendered = wait_until { request_json_lines }
        expect(JSON.parse(rendered.join("\n"))).to eq(payload)
        # Unlike the read-only projections, this buffer is left modifiable so a
        # human can edit the request in place before resending.
        expect(buffer_modifiable("lain://request")).to be(true)
      end
    end

    it "exists at attach as an editable placeholder whose resend is a no-op" do
      frontend = described_class.new(channel:, socket_path: @socket, journal:)

      frontend.run do
        wait_until { buffer_lines("lain://request") == ["(no request yet)"] }
        expect(buffer_modifiable("lain://request")).to be(true)

        inspector.command("LainResend") # no baseline yet -- must journal nothing

        push_request(payload)
        wait_until { request_json_lines }
        set_buffer("lain://request", JSON.pretty_generate(payload.merge("model" => "b")).split("\n"))
        inspector.command("LainResend")

        # The first journaled resend is the REAL one: had the placeholder
        # resend journaled anything, this pop would yield that instead.
        expect(next_journaled.payload["model"]).to eq("b")
      end
    end
  end

  describe "edit, resend, see what changed (4-2.3)" do
    it "dispatches the edited request and shows exactly the change in lain://diff" do
      frontend = described_class.new(channel:, socket_path: @socket, journal:)

      frontend.run do
        push_request(payload)
        wait_until { request_json_lines }

        edited = payload.merge("model" => "b")
        set_buffer("lain://request", JSON.pretty_generate(edited).split("\n"))
        inspector.command("LainResend")

        # The diff view reflects the edit, and only the edit: the model line
        # flips, everything else is unchanged context.
        diff = wait_until do
          lines = buffer_lines("lain://diff")
          lines if lines.any? { |line| line.start_with?("+") && line.include?("\"b\"") }
        end
        expect(diff).to include(a_string_matching(/\A\+.*"b"/))
        expect(diff).not_to include(a_string_matching(/\A\+.*"content"/)) # messages untouched

        # The resent request is journaled like any other, carrying the edit --
        # but stamped with its provenance: a RequestResent (still a RequestSent
        # for every projection), so journal mining never reads a hand-edit as a
        # real dispatch that failed (see JournalRequests' failure-reading doc).
        resent = next_journaled
        expect(resent.payload["model"]).to eq("b")
        expect(resent).to be_a(Lain::Telemetry::RequestResent)
        expect(resent.journal_type).to eq("request_resent")
      end
    end
  end

  describe "an unedited resend is a no-op diff (4-2.3)" do
    it "leaves the diff view empty when the buffer was not edited" do
      frontend = described_class.new(channel:, socket_path: @socket, journal:)

      frontend.run do
        push_request(payload)
        # The first request renders as all-additions in the diff; wait for that
        # so the empty diff after resend is a real transition, not a not-yet.
        wait_until { request_json_lines && buffer_lines("lain://diff").any? { |line| line.start_with?("+") } }

        inspector.command("LainResend") # no edit

        resent = next_journaled
        expect(resent.payload).to eq(payload)
        # An identical resend has nothing to diff: the view is emptied. (An
        # emptied nvim buffer reports a single blank line, never a zero-line
        # buffer, so "empty" is "carries no +/- change lines".)
        emptied = wait_until { buffer_lines("lain://diff").none? { |line| line.start_with?("+", "-") } }
        expect(emptied).to be(true)
      end
    end
  end

  describe "resend-worker death is loud (T16 panel fix #2)" do
    # The worker journals inside its loop, so a raising journal write is its
    # native death. It must get the same observability discipline as the RPC
    # thread: the channel closes (producers see the loss), teardown stays
    # bounded, the inbox closes (no silent black hole growing behind a dead
    # consumer), and run re-raises the failure -- without masking the block's
    # own exception, which the begin/ensure shape already guarantees.
    it "closes the channel, closes the inbox, and re-raises the journal failure from run" do
      exploding = Class.new do
        def <<(_event) = raise "journal broke"
      end.new
      frontend = described_class.new(channel:, socket_path: @socket, journal: exploding)

      # The death-driven close must be observable INSIDE the block -- teardown
      # closes the channel too, so only an in-block observation proves the
      # death itself was made loud (recorded as false, never raised, so a miss
      # here can't be masked by whatever run re-raises after teardown).
      death_closed_channel = false
      error = begin
        frontend.run do
          push_request(payload)
          wait_until { request_json_lines }
          inspector.command("LainResend")
          death_closed_channel = begin
            wait_until(timeout: 6) { channel.closed? }
            true
          rescue RuntimeError
            false
          end
        end
        nil
      rescue StandardError => e
        e
      end

      expect(death_closed_channel).to be(true)
      # T9: the recorded failure re-raises WRAPPED -- a SessionFailure naming
      # the dead thread, the raw error riding cause -- so exe/lain's
      # `rescue Lain::Error` presents the loss as an actionable notice.
      expect(error).to be_a(Lain::Frontend::Neovim::SessionFailure)
      expect(error.message).to eq("resend worker died: journal broke")
      expect(error.cause).to be_a(RuntimeError)
      expect(frontend.instance_variable_get(:@resend_inbox)).to be_closed
    end
  end

  # T18 (M4-2): the bridged path. Everything ABOVE this describe runs
  # unbridged and unchanged -- that IS the card's third scenario, "the
  # projection path without the bridge is unchanged": no ResendBridge wired,
  # :LainResend journals + diffs exactly as before, and the default
  # {Lain::Frontend::Neovim::Unbridged} never rebuilds or dispatches (its
  # never-forced rebuild is pinned in resend_bridge_spec.rb, default suite).
  describe "T18: edit, resend, DISPATCH -- the edited request reaches the provider" do
    let(:override) { Lain::Agent::RequestOverride.new }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64) }

    # The chat shape in miniature: JournalRequests is INNERMOST on the model
    # phase and shares the resend records' journal, so projection AND dispatch
    # land in ONE stream where their record types (and digest join keys) can
    # be popped in order. The lain://request baseline is pushed from the
    # provider's actually-received bytes, as the other describes push theirs.
    def build_agent(provider)
      stack = Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal:)])
      Lain::Agent.new(provider:, toolset: Lain::Toolset.new, context:, request_override: override,
                      model_middleware: stack)
    end

    def edit_buffer(&edit)
      edited = edit.call(JSON.parse(wait_until { request_json_lines }.join("\n")))
      set_buffer("lain://request", JSON.pretty_generate(edited).split("\n"))
    end

    it "dispatches the edit byte-identically, journals projection AND dispatch distinctly, and tells the editor" do
      provider = Lain::Provider::Mock.new(responses: [text_response("first"), text_response("re-answered")])
      agent = build_agent(provider)
      bridge = Lain::CLI::ResendBridge.new(agent:, journal:)
      frontend = described_class.new(channel:, socket_path: @socket, journal:, resend_bridge: bridge)

      frontend.run do
        agent.ask("hi")
        push_request(provider.last_request.cache_payload)
        edit_buffer { |rendered| rendered.merge("max_tokens" => 48) }
        inspector.command("LainResend")

        # The dispatch happens on the resend worker; the provider receiving a
        # second request IS the headline -- an edited lain://request reached it.
        wait_until { provider.requests.size == 2 }
        expect(provider.last_request.max_tokens).to eq(48)

        # Projection and dispatch journal DISTINCTLY, provenance in the record
        # TYPES: the ordinary request_sent of the first ask, then the resend's
        # projection, the bridge's attempt-first marker, and the dispatch's own
        # ordinary request_sent -- all joined on the edited request's digest.
        expect(next_journaled).to be_an_instance_of(Lain::Telemetry::RequestSent)
        resent = next_journaled
        expect(resent).to be_a(Lain::Telemetry::RequestResent)
        marker = next_journaled
        expect(marker).to be_a(Lain::Telemetry::ResendDispatched)
        dispatched = next_journaled
        expect(dispatched).to be_an_instance_of(Lain::Telemetry::RequestSent)
        expect([marker.digest, dispatched.digest]).to all(eq(resent.digest))
        # Byte-identical (T4): the wire request's content address IS the
        # projection's recomputed digest.
        expect(provider.last_request.digest).to eq(marker.digest)

        # lain://diff shows edited-vs-rendered, and the editor is told the
        # dispatch happened -- both through the existing render paths. S2: the
        # human is told UP FRONT an attempt is being made, before the outcome.
        wait_until { buffer_lines("lain://diff").any? { |line| line.start_with?("+") && line.include?("48") } }
        wait_until { buffer_lines("lain://journal").any? { |line| line.include?("resend: dispatching") } }
        wait_until { buffer_lines("lain://journal").any? { |line| line.include?("resend dispatched") } }
        expect(agent).to be_done
      end
    end

    it "refuses a mid-flight resend with a rendered notice, and nothing dispatches later" do
      gate = Thread::Queue.new
      holding = Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |request, on_stream_started: nil|
          gate.pop
          super(request, on_stream_started:)
        end
      end
      provider = holding.new(responses: [text_response("held answer")])
      agent = build_agent(provider)
      bridge = Lain::CLI::ResendBridge.new(agent:, journal:)
      frontend = described_class.new(channel:, socket_path: @socket, journal:, resend_bridge: bridge)

      frontend.run do
        asker = Thread.new { agent.ask("hi") }
        # The provider blocked on the gate IS mid-flight: the ask has
        # dispatched (and JournalRequests has recorded it) but cannot settle.
        wait_until { gate.num_waiting == 1 }
        push_request(payload)
        wait_until { request_json_lines }
        inspector.command("LainResend")

        # The editor is told the resend was refused and why -- echoed through
        # the same render path every notice takes.
        refusal = wait_until do
          buffer_lines("lain://journal").find { |line| line.include?("resend refused") }
        end
        expect(refusal).to include("mid-turn")

        gate << :go
        asker.join
        # Refused means refused: never queued, never dispatched later. The one
        # request the provider ever saw is the held original, and the journal
        # carries its request_sent plus the projection -- no marker.
        expect(override).not_to be_queued
        expect(provider.requests.size).to eq(1)
        expect(next_journaled).to be_an_instance_of(Lain::Telemetry::RequestSent)
        expect(next_journaled).to be_a(Lain::Telemetry::RequestResent)
      end
    end
  end

  # S3: since T18 a bridged offer holds the resend worker for a whole model
  # round trip, so a bare `join` at teardown is UNBOUNDED -- a wedged provider
  # would strand the editor's exit forever. The join is now capped
  # (Neovim::TEARDOWN_GRACE); the worker exits itself once the offer settles.
  describe "S3: teardown stays bounded when a bridged offer holds the worker" do
    it "returns from run within the teardown grace instead of blocking on the in-flight round trip" do
      parked = Thread::Queue.new
      gate = Thread::Queue.new
      blocking = Object.new
      blocking.define_singleton_method(:offer) do |on_attempt: nil, &_build| # rubocop:disable Lint/UnusedBlockArgument
        parked << :in
        gate.pop
        "resend dispatched: held"
      end
      frontend = described_class.new(channel:, socket_path: @socket, journal:, resend_bridge: blocking)

      returned = false
      runner = Thread.new do
        frontend.run do
          push_request(payload)
          wait_until { request_json_lines }
          inspector.command("LainResend")
          parked.pop # the worker is now stranded inside the bridge's offer
        end
        returned = true
      end

      # The worker is stranded in the round trip, yet teardown must not wait on
      # it unboundedly: run returns within the grace (plus slack), where an
      # unbounded join would still be blocked here.
      completed = runner.join(Lain::Frontend::Neovim::TEARDOWN_GRACE + 4)
      gate << :go # release the stranded worker so it exits cleanly
      expect(completed).not_to be_nil
      expect(returned).to be(true)
    end
  end

  describe "resends are journaled and non-destructive (4-2.3)" do
    let(:store) { Lain::Store.new }

    it "records the resend and leaves the original Timeline head reachable (speculative fork)" do
      timeline = Lain::Timeline.empty(store:)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "hello" }])
      head = timeline.head_digest
      frontend = described_class.new(channel:, socket_path: @socket, store:, journal:)

      frontend.run do
        channel.push(Lain::Telemetry::TurnUsage.new(digest: head, model: "m", stop_reason: :end_turn, usage: {}))
        push_request(payload)
        wait_until { request_json_lines && buffer_lines("lain://timeline").include?("user: hi") }

        set_buffer("lain://request", JSON.pretty_generate(payload.merge("model" => "b")).split("\n"))
        inspector.command("LainResend")

        expect(next_journaled.payload["model"]).to eq("b")

        # Speculative fork, not rewrite: the resend never committed, so the
        # original head still resolves and a fork of it is O(1) and equal.
        expect(store.key?(head)).to be(true)
        original = Lain::Timeline.new(head_digest: head, store:)
        expect(original.fork).to eq(original)
        expect(original.to_a.map(&:role)).to eq(%w[user assistant])
        # The live timeline view still shows the untouched chain.
        expect(buffer_lines("lain://timeline")).to eq(["user: hi", "assistant: hello"])
      end
    end
  end
end
