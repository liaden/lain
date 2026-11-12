# frozen_string_literal: true

require "json"

RSpec.describe Lain::Tools::Subagent::Stops do
  subject(:stops) { described_class.new(role: "dev", journal:) }

  let(:journal) { [] }
  let(:builder) { Struct.new(:budget).new(Lain::Budget.ceilings(iterations: 20)) }

  # A lease a stop kept: where it is, and what was snapshotted of it.
  let(:held) { Struct.new(:path, :snapshot).new("/w/children/4bfe", "c0ffee") }

  def stopped(label: "skeleton", spawn: "blake3:spawn", scope: Lain::Session::Unconfined, lease: -> {},
              parent: "blake3:chat")
    Lain::Tools::Subagent::Stopped.new(label:, spawn:, head: nil, prompt: "build the skeleton", builder:,
                                       announced: Lain::Requester.of(label), scope:, lease:, parent:)
  end

  describe "#keeping" do
    it "journals the stop, naming where the child worked and why it stopped" do
      stops.keeping(stopped, ->(**) { held }).call("blake3:head", :iterations)

      expect(journal).to eq([Lain::Telemetry::ChildStopped.new(
        spawn: "blake3:spawn", label: "skeleton", role: "dev", head: "blake3:head",
        lease_path: "/w/children/4bfe", ceiling: 20, reason: :iterations, snapshot: "c0ffee",
        task: "build the skeleton", parent: "blake3:chat", kept: false
      )])
    end

    it "tells the parent how to resume the child, under its role" do
      sentence = stops.keeping(stopped, ->(**) { held }).call("blake3:head", :transport)

      expect(sentence).to include('role: "dev", resume: "skeleton"')
    end

    it "holds the child at its head, lending the kept lease to whoever resumes it" do
      stops.keeping(stopped, ->(**) { held }).call("blake3:head", :interrupted)
      kept = stops.fetch("skeleton", parent: "blake3:chat") { raise "not held" }

      expect(kept.head).to eq("blake3:head")
      expect(kept.relet.call.lend(:the_runs_own_leases)).to be(held)
    end

    it "leaves a child with no lease of its own to lease afresh" do
      fresh = -> { Lain::Session::Unconfined }
      stops.keeping(stopped(lease: fresh), ->(**) {}).call("blake3:head", :iterations)

      expect(stops.fetch("skeleton", parent: "blake3:chat") { raise "not held" }.relet).to be(fresh)
      expect(journal.first).to have_attributes(lease_path: nil, snapshot: nil)
    end

    it "names a kept directory as where the child worked, and the working directory it had there" do
      worktree = "/state/research/worktrees/1f2e"
      dir = Struct.new(:root, :worker_env).new(worktree, Lain::WorkerEnv.new(cwd: "#{worktree}/sub", env: {}))
      stops.keeping(stopped(scope: dir), ->(**) {}).call("blake3:head", :iterations)

      expect(journal.first).to have_attributes(lease_path: worktree, kept: true, cwd: "#{worktree}/sub")
    end

    it "asks the lease to outlast the run only when a later run can resume the child" do
      asked = []
      described_class.new(role: "dev", journal:, lasting: false)
                     .keeping(stopped, ->(lasting:) { (asked << lasting) && held }).call("blake3:head", :iterations)

      expect(asked).to eq([false])
    end

    it "offers a held child only to the parent it stopped under" do
      stops.keeping(stopped, ->(**) { held }).call("blake3:head", :iterations)

      expect(stops.fetch("skeleton", parent: "blake3:a-child") { |labels| labels }).to eq([])
      expect(stops.fetch("skeleton", parent: "blake3:chat") { raise "not held" }.label).to eq("skeleton")
    end
  end

  describe ".from_journal" do
    def spawn_line(digest, resumed_from: nil)
      body = { "task" => "blake3:task", **({ "resumed_from" => resumed_from } if resumed_from).to_h }
      Lain::Telemetry::Message.new(digest:, kind: :spawn, from: "blake3:parent", to: "blake3:child", payload: body,
                                   causal_parents: [], correlation: "blake3:root").to_journal
    end

    def stop_line(spawn, label, role: "dev")
      Lain::Telemetry::ChildStopped.new(spawn:, label:, role:, head: "blake3:#{label}-head",
                                        lease_path: "/w/#{label}", ceiling: 20, reason: :iterations,
                                        snapshot: "#{label}-snap", task: "build the #{label}").to_journal
    end

    def lines(*records) = records.map { |record| JSON.generate(record) }

    it "lists every stopped child with the task it was spawned with" do
      restored = described_class.from_journal(lines(spawn_line("blake3:s1"), stop_line("blake3:s1", "skeleton")))

      expect(restored.map { |stop| [stop.label, stop.head, stop.task] })
        .to eq([["skeleton", "blake3:skeleton-head", "build the skeleton"]])
    end

    it "leaves out a child a later spawn resumed" do
      restored = described_class.from_journal(lines(spawn_line("blake3:s1"), stop_line("blake3:s1", "skeleton"),
                                                    spawn_line("blake3:s2", resumed_from: "blake3:s1")))

      expect(restored).to be_empty
    end

    it "lists a resumed child again once its resume stopped too" do
      restored = described_class.from_journal(lines(spawn_line("blake3:s1"), stop_line("blake3:s1", "skeleton"),
                                                    spawn_line("blake3:s2", resumed_from: "blake3:s1"),
                                                    stop_line("blake3:s2", "skeleton")))

      expect(restored.map(&:spawn)).to eq(["blake3:s2"])
    end
  end

  describe "#restore" do
    let(:restored) do
      records = { "skeleton" => "dev", "notes" => "researcher" }.map do |label, role|
        Lain::Telemetry::ChildStopped.new(spawn: "blake3:#{label}", label:, role:, head: "blake3:h",
                                          reason: :iterations, parent: "blake3:chat")
      end
      described_class.from_journal(records.map(&:to_journal))
    end

    it "holds the stopped children of its own role, under their labels" do
      stops.restore(restored) { |stop| stopped(label: stop.label, parent: stop.parent) }

      expect(stops.fetch("skeleton", parent: "blake3:chat") { raise "not held" }.label).to eq("skeleton")
      expect(stops.fetch("notes", parent: "blake3:chat") { |held| held }).to eq(["skeleton"])
    end
  end
end
