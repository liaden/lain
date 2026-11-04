# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Approval::DenialBreaker do
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:breaker) { described_class.for(:breaker, journal:) }

  def tripped_records = journal_records(io, "judge_breaker_tripped")

  def deny(requester, times) = times.times { breaker.denied(requester) }

  describe ".for" do
    it "answers off with an arm that never trips and applies a judge's deny" do
      off = described_class.for(:off, journal:)
      30.times { off.denied("agent") }

      expect([off.tripped?("agent"), off.maps_deny?]).to eq([false, false])
      expect(tripped_records).to be_empty
    end

    it "answers escalate_only with an arm that hands a deny down and never trips" do
      escalating = described_class.for("escalate_only", journal:)
      30.times { escalating.denied("agent") }

      expect([escalating.tripped?("agent"), escalating.maps_deny?]).to eq([false, true])
    end

    it "answers breaker with an arm that applies a deny until it trips" do
      expect([breaker.maps_deny?, breaker.tripped?("agent")]).to eq([false, false])
    end

    it "refuses an arm it does not know" do
      expect { described_class.for(:sometimes, journal:) }.to raise_error(ArgumentError, /sometimes/)
    end
  end

  describe "the breaker" do
    it "trips a requester on its 3rd judge deny in a row, and journals it once" do
      deny("agent", 2)
      expect(breaker.tripped?("agent")).to be(false)

      deny("agent", 2)

      expect(breaker.tripped?("agent")).to be(true)
      expect(tripped_records.sole).to include("requester" => "agent", "count" => 3, "because" => "3 in a row")
    end

    it "keeps another requester's calls judged" do
      deny("agent", 3)

      expect([breaker.tripped?("agent"), breaker.tripped?("researcher")]).to eq([true, false])
    end

    it "lets an approve reset the run, so denies split by approves do not trip it" do
      6.times do
        deny("agent", 2)
        breaker.approved("agent")
      end

      expect(breaker.tripped?("agent")).to be(false)
    end

    it "trips on the 20th deny of a session even with approves between, saying so" do
      10.times do
        deny("agent", 2)
        breaker.approved("agent")
      end

      expect(breaker.tripped?("agent")).to be(true)
      expect(tripped_records.sole).to include("requester" => "agent", "count" => 20, "because" => "20 this session")
    end

    it "counts the session's denies per requester" do
      19.times do
        %w[agent researcher].each do |requester|
          breaker.denied(requester)
          breaker.approved(requester)
        end
      end

      expect([breaker.tripped?("agent"), breaker.tripped?("researcher")]).to eq([false, false])
    end
  end

  # Scenario: postponing in a loop trips the breaker
  describe "a human's answer at the asking rung" do
    let(:queue) { Lain::Approval::Parked::Queue.new(journal:, timeout: 1) }
    let(:surfaces) { Lain::Approval::Escalation::Surfaces.new(queue, denials: breaker) }
    let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "ls" }) }

    def answered(verdict)
      Sync do |task|
        ruled = task.async { surfaces.call(effect, nil) }
        task.with_timeout(1) { queue.dequeue }.decide(verdict, surface: "tty", authority: :human)
        task.with_timeout(1) { ruled.wait }
      end
    end

    it "counts each postpone as a denial, and trips at the usual 3 in a row" do
      2.times { answered(Lain::Approval::Verdict::Hold.new(note: "after lunch")) }
      tripped_after_two = breaker.tripped?("agent")
      answered(Lain::Approval::Verdict::Hold.new(note: "after lunch"))

      expect([tripped_after_two, breaker.tripped?("agent")]).to eq([false, true])
      expect(tripped_records.sole).to include("requester" => "agent", "count" => 3, "because" => "3 in a row")
    end

    it "never counts a human's deny" do
      3.times { answered(Lain::Approval::Verdict::Deny.new(note: "no")) }

      expect(breaker.tripped?("agent")).to be(false)
    end
  end
end
