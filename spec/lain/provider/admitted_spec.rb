# frozen_string_literal: true

# The join between a gate that knows about SERVERS and a provider that knows
# about its own endpoint and its own caller. Extracted when both arms needed the
# identical eight lines -- the point at which a duplicated policy starts to
# drift -- so it is exercised here against a bare includer rather than only
# through the two providers in `admission_spec.rb`.
RSpec.describe Lain::Provider::Admitted do
  # A minimal includer: the two messages the module depends on, and nothing
  # else. Depending on MESSAGES rather than on an includer's ivars is what lets
  # the two real arms resolve their endpoints differently.
  def caller_for(endpoint:, queue: true)
    Class.new do
      include Lain::Provider::Admitted

      define_method(:queue_for_capacity?) { queue }
      define_method(:resolved_endpoint) { endpoint }
      # `#admitted` is private, so the double needs a public way in.
      define_method(:run) { |&block| admitted(&block) }
    end.new
  end

  let(:endpoint) { "http://127.0.0.1:11434/#{SecureRandom.hex(4)}" }

  it "runs the block inside the endpoint's slot and returns its value" do
    expect(Sync { caller_for(endpoint:).run { :answered } }).to eq(:answered)
  end

  it "reports the callers inside while the block runs" do
    inside = nil

    Sync { caller_for(endpoint:).run { inside = Lain::Provider::Admission.for(endpoint:).in_flight } }

    expect(inside).to eq(1)
    expect(Lain::Provider::Admission.for(endpoint:).in_flight).to eq(0)
  end

  it "queues a willing caller behind the holder rather than refusing it" do
    events = []
    holder = caller_for(endpoint:)
    patient = caller_for(endpoint:)

    Sync do |task|
      held = task.async do
        holder.run do
          events << :holder_in
          task.sleep(0.15)
          events << :holder_out
        end
      end
      task.sleep(0.03)
      [held, task.async { patient.run { events << :patient_in } }].each(&:wait)
    end

    expect(events).to eq(%i[holder_in holder_out patient_in])
  end

  # The refusal has to be a StandardError, because {Oracle::Eager}'s task
  # boundary is what turns it into a skipped summary rather than a dead turn.
  it "refuses an unwilling caller by name, without running its block" do
    ran = false
    holder = caller_for(endpoint:)
    impatient = caller_for(endpoint:, queue: false)
    refusal = nil

    Sync do |task|
      held = task.async { holder.run { task.sleep(0.2) } }
      task.sleep(0.03)
      begin
        impatient.run { ran = true }
      rescue Lain::Provider::Admission::Busy => e
        refusal = e
      end
      held.wait
    end

    expect(refusal).to be_a(Lain::Provider::Admission::Busy).and be_a(StandardError)
    expect(refusal.message).to include(endpoint)
    expect(ran).to be(false)
  end

  it "admits an unwilling caller when the endpoint is free" do
    expect(Sync { caller_for(endpoint:, queue: false).run { :summarised } }).to eq(:summarised)
  end

  # A block returning nil must not read as a refusal: {Admission::REFUSED} is a
  # sentinel precisely so "ran, gave nothing" stays distinguishable.
  it "passes a nil result through rather than mistaking it for a refusal" do
    expect(Sync { caller_for(endpoint:, queue: false).run { nil } }).to be_nil
  end

  it "releases the slot when the block raises" do
    admitting = caller_for(endpoint:)

    Sync do
      expect { admitting.run { raise "boom" } }.to raise_error(RuntimeError, "boom")
    end

    expect(Lain::Provider::Admission.for(endpoint:).in_flight).to eq(0)
  end
end
