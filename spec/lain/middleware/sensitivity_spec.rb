# frozen_string_literal: true

RSpec.describe Lain::Middleware::Sensitivity do
  # The session's ONE path policy, real: the same object the gate one layer in
  # consults for its own axis, so every example below drives the real
  # extraction, the real tool->field table and the real classifier rather than
  # a fake agreeing with itself.
  def denying(classifier) = Lain::Sensitivity::Policy.new(sensitivity: classifier)

  def reads(path, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name: "read_file", input: { "path" => path })
  end

  def call(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  # One pass over a downstream that records what got past the refusal.
  # Answers the result and the effects that reached downstream.
  def through(layer, effect)
    reached = []
    env = layer.call({ effect:, tool: Lain::Toolset::Unheld.new("unused"), context: nil }) do |inner|
      reached << inner.fetch(:effect)
      inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
    end
    [env.fetch(:result), reached]
  end

  def result_of(layer, effect) = through(layer, effect).first

  let(:home) { "/home/tester" }
  let(:project) { "#{home}/project" }
  let(:classifier) { Lain::Sensitivity.new(home:, cwd: project) }
  let(:journal) { [] }
  let(:policy) { denying(classifier) }
  let(:layer) { described_class.new(sensitivity: policy, journal:) }

  describe "a denied path" do
    it "refuses it, naming the path as a protected path" do
      result = result_of(layer, reads("#{home}/.ssh/id_ed25519"))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("refused", "#{home}/.ssh/id_ed25519", "protected path")
    end

    it "never lets the effect reach downstream" do
      expect(through(layer, reads("#{home}/.ssh/id_ed25519")).last).to be_empty
    end

    # The tell that the refusal is decided BEFORE the tool runs: the file is
    # real, holds real key bytes, and none of them appear in the answer. Driven
    # through the real runner and a real ReadFile, so the claim is about what
    # the model is told.
    it "names the path and none of the file's bytes", :seam do
      dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(dir, ".ssh"))
      path = File.join(dir, ".ssh", "id_ed25519")
      File.write(path, "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEQ\n")
      refusing = described_class.new(sensitivity: denying(Lain::Sensitivity.new(home:, cwd: dir)), journal:)

      result = dispatch_call("read_file", { "path" => path }, toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new]),
                                                              layers: [refusing], context: Lain::Session.new)

      expect(result.content).to include(path)
      expect(result.content).not_to include("PRIVATE KEY", "b3BlbnNzaC1rZXktdjEQ")
    ensure
      FileUtils.remove_entry(dir)
    end

    # Loud is the point: a refusal that only says "no" gets resent verbatim,
    # so the message has to say the boundary cannot be moved.
    it "tells the model no approval can lift it, so it stops retrying variants" do
      expect(result_of(layer, reads("#{home}/.ssh/id_ed25519")).content).to include("no approval can lift")
    end

    it "reports the refusal rather than raising, so the loop keeps running" do
      expect { through(layer, reads("#{home}/.ssh/id_ed25519")) }.not_to raise_error
    end
  end

  describe "the journal" do
    it "records exactly one ReadRefused, naming the path and the reason" do
      through(layer, reads("#{home}/.ssh/id_ed25519", id: "tu_7"))

      expect(journal.size).to eq(1)
      expect(journal.first).to be_a(Lain::Telemetry::ReadRefused)
      expect(journal.first).to have_attributes(tool_use_id: "tu_7", path: "#{home}/.ssh/id_ed25519",
                                               reason: "protected")
    end

    # The reason travels from the VERDICT, not from a constant here: a path a
    # project's own `[sensitivity] denied` names refuses under its own reason,
    # so "why is my file denied?" is answerable without reading our table.
    it "carries the verdict's real reason, so a config denial is not reported as ours" do
      rules = Lain::Sensitivity::Rules.from({ "denied" => ["*.secret"] })
      configured = described_class.new(sensitivity: denying(Lain::Sensitivity.new(home:, cwd: project, rules:)),
                                       journal:)

      result = result_of(configured, reads("#{project}/prod.secret"))

      expect(journal.first).to have_attributes(reason: "configured")
      expect(result.content).to include("named by this project's sensitivity config")
    end

    it "writes nothing at all for a path it does not refuse" do
      through(layer, reads("README.md"))

      expect(journal).to be_empty
    end

    # Channel::Null is the default so a stack that wired no journal refuses
    # exactly as loudly and no caller writes `if journal`.
    it "refuses with no journal wired" do
      expect(result_of(described_class.new(sensitivity: policy), reads("#{home}/.ssh/id_ed25519")))
        .to have_attributes(is_error: true)
    end
  end

  describe "what it lets pass" do
    it "passes an ordinary path downstream" do
      effect = reads("README.md")

      expect(through(layer, effect)).to eq([Lain::Tool::Result.ok("downstream ran"), [effect]])
    end

    # A GATED path is approvable, so it is not this layer's business: it
    # belongs to the gate, one layer in. Refusing it here would take away the
    # human's move.
    it "passes a gated path, so the effect reaches the gate" do
      effect = reads(".env")

      expect(classifier.classify("#{project}/.env")).to have_attributes(gated?: true, denied?: false)
      expect(through(layer, effect).last).to eq([effect])
    end

    it "passes a tool the path table does not name" do
      effect = call("web_search", { "path" => "#{home}/.ssh/id_rsa" })

      expect(through(layer, effect).last).to eq([effect])
    end

    # The dispatch path is synchronous and runs before Tool::Input validation,
    # so a shape carrying no readable field must PASS rather than raising --
    # the repair a raise here invites is a `rescue` answering "not denied",
    # which is this boundary failing open.
    it "passes shapes that name no path, rather than raising on them" do
      %w[read_file bash].product([[], "just a string", nil, { "path" => 42 }]).each do |name, input|
        effect = call(name, input)
        expect { through(layer, effect) }.not_to raise_error
        expect(through(layer, effect).last).to eq([effect])
      end
    end

    it "passes a ModelCall, which names no path at all" do
      effect = Lain::Effect::ModelCall.new(request: nil)

      expect(through(layer, effect).last).to eq([effect])
    end
  end

  # The table is `Sensitivity::Policy`'s, and this layer holds none of its
  # own: `bash` names its directory in `cwd`, not `path`, and a second table
  # here would be the drift this whole boundary exists to prevent.
  describe "the tool->field table is the shared one" do
    it "refuses a bash call whose cwd is denied" do
      expect(result_of(layer, call("bash", { "cwd" => "#{home}/.gnupg" }))).to have_attributes(is_error: true)
    end

    # A WRITE to a denied path is refused too, and must be: the table names
    # `write_file` and `edit_file` beside the readers, and writing to
    # `~/.ssh/id_ed25519` is not the lesser act.
    it "refuses a write to a denied path, not only a read" do
      effect = call("write_file", { "path" => "#{home}/.ssh/id_ed25519", "content" => "x" })

      expect(result_of(layer, effect)).to have_attributes(is_error: true)
    end

    it "gives a refused writer advice that names no verb" do
      refused = result_of(layer, call("edit_file", { "path" => "#{home}/.ssh/id_ed25519" }))

      expect(refused.content).to include("name a different path")
      expect(refused.content).not_to include("read something else")
    end

    it "journals the refused tool, so a write is not tallied as a read" do
      through(layer, call("write_file", { "path" => "#{home}/.ssh/id_ed25519" }))
      through(layer, call("bash", { "cwd" => "#{home}/.gnupg" }))

      expect(journal.map(&:tool)).to eq(%w[write_file bash])
    end

    it "refuses an ast_search on a denied path, which returns the same bytes read_file would" do
      expect(result_of(layer, call("ast_search", { "path" => "#{home}/.ssh/id_rsa" })))
        .to have_attributes(is_error: true)
    end

    # {Tool::Input} COERCES rather than refuses, so a Pathname passed here
    # would be read anyway -- the fail-open a review demonstrated end to end.
    it "refuses a Pathname spelling of a denied path" do
      expect(result_of(layer, reads(Pathname.new("#{home}/.ssh/id_rsa")))).to have_attributes(is_error: true)
    end

    it "reads the field under either key spelling" do
      expect(result_of(layer, call("read_file", { path: "#{home}/.ssh/id_rsa" }))).to have_attributes(is_error: true)
    end
  end

  # Sitting ahead of the gate means this layer sees the {Effect::Approval}
  # wrapper the gate would otherwise unwrap first. Left alone, wrapping a
  # denied read would have LIFTED the denial: not a tool_call?, so passed
  # here, unwrapped by the gate, approved. The unwrap lives in
  # {Sensitivity::Policy#denial} -- the object both axes already consult --
  # rather than being a second copy of the gate's contract in this class.
  describe "an Approval wrapper" do
    def wrapped(effect) = Lain::Effect::Approval.new(effect:)

    it "does not lift a denial by wrapping it" do
      result, reached = through(layer, wrapped(reads("#{home}/.ssh/id_ed25519")))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("protected path")
      expect(reached).to be_empty
    end

    it "does not lift one by wrapping it twice either" do
      expect(result_of(layer, wrapped(wrapped(reads("#{home}/.ssh/id_ed25519"))))).to have_attributes(is_error: true)
    end

    it "journals the wrapped refusal against the inner call's tool_use_id" do
      through(layer, wrapped(reads("#{home}/.ssh/id_ed25519", id: "tu_9")))

      expect(journal.size).to eq(1)
      expect(journal.first).to have_attributes(tool_use_id: "tu_9", path: "#{home}/.ssh/id_ed25519")
    end

    # Wrapping does not PROMOTE a gated path either -- it stays the gate's,
    # which is the whole point of the wrapper.
    it "leaves a wrapped gated path to the gate" do
      effect = wrapped(reads(".env"))

      expect(through(layer, effect).last).to eq([effect])
    end

    # The asymmetry, asserted so nobody "tidies" it away: `gates?` must NOT
    # unwrap, because the gate unwraps before consulting it, and teaching it to
    # would change WHEN the gate fires. `denial` must, because this layer runs
    # before that unwrap ever happens.
    it "is unwrapped by #denial and deliberately not by #gates?" do
      effect = wrapped(reads("#{home}/.ssh/id_ed25519"))

      expect(policy.denial(effect, cwd: project)).to have_attributes(path: "#{home}/.ssh/id_ed25519")
      expect(policy.gates?(effect, cwd: project)).to be(false)
    end
  end

  # A relative path resolves where the TOOL will resolve it: the call's own
  # session, whose cwd a worktree or `/mode plan` moves away from the project's.
  describe "a link to a denied file" do
    around do |example|
      Dir.mktmpdir("lain-sensitivity-link") do |dir|
        @base = File.realpath(dir)
        example.run
      end
    end

    let(:home) { File.join(@base, "home") }
    let(:project) { File.join(@base, "project") }
    let(:worker) { File.join(@base, "worker") }

    before do
      FileUtils.mkdir_p([File.join(home, ".ssh"), project, worker])
      File.write(File.join(home, ".ssh", "id_ed25519"), "PRIVATE KEY\n")
      File.symlink(File.join(home, ".ssh", "id_ed25519"), File.join(worker, "notes.txt"))
    end

    def in_session(cwd) = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: {}))

    def refused(context)
      layer.call({ effect: reads("notes.txt"), tool: Lain::Toolset::Unheld.new("unused"), context: }) do |inner|
        inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
      end.fetch(:result)
    end

    it "refuses it, resolving the link against the call's worker cwd" do
      expect(refused(in_session(worker)).content).to include("refused", "notes.txt", "protected path")
      expect(journal.map(&:reason)).to eq(["protected"])
    end

    it "leaves the same name alone where the worker's cwd holds no such link" do
      expect(refused(in_session(project)).content).to eq("downstream ran")
    end
  end

  # The whole reason this is a layer AHEAD of the gate rather than a gate
  # policy answer: a gate policy is boolean and every boolean is approvable.
  # Driven through the real runner, ReadFile and all.
  describe "ahead of the gate" do
    let(:readers) { Lain::Toolset.new([Lain::Tools::ReadFile.new]) }

    def gate(policy, sensitivity: Lain::Sensitivity::Policy::Null.instance)
      Lain::Middleware::Gate.new(policy:, sensitivity:)
    end

    it "still refuses a denied path under ApproveAll" do
      result = dispatch_call("read_file", { "path" => "#{home}/.ssh/id_ed25519" },
                             toolset: readers, layers: [layer, gate(Lain::Middleware::Gate::ApproveAll.new)],
                             context: Lain::Session.new)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("protected path")
    end

    # The complement, and the one that proves the stack is really composed:
    # the same ApproveAll that cannot lift a denial DOES lift a gated path.
    it "lets ApproveAll approve a gated path, which is what makes a denial different", :seam do
      dir = Dir.mktmpdir
      File.write(File.join(dir, ".env"), "TOKEN=shhh")
      path_policy = denying(Lain::Sensitivity.new(home:, cwd: dir))
      layers = [described_class.new(sensitivity: path_policy, journal:),
                gate(Lain::Middleware::Gate::ApproveAll.new, sensitivity: path_policy)]

      result = dispatch_call("read_file", { "path" => File.join(dir, ".env") }, toolset: readers, layers:,
                                                                                context: Lain::Session.new)

      expect(result.content).to include("TOKEN=shhh")
    ensure
      FileUtils.remove_entry(dir)
    end

    it "hands a gated path on to the gate, which then applies its own policy", :seam do
      layers = [layer, gate(Lain::Middleware::Gate::DenyAll.new, sensitivity: policy)]

      result = dispatch_call("read_file", { "path" => ".env" }, toolset: readers, layers:, context: Lain::Session.new)

      expect(result.content).to include("approval denied")
      expect(journal).to be_empty
    end
  end

  # ONE Null for the role, not two. A Null answering only `denial` would be an
  # object this layer accepts and the gate rejects (NoMethodError: gates?),
  # which contradicts the premise that both layers take the same object.
  describe "the default policy" do
    it "denies nothing, so a stack that wired no policy behaves as it did before this boundary" do
      effect = reads("#{home}/.ssh/id_ed25519")

      expect(through(described_class.new, effect)).to eq([Lain::Tool::Result.ok("downstream ran"), [effect]])
    end

    it "is the same shared Null the gate defaults to, so either layer takes either object" do
      expect(described_class.new.instance_variable_get(:@sensitivity)).to equal(Lain::Sensitivity::Policy::Null.instance)
      expect(Lain::Middleware::Gate.new.instance_variable_get(:@sensitivity))
        .to equal(Lain::Sensitivity::Policy::Null.instance)
      expect(Lain::Sensitivity::Policy::Null.instance).to respond_to(:denial, :gates?)
    end

    it "defines no Null of its own for a gate to choke on" do
      expect(described_class.const_defined?(:Null, false)).to be(false)
    end
  end
end
