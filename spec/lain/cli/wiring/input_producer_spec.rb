# frozen_string_literal: true

require "json"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module InputProducerSpecSupport
  # The chat's registration as the daemon's offer pushes reach it: the 1
  # subscriber per method, and every request the chat sends back.
  class Registration
    attr_reader :requests

    # @param refusal [String, nil] what the daemon refuses every request with
    def initialize(refusal: nil)
      @handlers = {}
      @requests = Thread::Queue.new
      @refusal = refusal
    end

    def on(method, &handler)
      @handlers[method] = handler
      self
    end

    def call(method, *params)
      @requests << [method, *params]
      raise Lain::Core::Client::Refused, @refusal if @refusal
    end

    def subscribed?(method) = @handlers.key?(method)

    # Delivered on the caller's fiber, as the registration's own push fiber does.
    def push(method, *params) = @handlers.fetch(method).call(params)
  end
end

RSpec.describe Lain::CLI::Wiring::InputProducer do
  # The fleet tree is read through lain://status and lain watch; the pane's
  # header is the HUD line alone, so a child starting or ending never changes
  # its row count.
  describe "the input pane's header" do
    let(:running) do
      Array.new(3) do |index|
        { "spawn" => "blake3:c#{index}", "role" => "dev", "task" => "port the parser", "state" => "running",
          "turns" => 1, "depth" => 0, "started" => "2026-09-20T12:00:00Z" }
      end
    end

    it "is 1 line holding the HUD and the fleet count, naming no child, while children run" do
      state = { "fleet" => %w[a b c], "fleet_tree" => running, "inbox_count" => 0 }
      header = described_class.new(human: nil, attended: true, cockpit: nil, pending: nil, stdin: nil, notes: nil,
                                   paths: Lain::Paths.new, root: "/work", switchboard: nil, commands: -> { [] },
                                   registration: nil, status_feed: instance_double(Lain::StatusFeed, state:)).hud_line

      expect(header.lines.size).to eq(1)
      expect(header).to include("fleet:3").and(satisfy { |line| !line.include?("dev") })
    end

    it "ends with the review count the poll wrote" do
      Dir.mktmpdir do |home|
        paths = Lain::Paths.new(env: { "HOME" => home, "XDG_STATE_HOME" => File.join(home, "state") })
        FileUtils.mkdir_p(File.dirname(paths.review_counts))
        File.write(paths.review_counts, JSON.generate("hud" => "rv 3+1", "stale" => true))
        state = { "fleet" => [], "inbox_count" => 0 }
        header = described_class.new(human: nil, attended: true, cockpit: false, pending: nil, stdin: nil, notes: nil,
                                     paths:, root: "/work", switchboard: nil, commands: -> { [] }, registration: nil,
                                     status_feed: instance_double(Lain::StatusFeed, state:)).hud_line

        expect(header).to end_with(" rv 3+1?")
      end
    end
  end

  describe "the chat it builds for an attended human" do
    let(:registration) { InputProducerSpecSupport::Registration.new }

    def producer(attended:)
      Dir.mktmpdir do |home|
        paths = Lain::Paths.new(env: { "HOME" => home, "XDG_STATE_HOME" => File.join(home, "state") })
        human = Lain::CLI::Wiring::HumanInput.new(input: nil, attended:, stdin: StringIO.new, paths:, cwd: home)
        producer = described_class.new(human:, attended:, cockpit: false, pending: nil, stdin: StringIO.new,
                                       notes: StringIO.new, paths:, root: home, status_feed: nil, switchboard: nil,
                                       commands: -> { [] }, registration:)
                                  .call(Lain::Frontend::Intake.new, Struct.new(:render_warning).new)
        Sync { |task| producer.start(task).stop }
      end
    end

    it "takes the review queue's offers from the daemon" do
      producer(attended: true)

      expect(registration.subscribed?("offer")).to be(true)
    end

    it "takes none for a chat nobody attends" do
      producer(attended: false)

      expect(registration.subscribed?("offer")).to be(false)
    end
  end

  describe Lain::CLI::Wiring::InputProducer::QueueOffers, :seam do
    subject(:offers) do
      described_class.new(Lain::Frontend::StdinPump::Idle, registration:, rail:, log:,
                                                           notice: ->(word) { said << word })
    end

    let(:state) { Dir.mktmpdir("lain-queue-offers") }
    let(:registration) { InputProducerSpecSupport::Registration.new }
    let(:rail) { Lain::Frontend::Intake.new }
    let(:log) { Lain::Review::Queue::Log.new(paths:) }
    let(:paths) { Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => state })) }
    let(:said) { Thread::Queue.new }
    let(:url) { "https://github.com/fuze/api/pull/12" }
    let(:row) { { "id" => "pr:fuze/api#12", "head_sha" => "c" * 40 } }
    let(:queued) do
      Lain::Review::Queue::Row.new(id: row["id"], rank: :direct, reason: "", request: nil, head_sha: "c" * 40)
    end

    # The chat's reactor: pushes are delivered and the human answers on it.
    around do |example|
      Sync do |task|
        @task = task
        offers.start(task)
        example.run
      ensure
        offers.stop
      end
    ensure
      FileUtils.remove_entry(state)
    end

    def until_held(reason, &) = pumped_until(@task, reason:, &)

    def offer(request = { "kind" => "pr", "url" => url }, with: row, id: 7)
      registration.push("offer", { "offer_id" => id, "request" => request, "row" => with }.compact)
    end

    def reply = until_held("the reply") { registration.requests.empty? ? nil : registration.requests.pop }

    def note = until_held("the note") { said.empty? ? nil : said.pop }

    def prompt = until_held("the offer drawn") { rail.published.kind == :human && rail.published }

    def answer(text) = rail << Lain::Frontend::Intake::Line.new(text:, generation: prompt.generation)

    def opened_events
      File.readlines(paths.review_queue_log).reject { _1.strip.empty? }.map { JSON.parse(_1) }
    end

    def withdrawn = until_held("the offer withdrawn") { rail.published.kind.nil? }

    it "marks the row seen, once, at the head offered, when the human presses Enter" do
      offer
      answer("")

      seen = until_held("the row seen") { log.seen?(queued) }

      expect([seen, opened_events.map { |event| event.slice("kind", "row_id", "head_sha") }])
        .to eq([true, [{ "kind" => "opened", "row_id" => row["id"], "head_sha" => "c" * 40 }]])
    end

    it "marks the row seen for an Enter that lands just as the chat stops" do
      offer
      rail << Lain::Frontend::Intake::Line.new(text: "", generation: prompt.generation)
      offers.stop

      expect(log.seen?(queued)).to be(true)
    end

    context "with the chat's answers to offers recorded" do
      let(:rail) do
        Class.new(SimpleDelegator) do
          def answers = @answers ||= []

          def offer(request, &decided) = super.tap { answers << _1 }
        end.new(Lain::Frontend::Intake.new)
      end

      it "ends an offer still showing as the chat stops, rather than killing it" do
        offer
        prompt
        offers.stop

        expect(rail.answers).to eq([nil])
      end
    end

    it "leaves the row unseen for an offer the chat stops before the human answers" do
      offer
      prompt
      offers.stop

      expect([log.seen?(queued), rail.held_lines]).to eq([false, []])
    end

    it "leaves the row unseen when the human drops the offer with x" do
      offer
      answer("x")
      withdrawn

      expect(log.seen?(queued)).to be(false)
    end

    it "leaves the row unseen when the human drops the offer with Ctrl-D" do
      offer
      prompt
      rail << Lain::Frontend::Intake::Eof.new
      withdrawn

      expect(log.seen?(queued)).to be(false)
    end

    it "drops an offer whose row is malformed with 1 note naming the field, never its value" do
      offer(with: row.merge("head_sha" => "/mode bypass"))

      expect([note, said.size, rail.published.kind]).to eq(
        ["lain queue: an offer was dropped: queued review request refused: row.head_sha is not of its shape", 0, nil]
      )
    end

    it "drops an offer that names no row, naming the field" do
      offer(with: nil)

      expect([note, rail.published.kind])
        .to eq(["lain queue: an offer was dropped: queued review request refused: row is missing", nil])
    end

    it "is put to the human, and Enter sends its rebuilt line on as if typed" do
      offer
      shown = prompt
      answer("")

      expect([shown.text, until_held("the line sent") { rail.held_lines.first }])
        .to eq(["lain queue: /review #{url}  (Enter opens, x drops)", "/review #{url}"])
    end

    it "drops an offer that fails to load with 1 note naming the field, never its value" do
      offer({ "kind" => "pr", "url" => "#{url} --base \e[2Jx" })

      expect([note, said.size, rail.published.kind, rail.held_lines]).to eq(
        ["lain queue: an offer was dropped: queued review request refused: url is not of its shape", 0, nil, []]
      )
    end

    it "writes out the escapes in a refused field's name rather than sending them to the screen" do
      offer({ "kind" => "pr", "url" => url, "x\e[2J" => "v" })

      expect(note).to eq(
        "lain queue: an offer was dropped: queued review request refused: x\\e[2J is not a field of a pr request"
      )
    end

    it "says a dirty-tree request's own reason when the tree has nothing to snapshot" do
      Dir.mktmpdir("lain-offer-clean") do |repo|
        root = File.realpath(repo)
        FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", root)
        offer({ "kind" => "dirty", "repo_root" => root })

        expect([note, rail.published.kind]).to eq(
          ["lain queue: an offer was dropped: queued review request refused: repo_root has no uncommitted changes", nil]
        )
      end
    end

    context "with a cockpit chat" do
      subject(:offers) do
        human = Lain::CLI::Wiring::HumanInput.new(input: nil, attended: true, stdin: StringIO.new, paths:, cwd: state)
        held = Class.new { def offering(producer, **) = producer }.new
        Lain::CLI::Wiring::InputProducer.new(human:, attended: true, cockpit: true, pending: held, stdin: StringIO.new,
                                             notes: StringIO.new, paths:, root: state, status_feed: nil,
                                             switchboard: nil, commands: -> { [] }, registration:)
                                        .call(rail, Struct.new(:render_warning).new(->(word) { said << word }))
      end

      it "shows the offer to the human, and replies held because it is showing" do
        offer

        expect([reply, rail.published.kind])
          .to eq([["offer.reply", { "offer_id" => 7, "outcome" => "held" }], :human])
      end
    end

    context "with a chat that has no editor to open a review in" do
      subject(:offers) do
        human = Lain::CLI::Wiring::HumanInput.new(input: nil, attended: true, stdin: StringIO.new, paths:, cwd: state)
        Lain::CLI::Wiring::InputProducer.new(human:, attended: true, cockpit: false, pending: nil, stdin: StringIO.new,
                                             notes: StringIO.new, paths:, root: state, status_feed: nil,
                                             switchboard: nil, commands: -> { [] }, registration:)
                                        .call(rail, Struct.new(:render_warning).new(->(word) { said << word }))
      end

      it "replies plain, shows nothing, and leaves the row unseen" do
        offer

        expect([reply, rail.published.kind, log.seen?(queued)])
          .to eq([["offer.reply", { "offer_id" => 7, "outcome" => "plain" }], nil, false])
      end

      it "replies plain with no offer id for a push that is not a hash" do
        registration.push("offer", "junk")

        expect(reply).to eq(["offer.reply", { "offer_id" => nil, "outcome" => "plain" }])
      end

      context "with a daemon connection that fails" do
        let(:registration) do
          Class.new(InputProducerSpecSupport::Registration) do
            def call(*) = raise(IOError, "connection lost")
          end.new
        end

        it "says nothing and raises nothing, since a plain chat has no notice path" do
          expect { offer }.not_to raise_error
          expect(said.size).to eq(0)
        end
      end
    end

    context "with a rail that fails while it builds the offer" do
      subject(:offers) do
        described_class.new(producer, registration:, rail:, log:, notice: ->(word) { said << word })
      end

      let(:producer) do
        Class.new do
          attr_reader :stopped

          def start(_task) = self

          def stop(**) = @stopped = true
        end.new
      end
      let(:rail) do
        Class.new(SimpleDelegator) do
          def offer(_request) = raise(Lain::Shell::Out::Timeout, "timed out after 10s: git rev-parse")
        end.new(Lain::Frontend::Intake.new)
      end

      it "says why, and still stops the producer underneath, with no unhandled task left to print" do
        expect do
          offer
          @said = note
          offers.stop
        end.not_to output(/unhandled|Timeout/i).to_stderr_from_any_process

        expect([@said, producer.stopped])
          .to eq(["lain queue: an offer was dropped: timed out after 10s: git rev-parse", true])
      end

      it "replies refused, naming no field, so the sender is not left waiting out the daemon's bound" do
        offer

        expect(reply).to eq(["offer.reply", { "offer_id" => 7, "outcome" => "refused" }])
      end
    end

    context "with a daemon that no longer waits on the offer" do
      let(:registration) { InputProducerSpecSupport::Registration.new(refusal: "offer 7 is not waiting on a reply") }

      it "tells the human nothing about the refused reply" do
        offer
        reply
        prompt

        expect(said.size).to eq(0)
      end
    end

    describe "the reply to the daemon" do
      def offering(request, id: 7)
        offer(request, id:)
        reply
      end

      it "is held, naming the offer, as the offer is put to the human while it still waits" do
        expect([offering({ "kind" => "pr", "url" => url }), rail.published.kind])
          .to eq([["offer.reply", { "offer_id" => 7, "outcome" => "held" }], :human])
      end

      it "is given for a second offer while the first still waits on the human's Enter" do
        offering({ "kind" => "pr", "url" => url }, id: 1)
        crowded = offering({ "kind" => "pr", "url" => "#{url}3" }, id: 2)
        waiting = rail.published
        answer("")

        expect([crowded, waiting.kind, waiting.text, until_held("the row seen") { log.seen?(queued) }])
          .to eq([["offer.reply", { "offer_id" => 2, "outcome" => "crowded" }], :human,
                  "lain queue: /review #{url}  (Enter opens, x drops)", true])
      end

      it "is crowded for another request while 1 is offered, and repeat for the same request" do
        offering({ "kind" => "pr", "url" => url }, id: 1)

        expect([offering({ "kind" => "pr", "url" => "#{url}3" }, id: 2),
                offering({ "kind" => "pr", "url" => url }, id: 3)])
          .to eq([["offer.reply", { "offer_id" => 2, "outcome" => "crowded" }],
                  ["offer.reply", { "offer_id" => 3, "outcome" => "repeat" }]])
      end

      it "is refused naming the field, never its value, for a request that fails to load" do
        expect(offering({ "kind" => "pr", "url" => "#{url} --base \e[2Jx" }))
          .to eq(["offer.reply", { "offer_id" => 7, "outcome" => "refused", "field" => "url" }])
      end

      it "is refused naming the field, never its value, for a malformed row" do
        offer(with: row.merge("id" => 7))

        expect(reply).to eq(["offer.reply", { "offer_id" => 7, "outcome" => "refused", "field" => "row.id" }])
      end

      it "is refused naming the field for a request whose line cannot be rebuilt" do
        Dir.mktmpdir("lain-offer-clean") do |repo|
          root = File.realpath(repo)
          FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", root)

          expect(offering({ "kind" => "dirty", "repo_root" => root }))
            .to eq(["offer.reply", { "offer_id" => 7, "outcome" => "refused", "field" => "repo_root" }])
        end
      end
    end
  end
end
