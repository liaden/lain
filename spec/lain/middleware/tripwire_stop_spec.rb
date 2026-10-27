# frozen_string_literal: true

RSpec.describe Lain::Middleware::TripwireStop do
  let(:stops) { Lain::Tripwire::Stops.new }
  let(:journal) { [] }
  let(:session) { Lain::Session.new }

  def at(level) = Struct.new(:approval).new(Lain::Mode::Approval.for(level))

  def layer(level = :ask, requester: nil, attended: true, over: stops)
    described_class.new(stops: over, journal:, mode: at(level), attended:, requester:)
  end

  def call = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => "README.md" })

  def through(via)
    reached = []
    env = via.call({ effect: call, tool: Lain::Toolset::Unheld.new("unused"), context: session }) do |inner|
      reached << inner
      inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
    end
    [env, reached]
  end

  def escalations = journal.map { Lain::Journal.hash_of(_1) }.select { _1["type"] == "escalation" }

  describe "a requester the tripwire stopped" do
    before { stops.trip("researcher", at: Time.at(0)) }

    %i[ask auto bypass].each do |level|
      it "refuses its next call outright under #{level}, saying a running call was left to finish" do
        env, reached = through(layer(level, requester: "researcher"))

        expect(reached).to be_empty
        expect(env.fetch(:result)).to have_attributes(is_error: true)
        expect(env.fetch(:result).content)
          .to include("the tripwire stopped researcher", "a call already running when it tripped was left to finish",
                      "no approval will lift this")
      end
    end

    it "journals the refusal as a final deny on its own rung, saying the stop applies from the next call" do
      through(layer(requester: "researcher"))

      expect(escalations.sole).to include("tool" => "read_file", "tool_use_id" => "tu_1", "requester" => "researcher",
                                          "verdict" => "deny", "rung" => "tripwire", "final" => true)
      expect(escalations.sole["reason"]).to include("from the next call on")
    end

    it "passes another subagent's call on untouched" do
      env, reached = through(layer(requester: "writer"))

      expect([env.fetch(:result).content, reached.sole.fetch(:effect).approval?]).to eq(["downstream ran", false])
      expect(journal).to be_empty
    end
  end

  describe "a main agent the tripwire paused" do
    before { stops.trip("researcher", at: Time.at(0)) }

    %i[ask auto].each do |level|
      it "hands its next call to the asking rung under #{level}, barred from automatic approval" do
        env, reached = through(layer(level))
        handed = reached.sole

        expect(handed.fetch(:effect)).to have_attributes(approval?: true)
        expect(handed.fetch(:context).automatic_approval_barred?).to be(true)
        expect(env.fetch(:context)).to be(session)
        expect(journal).to be_empty
      end
    end

    it "tells the human who tripped it when the call parks" do
      _, reached = through(layer(:ask))

      expect(reached.sole.fetch(:context).parked_because.map(&:text).join)
        .to include("the tripwire paused the main agent after researcher tripped it")
    end

    it "refuses its call under bypass, naming who tripped it and how a human resumes" do
      env, reached = through(layer(:bypass))

      expect(reached).to be_empty
      expect(env.fetch(:result).content)
        .to include("the tripwire paused the main agent after researcher tripped it",
                    "a call already running when it tripped was left to finish",
                    "switch approval to ask, and a human is asked about each of main's calls")
      expect(env.fetch(:result).content).not_to include("no approval will lift this")
      expect(escalations.sole).to include("requester" => "agent", "rung" => "tripwire", "verdict" => "deny",
                                          "final" => true)
    end

    %i[ask auto].each do |level|
      it "refuses its call in its own words under unattended #{level}, where nobody can be asked" do
        env, reached = through(layer(level, attended: false))

        expect(reached).to be_empty
        expect(env.fetch(:result).content)
          .to include("the tripwire paused the main agent after researcher", "no approval will lift this")
        expect(escalations.sole).to include("rung" => "tripwire", "verdict" => "deny", "final" => true)
      end
    end

    it "refuses under a mode that asks nobody" do
      env, reached = through(described_class.new(stops:, journal:))

      expect([reached, env.fetch(:result).is_error]).to eq([[], true])
    end

    it "reads where main stands once, so a second trip landing during the read cannot let the call through" do
      racing = Class.new(SimpleDelegator) do
        %i[standing stopped?].each do |read|
          define_method(read) do |requester|
            __getobj__.public_send(read, requester).tap { __getobj__.trip("writer", at: Time.at(1)) }
          end
        end
      end

      _, reached = through(layer(:bypass, over: racing.new(stops)))

      expect(reached).to be_empty
    end
  end

  it "refuses main outright once every requester is stopped" do
    stops.trip("agent", at: Time.at(0))

    env, reached = through(layer(:ask))

    expect(reached).to be_empty
    expect(env.fetch(:result).content).to include("the tripwire stopped agent")
  end

  it "passes every call on while nobody tripped" do
    _, reached = through(layer(:ask))

    expect(reached.sole).to include(context: session)
    expect(reached.sole.fetch(:effect).approval?).to be(false)
  end

  describe "#over, the gate policy read again once the ladder settles" do
    def settling(verdict, authority: :automatic)
      ruling = Lain::Approval::Escalation::Ruling.public_send(verdict, rung: "spec", because: "settled", authority:)
      ->(_effect, _context) { ruling }
    end

    def ruled(policy, via: layer(:ask)) = via.over(policy).rule(call, session)

    it "refuses an approve when the requester was stopped while its call was judged or parked" do
      stopping = lambda do |_effect, _context|
        stops.trip("researcher", at: Time.at(0))
        Lain::Approval::Escalation::Ruling.allow(rung: "spec", because: "settled", authority: :human)
      end

      ruling = ruled(stopping, via: layer(:ask, requester: "researcher"))

      expect(ruling).to have_attributes(verdict: :deny, rung: "tripwire", final: true, liftable: false)
      expect(ruling.told).to include("the tripwire stopped researcher")
      expect(escalations.sole).to include("requester" => "researcher", "rung" => "tripwire", "verdict" => "deny")
    end

    it "refuses a paused main's automatic approve" do
      stops.trip("researcher", at: Time.at(0))

      expect(ruled(settling(:allow))).to have_attributes(verdict: :deny, rung: "tripwire", liftable: true)
    end

    it "refuses a paused main's approve for good on a board nobody attends" do
      stops.trip("researcher", at: Time.at(0))

      expect(ruled(settling(:allow), via: layer(:ask, attended: false)))
        .to have_attributes(verdict: :deny, rung: "tripwire", liftable: false)
    end

    it "keeps a paused main's approve when a human gave it" do
      stops.trip("researcher", at: Time.at(0))

      expect(ruled(settling(:allow, authority: :human))).to have_attributes(verdict: :allow, rung: "spec")
      expect(journal).to be_empty
    end

    it "keeps a stopped requester's deny as the ladder settled it" do
      stops.trip("agent", at: Time.at(0))

      expect(ruled(settling(:deny))).to have_attributes(verdict: :deny, rung: "spec")
    end

    it "keeps every ruling while nobody tripped" do
      expect(ruled(settling(:allow))).to have_attributes(verdict: :allow, rung: "spec")
    end
  end
end
