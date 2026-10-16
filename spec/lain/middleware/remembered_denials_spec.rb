# frozen_string_literal: true

RSpec.describe Lain::Middleware::RememberedDenials do
  let(:home) { "/home/tester" }
  let(:project) { "#{home}/project" }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: project)).confined(roots: [project])
  end
  let(:queue) { instance_double(Lain::Approval::Queue, denied: nil) }
  let(:denial) { "approval denied for tool %<name>s" }
  let(:layer) { described_class.new(queue:, sensitivity: policy, denial:) }

  def call(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)
  def lists(path) = call("list_files", { "path" => path })
  def in_project = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: project, env: {}))

  def through(effect, context: in_project, via: layer)
    reached = []
    env = via.call({ effect:, tool: Lain::Toolset::Unheld.new("unused"), context: }) do |inner|
      reached << inner.fetch(:effect)
      inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
    end
    [env.fetch(:result), reached]
  end

  def remembering(requester, path, reason = "not your business")
    allow(queue).to receive(:denied).with(requester:, path:).and_return(reason)
  end

  describe "a gated path the requester was denied" do
    before { remembering("agent", "/home/joel") }

    it "is refused in the gate's own words with the human's reason, never reaching downstream" do
      result, reached = through(lists("/home/joel"))

      expect(result).to have_attributes(is_error: true,
                                        content: 'approval denied for tool "list_files": not your business')
      expect(reached).to be_empty
    end

    it "is refused through an approval wrapper, judged by the call inside it" do
      result, = through(Lain::Effect::Approval.new(effect: lists("/home/joel")))

      expect(result).to have_attributes(is_error: true)
    end

    it "is resolved against the call's own cwd before the queue is asked" do
      result, = through(lists("../../joel"))

      expect(result).to have_attributes(is_error: true)
    end

    it "says only the gate's words when the human gave none" do
      remembering("agent", "/home/joel", "")

      expect(through(lists("/home/joel")).first.content).to eq('approval denied for tool "list_files"')
    end
  end

  it "passes a path the session refuses outright on to that refusal, whatever the queue remembers" do
    remembering("agent", "#{home}/.ssh/id_ed25519")

    expect(through(lists("#{home}/.ssh/id_ed25519")).last).to eq([lists("#{home}/.ssh/id_ed25519")])
  end

  it "journals a refusal from memory as a human's deny by its own rung" do
    remembering("agent", "/home/joel")
    journal = []

    through(lists("/home/joel"), via: described_class.new(queue:, sensitivity: policy, denial:, journal:))

    expect(journal).to contain_exactly(
      a_hash_including("type" => "escalation", "tool" => "list_files", "tool_use_id" => "tu_1",
                       "verdict" => "deny", "rung" => "remembered", "authority" => "human",
                       "requester" => "agent")
    )
  end

  # Directory names count from a leased worker's checkout, not from the cwd
  # below it, so a secret-named directory of the checkout is still gated.
  it "judges the path from the checkout when the cwd sits below it" do
    root = "/w/app"
    checkout = "/w/co"
    guarded = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:))
    leased = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "#{checkout}/sub", env: {}, checkout:))
    remembering("agent", "#{checkout}/secrets/prod.yml")
    reading = described_class.new(queue:, sensitivity: guarded, denial:)

    result, = through(call("read_file", { "path" => "../secrets/prod.yml" }), context: leased, via: reading)

    expect(result).to have_attributes(is_error: true)
  end

  it "passes a gated path the queue remembers nothing for" do
    expect(through(lists("/home/joel")).last).to eq([lists("/home/joel")])
  end

  it "passes an ordinary path even when the queue remembers a denial over it" do
    remembering("agent", "#{project}/lib/a.rb")

    expect(through(lists("#{project}/lib/a.rb")).first).to have_attributes(is_error: false)
  end

  it "passes a call that names no path" do
    expect(through(call("dangerous", { "text" => "boom" })).first).to have_attributes(is_error: false)
  end

  it "asks for the requester its stack was built for" do
    remembering("researcher", "/home/joel")

    for_researcher = described_class.new(queue:, sensitivity: policy, denial:, requester: "researcher")

    result, = through(lists("/home/joel"), via: for_researcher)

    expect(result).to have_attributes(is_error: true)
  end

  it "asks for the requester the context names when the stack names none" do
    remembering("researcher", "/home/joel")

    result, = through(lists("/home/joel"),
                      context: Lain::Approval::PolicySwitch::Requested.new(in_project, "researcher"))

    expect(result).to have_attributes(is_error: true)
  end

  it "reads a path's ~ as the policy's home" do
    remembering("agent", "#{home}/notes")
    homed = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: project), home:)
                                     .confined(roots: [project])

    expect(through(lists("~/notes"), via: described_class.new(queue:, sensitivity: homed, denial:)).first)
      .to have_attributes(is_error: true)
  end

  describe "a bash call" do
    def runs(command, **input) = call("bash", { "command" => command, **input })

    it "is refused when a path its command names was denied and is gated" do
      remembering("agent", "#{project}/.env")

      expect(through(runs("cat .env")).first)
        .to have_attributes(is_error: true, content: 'approval denied for tool "bash": not your business')
    end

    it "reads ~ in the command as the policy's home" do
      remembering("agent", "#{home}/notes")
      homed = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: project), home:)
                                       .confined(roots: [project])

      expect(through(runs("cat ~/notes"), via: described_class.new(queue:, sensitivity: homed, denial:)).first)
        .to have_attributes(is_error: true)
    end

    it "passes a path the session refuses outright on to that refusal, whatever the queue remembers" do
      remembering("agent", "#{home}/.ssh/id_ed25519")
      reads = runs("cat #{home}/.ssh/id_ed25519")

      expect(through(reads).last).to eq([reads])
    end

    it "passes when the denied path it names is ordinary" do
      remembering("agent", "#{project}/lib/a.rb")

      expect(through(runs("cat lib/a.rb")).first).to have_attributes(is_error: false)
    end

    it "is judged by the paths its command names, not by the directory it runs in" do
      remembering("agent", "/home/joel")

      expect(through(runs("make", "cwd" => "/home/joel")).first).to have_attributes(is_error: false)
    end

    it "passes when its paths cannot be named" do
      remembering("agent", "#{project}/.env")

      expect(through(runs('cat "$PWD/.env"')).first).to have_attributes(is_error: false)
    end
  end

  it "remembers nothing for a run with no queue" do
    unattended = described_class.new(queue: described_class::Unattended, sensitivity: policy, denial:)

    expect(through(lists("/home/joel"), via: unattended).first).to have_attributes(is_error: false)
  end
end
