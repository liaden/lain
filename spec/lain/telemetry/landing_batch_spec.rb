# frozen_string_literal: true

RSpec.describe Lain::Telemetry::LandingBatch do
  def build(**overrides)
    described_class.new(branch: "main", desk: :parent, verifier: "rake spec", worker_keys: %w[w-1 w-2],
                        landed: %w[w-1 w-2], ejected: [], declined: [], verifies: 1, rebuilds: 0,
                        verify_wall_s: 1.5, queue_wait_s: { "w-1" => 0.2, "w-2" => 0.4 },
                        outcome: :landed, **overrides)
  end

  it "journals under its own short name, deeply frozen and shareable" do
    record = build(worker_keys: [+"w-1", +"w-2"], branch: +"main")

    expect(record.to_journal).to include("type" => "landing_batch", "worker_keys" => %w[w-1 w-2],
                                         "desk" => :parent, "outcome" => :landed)
    expect(record).to be_deeply_frozen
    expect(record).to be_deeply_frozen
  end

  it "journals which landed workers were flagged, none by default" do
    expect(build.flagged).to eq({})
    record = build(flagged: { +"w-1" => [+"hooks .husky/pre-push"] })

    expect(record.to_journal["flagged"]).to eq("w-1" => ["hooks .husky/pre-push"])
    expect(record).to be_deeply_frozen
  end

  it "answers landing_batch to no other Journalable" do
    others = ObjectSpace.each_object(Class).select { |klass| klass.include?(Lain::Telemetry::Journalable) && klass.name }
                        .reject { |klass| klass == described_class }
                        .select { |klass| klass.name.split("::").last.underscore == "landing_batch" }

    expect(others).to be_empty
  end

  it "refuses an outcome outside landed, partial and none, naming the field" do
    expect { build(outcome: "maybe") }.to raise_error(ArgumentError, %r{outcome.*landed/partial/none})
  end

  it "refuses a desk that is neither parent nor candidate" do
    expect { build(desk: :elsewhere) }.to raise_error(ArgumentError, /desk/)
  end

  it "refuses a record that names no branch" do
    expect { build(branch: nil) }.to raise_error(ArgumentError, /branch/)
  end

  describe "journal bytes" do
    it "prints every field when all are set" do
      record = build(verifies: 2, rebuilds: 1, ejected: %w[w-2], landed: %w[w-1], outcome: :partial,
                     queue_wait_s: { "w-1" => 0.2, "w-2" => 3 }, flagged: { "w-1" => ["hooks"] })

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"landing_batch","branch":"main","desk":"parent","verifier":"rake spec",' \
        '"worker_keys":["w-1","w-2"],"landed":["w-1"],"ejected":["w-2"],"declined":[],"verifies":2,' \
        '"rebuilds":1,"verify_wall_s":1.5,"queue_wait_s":{"w-1":0.2,"w-2":3.0},"outcome":"partial",' \
        '"flagged":{"w-1":["hooks"]}}'
      )
    end

    it "prints null and empty collections for every optional field" do
      record = build(verifier: nil, worker_keys: [], landed: [], queue_wait_s: {})

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"landing_batch","branch":"main","desk":"parent","verifier":null,"worker_keys":[],' \
        '"landed":[],"ejected":[],"declined":[],"verifies":1,"rebuilds":0,"verify_wall_s":1.5,' \
        '"queue_wait_s":{},"outcome":"landed","flagged":{}}'
      )
    end
  end

  describe "interning and refusals" do
    def fresh
      build(branch: +"main", verifier: +"v", worker_keys: [+"w-1"], landed: [+"w-1"], ejected: [+"w-2"],
            declined: [+"w-3"])
    end

    it "interns branch, verifier and every key list across equal records" do
      a = fresh
      b = fresh

      expect([a.branch.equal?(b.branch), a.verifier.equal?(b.verifier), a.worker_keys.first.equal?(b.worker_keys.first),
              a.landed.first.equal?(b.landed.first), a.ejected.first.equal?(b.ejected.first),
              a.declined.first.equal?(b.declined.first)]).to eq([true] * 6)
    end

    it "interns each flag across equal records" do
      a = build(flagged: { +"w-1" => [+"hooks"] })
      b = build(flagged: { +"w-1" => [+"hooks"] })

      expect(a.flagged["w-1"].first).to equal(b.flagged["w-1"].first)
    end

    it "refuses an unknown keyword, a missing one and a nil list with ArgumentError or TypeError" do
      expect { build(bogus: 1) }.to raise_error(ArgumentError)
      expect { build(verifies: nil) }.to raise_error(TypeError)
      expect { build(landed: nil) }.to raise_error(NoMethodError)
    end
  end
end
