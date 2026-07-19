# frozen_string_literal: true

# OR-5: the adaptive-router arm. One agent, like {Arm::SingleThread}, but WHICH
# model (and shared sibling template) it runs under is chosen by
# {Oracle::Router} from the task's own text, BEFORE the child exists -- and
# that routing decision is journaled at the spawn boundary, never re-asked
# mid-session (the birth-boundary rule, made structural rather than a
# convention).
RSpec.describe Lain::Arm::AdaptiveRouter do
  let(:router) do
    Lain::Oracle::Router.heuristic(short_model: "claude-haiku-4", long_model: "claude-opus-4-8",
                                   long_after_chars: 20)
  end

  subject(:arm) { described_class.new(router:) }

  # A FRESH agent per call (Provider::Mock is stateful), built from whichever
  # `model:`/`template:` the router chose -- exactly the spawn_seam duck
  # `arm_spec`'s toy routing arm pins (`call(journal:, **spawn_opts) -> Agent`).
  let(:seen_spawn_opts) { [] }
  let(:spawn_seam) do
    lambda do |journal:, **spawn_opts|
      seen_spawn_opts << spawn_opts
      Lain::Agent.new(
        provider: Lain::Provider::Mock.new(
          responses: [text_response("done", model: spawn_opts.fetch(:model),
                                            usage: Lain::Usage.new(input_tokens: 100, output_tokens: 20))]
        ),
        toolset: Lain::Toolset.new([]),
        context: Lain::Context.new(model: spawn_opts.fetch(:model), max_tokens: 256),
        journal:
      )
    end
  end

  let(:grader) do
    Lain::Grader::Fixture.new("settled") do |f|
      f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
    end
  end

  describe "#run -- routes, then spawns, then runs" do
    it "spawns the child under the router's chosen model" do
      run = arm.run("fix the typo", spawn_seam:, grader:)

      expect(seen_spawn_opts).to eq([{ model: "claude-haiku-4", template: "" }])
      expect(run).to be_a(Lain::Arm::Run)
      expect(run.timeline.to_a.map(&:role)).to eq(%w[user assistant])
    end

    it "routes a long task to the long model" do
      arm.run("a" * 25, spawn_seam:, grader:)

      expect(seen_spawn_opts).to eq([{ model: "claude-opus-4-8", template: "" }])
    end

    it "grades the run with the injected grader" do
      run = arm.run("fix the typo", spawn_seam:, grader:)

      expect(run.grade).to be_a(Lain::Grader::Grade)
      expect(run.grade).to be_pass
    end

    it "records a non-negative wall-clock elapsed" do
      run = arm.run("fix the typo", spawn_seam:, grader:)

      expect(run.elapsed).to be_a(Float).and be >= 0
    end

    it "produces a Run priced through the run's own Ledger" do
      run = arm.run("fix the typo", spawn_seam:, grader:)

      expect(run.total_tokens).to eq(120)
    end

    it "acquires and releases the injected isolation lease" do
      lease = instance_double("lease", release: nil)
      isolation = instance_double("isolation", acquire: lease)

      arm.run("fix the typo", spawn_seam:, grader:, isolation:)

      expect(isolation).to have_received(:acquire)
      expect(lease).to have_received(:release)
    end
  end

  # ---- AC1: each routing decision is journaled at the spawn boundary --------

  describe "AC1 -- the routing decision is journaled as an oracle_answer" do
    it "journals a Telemetry::OracleAnswer naming the router's own oracle_digest, on the run's own journal" do
      # #run drains the run's journal exactly once, into its own Ledger --
      # so the routing record is caught here, at the one seam it flows
      # through, rather than by re-draining an already-drained Channel.
      captured = nil
      allow(Lain::Ledger).to receive(:from_journal).and_wrap_original do |original, entries, **kwargs|
        captured = entries
        original.call(entries, **kwargs)
      end

      arm.run("fix the typo", spawn_seam:, grader:)

      oracle_records = captured.select { |entry| entry["type"] == "oracle_answer" }
      expect(oracle_records.size).to eq(1)
      expect(oracle_records.first).to include(
        "oracle_digest" => Lain::Oracle::Router.definition.digest,
        "answer" => { "model" => "claude-haiku-4", "template" => "", "reason" => "task length 12 < 20" }
      )
    end
  end

  # ---- AC2: re-routing mid-session is structurally impossible ---------------

  describe "AC2 -- re-routing mid-session is structurally impossible" do
    it "never hands the router to the spawned Agent -- nothing returned from #run can reach it" do
      run = arm.run("fix the typo", spawn_seam:, grader:)

      expect(run.to_h.values).not_to include(router)
      expect(Lain::Agent.instance_methods(false)).not_to include(:router, :reroute, :re_route)
    end

    it "carries no public accessor back to the router or its definition on the arm itself" do
      expect(arm).not_to respond_to(:router)
      expect(arm).not_to respond_to(:definition)
    end

    it "asks the router exactly ONCE per #run -- never again once the child is spawned" do
      allow(router).to receive(:ask).and_call_original

      arm.run("fix the typo", spawn_seam:, grader:)

      expect(router).to have_received(:ask).once
    end
  end
end
