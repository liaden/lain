# frozen_string_literal: true

RSpec.describe Lain::CLI::Wiring::JudgeSource do
  let(:question) { { tool: "bash", input: { "command" => "rm -rf build" }, place: } }
  let(:place) { Lain::Approval::Judge::Place.new(root: "/p", cwd: "/p", requester: "main", outside: []) }
  let(:judge) { instance_double(Lain::Approval::Judge, call: :approve) }

  it "reads the spawn seam at the first judged call, not when it is built" do
    reads = 0
    described_class.new(-> { reads += 1 })

    expect(reads).to eq(0)
  end

  it "builds the judge once across two judged calls, and answers its verdict" do
    spawn = instance_double(Lain::Skill::RoleSpawn)
    allow(Lain::Approval::Judge).to receive(:new).with(role_spawn: spawn).and_return(judge)
    source = described_class.new(-> { spawn })

    expect(Array.new(2) { source.call(**question) }).to eq(%i[approve approve])
    expect(Lain::Approval::Judge).to have_received(:new).once
  end

  # A judge that cannot be built is a fault like any other the judge has.
  it "answers :fault and tells the fault callback when the judge cannot be built" do
    allow(Lain::Approval::Judge).to receive(:new).and_raise(IOError, "no spawn seam")
    faults = []

    verdict = described_class.new(-> {}).call(**question) { |why| faults << why }

    expect([verdict, faults]).to eq([:fault, ["IOError: no spawn seam"]])
  end

  it "forwards the place to the judge" do
    allow(Lain::Approval::Judge).to receive(:new).and_return(judge)

    described_class.new(-> {}).call(**question)

    expect(judge).to have_received(:call).with(**question)
  end

  it "answers :fault with no callback given" do
    allow(Lain::Approval::Judge).to receive(:new).and_raise(IOError, "no spawn seam")

    expect(described_class.new(-> {}).call(**question)).to eq(:fault)
  end
end
