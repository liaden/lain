# frozen_string_literal: true

RSpec.describe Lain::Exec::Priming do
  let(:trail) { [] }
  let(:slot) do
    Class.new do
      def initialize(trail) = @trail = trail
      def prime = @trail << :prime
      def unwritable_by?(_dirs) = false
    end.new(trail)
  end
  let(:inner) do
    Class.new do
      def initialize(trail) = @trail = trail
      def takes_term?(term) = term.stages.size == 1
      def child_env = :inner_env

      def call(**kwargs)
        @trail << [:ran, kwargs.fetch(:command)]
        Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
      end
    end.new(trail)
  end
  let(:priming) { described_class.new(inner, snapshots: -> { slot }) }

  # No sandbox chooses a profile here, so any call may write under the root.
  it "primes the round's snapshot before every call it runs" do
    2.times { priming.call(command: "true", cwd: Dir.pwd, env: {}, timeout: 5) }

    expect(trail).to eq([:prime, [:ran, "true"], :prime, [:ran, "true"]])
  end

  it "answers for a term and a child env as its inner exec does" do
    expect([priming.takes_term?(Lain::Shell::Term.of(%w[cat a])), priming.child_env]).to eq([true, :inner_env])
  end

  it "reads the slot at each call, so a slot bound after construction is the one primed" do
    late = nil
    built = described_class.new(inner, snapshots: -> { late })
    late = slot

    built.call(command: "true", cwd: Dir.pwd, env: {}, timeout: 5)

    expect(trail.first).to eq(:prime)
  end

  describe Lain::Exec::Priming::ByProfile do
    # The call dir is made when the profile is chosen, and nothing else removes it before the call runs.
    it "removes the call's own tmpdir when the prime raises, and lets the error through" do
      Dir.mktmpdir("lain-priming") do |dir|
        call_dir = File.join(dir, "call").tap { Dir.mkdir(_1) }
        profile = Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: [dir], call_tmpdir: call_dir)
        chosen = Struct.new(:profile) { def for(_request) = profile }.new(profile)
        failing = Class.new do
          def prime = raise(Async::Stop)
          def unwritable_by?(_dirs) = false
        end.new
        by = described_class.new(chosen, snapshots: -> { failing })

        expect { by.for(nil) }.to raise_error(Async::Stop)
        expect(File.exist?(call_dir)).to be(false)
      end
    end

    it "keeps the call's own tmpdir when the prime succeeds" do
      Dir.mktmpdir("lain-priming") do |dir|
        call_dir = File.join(dir, "call").tap { Dir.mkdir(_1) }
        profile = Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: [dir], call_tmpdir: call_dir)
        chosen = Struct.new(:profile) { def for(_request) = profile }.new(profile)

        expect(described_class.new(chosen, snapshots: -> { slot }).for(nil)).to be(profile)
        expect(File.exist?(call_dir)).to be(true)
      end
    end
  end

  describe ".over" do
    it "leaves a sandboxed exec bare, since it primes by the profile it applies" do
      sandboxed = Lain::Exec::Sandboxed.new(inner: Lain::Exec::Local.new, launcher: nil, profiles: nil, journal: [])

      expect(described_class.over(sandboxed, snapshots: -> { slot })).to be(sandboxed)
    end

    it "wraps any other exec" do
      expect(described_class.over(inner, snapshots: -> { slot })).to be_a(described_class)
    end
  end
end
