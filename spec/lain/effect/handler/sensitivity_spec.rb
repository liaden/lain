# frozen_string_literal: true

RSpec.describe Lain::Effect::Handler::Sensitivity do
  # The session's ONE path policy, real: the same object the Gate one step in
  # consults for its own axis, so every example below drives the real
  # extraction, the real tool->field table and the real classifier rather than
  # a fake agreeing with itself.
  def denying(classifier) = Lain::Sensitivity::Policy.new(sensitivity: classifier)

  # Counts what got past the refusal. A double would answer `handles?` and
  # `call` with stubs; this answers them the way a handler does, and records.
  def recording_inner
    Class.new(Lain::Effect::Handler) do
      def seen = (@seen ||= [])
      def handles?(_effect) = true

      protected

      def perform(effect, _context)
        seen << effect
        Lain::Tool::Result.ok("inner ran")
      end
    end.new
  end

  def reads(path, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name: "read_file", input: { "path" => path })
  end

  def board(sensitivity)
    Lain::CLI::Switchboard.new(journal: Lain::Journal.new(io: StringIO.new), yolo: false, model: "m",
                               sensitivity:, toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new]))
  end

  let(:home) { "/home/tester" }
  let(:project) { "#{home}/project" }
  let(:classifier) { Lain::Sensitivity.new(home:, cwd: project) }
  let(:journal) { [] }
  let(:policy) { denying(classifier) }
  # A real executor over the real shipped tools, so "no file is read" and "the
  # effect reaches the gate" are claims about the chain rather than about a
  # double's expectations.
  let(:shipped) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::Bash.new]) }
  let(:live) { Lain::Effect::Handler::Live.new(toolset: shipped) }

  describe "a denied path" do
    let(:inner) { recording_inner }
    let(:handler) { described_class.new(sensitivity: policy, journal:, inner:) }

    it "refuses it, naming the path as a protected path" do
      result = handler.call(reads("#{home}/.ssh/id_ed25519"))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("refused", "#{home}/.ssh/id_ed25519", "protected path")
    end

    it "never lets the effect reach the inner handler" do
      handler.call(reads("#{home}/.ssh/id_ed25519"))

      expect(inner.seen).to be_empty
    end

    # The tell that the refusal is decided BEFORE the tool runs: the file is
    # real, holds real key bytes, and none of them appear in the answer.
    it "names the path and none of the file's bytes", :seam do
      dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(dir, ".ssh"))
      path = File.join(dir, ".ssh", "id_ed25519")
      File.write(path, "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEQ\n")
      refusing = described_class.new(sensitivity: denying(Lain::Sensitivity.new(home:, cwd: dir)),
                                     journal:, inner: live)

      result = refusing.call(reads(path), Lain::Session.new)

      expect(result.content).to include(path)
      expect(result.content).not_to include("PRIVATE KEY", "b3BlbnNzaC1rZXktdjEQ")
    ensure
      FileUtils.remove_entry(dir)
    end

    # Loud is the point: a refusal that only says "no" gets resent verbatim,
    # so the message has to say the boundary cannot be moved.
    it "tells the model no approval can lift it, so it stops retrying variants" do
      expect(handler.call(reads("#{home}/.ssh/id_ed25519")).content).to include("no approval can lift")
    end

    it "reports the refusal rather than raising, so the loop keeps running" do
      expect { handler.call(reads("#{home}/.ssh/id_ed25519")) }.not_to raise_error
    end
  end

  describe "the journal" do
    let(:handler) { described_class.new(sensitivity: policy, journal:, inner: recording_inner) }

    it "records exactly one ReadRefused, naming the path and the reason" do
      handler.call(reads("#{home}/.ssh/id_ed25519", id: "tu_7"))

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
      configured = denying(Lain::Sensitivity.new(home:, cwd: project, rules:))
      handler = described_class.new(sensitivity: configured, journal:, inner: recording_inner)

      result = handler.call(reads("#{project}/prod.secret"))

      expect(journal.first).to have_attributes(reason: "configured")
      expect(result.content).to include("named by this project's sensitivity config")
    end

    it "writes nothing at all for a path it does not refuse" do
      handler.call(reads("README.md"))

      expect(journal).to be_empty
    end

    # Channel::Null is the default so a chain that wired no journal refuses
    # exactly as loudly and no caller writes `if journal`.
    it "refuses with no journal wired" do
      bare = described_class.new(sensitivity: policy, inner: recording_inner)

      expect(bare.call(reads("#{home}/.ssh/id_ed25519"))).to have_attributes(is_error: true)
    end
  end

  describe "what it declines" do
    let(:inner) { recording_inner }
    let(:handler) { described_class.new(sensitivity: policy, journal:, inner:) }

    it "declines an ordinary path and lets the inner handler run it" do
      effect = reads("README.md")

      expect(handler.handles?(effect)).to be(false)
      expect(handler.call(effect)).to eq(Lain::Tool::Result.ok("inner ran"))
      expect(inner.seen).to eq([effect])
    end

    # A GATED path is approvable, so it is not this handler's business: it
    # belongs to the Gate, one step in. Refusing it here would take away the
    # human's move.
    it "declines a gated path, so the effect reaches the gate" do
      effect = reads(".env")

      expect(classifier.classify("#{project}/.env")).to have_attributes(gated?: true, denied?: false)
      expect(handler.handles?(effect)).to be(false)
    end

    it "declines a tool the path table does not name" do
      expect(handler.handles?(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "web_search",
                                                         input: { "path" => "#{home}/.ssh/id_rsa" }))).to be(false)
    end

    # The dispatch path is synchronous and runs before Tool::Input validation,
    # so a shape carrying no readable field must be DECLINED rather than
    # raising -- the repair a raise here invites is a `rescue` answering
    # "not denied", which is this boundary failing open.
    it "declines shapes that name no path, rather than raising on them" do
      %w[read_file bash].product([[], "just a string", nil, { "path" => 42 }]).each do |name, input|
        effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)
        expect { handler.handles?(effect) }.not_to raise_error
        expect(handler.handles?(effect)).to be(false)
      end
    end

    it "declines a ModelCall, which names no path at all" do
      expect(handler.handles?(Lain::Effect::ModelCall.new(request: nil))).to be(false)
    end
  end

  # The table is `Sensitivity::Policy`'s, and this handler holds none of its
  # own: `bash` names its directory in `cwd`, not `path`, and a second table
  # here would be the drift this whole boundary exists to prevent.
  describe "the tool->field table is the shared one" do
    let(:handler) { described_class.new(sensitivity: policy, journal:, inner: recording_inner) }

    it "refuses a bash call whose cwd is denied" do
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                          input: { "cwd" => "#{home}/.gnupg" })

      expect(handler.call(effect)).to have_attributes(is_error: true)
    end

    # A WRITE to a denied path is refused too, and must be: the table names
    # `write_file` and `edit_file` beside the readers, and writing to
    # `~/.ssh/id_ed25519` is not the lesser act. What the earlier edition got
    # wrong was the WORDING and the record, not the refusal.
    it "refuses a write to a denied path, not only a read" do
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "write_file",
                                          input: { "path" => "#{home}/.ssh/id_ed25519", "content" => "x" })

      expect(handler.call(effect)).to have_attributes(is_error: true)
    end

    it "gives a refused writer advice that names no verb" do
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "edit_file",
                                          input: { "path" => "#{home}/.ssh/id_ed25519" })

      expect(handler.call(effect).content).to include("name a different path")
      expect(handler.call(effect).content).not_to include("read something else")
    end

    it "journals the refused tool, so a write is not tallied as a read" do
      handler.call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "write_file",
                                              input: { "path" => "#{home}/.ssh/id_ed25519" }))
      handler.call(Lain::Effect::ToolCall.new(tool_use_id: "tu_2", name: "bash",
                                              input: { "cwd" => "#{home}/.gnupg" }))

      expect(journal.map(&:tool)).to eq(%w[write_file bash])
    end

    it "refuses an ast_search on a denied path, which returns the same bytes read_file would" do
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "ast_search",
                                          input: { "path" => "#{home}/.ssh/id_rsa" })

      expect(handler.call(effect)).to have_attributes(is_error: true)
    end

    # {Tool::Input} COERCES rather than refuses, so a Pathname declined here
    # would be read anyway -- the fail-open T11's panel demonstrated end to end.
    it "refuses a Pathname spelling of a denied path" do
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file",
                                          input: { "path" => Pathname.new("#{home}/.ssh/id_rsa") })

      expect(handler.call(effect)).to have_attributes(is_error: true)
    end

    it "reads the field under either key spelling" do
      symbolic = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file",
                                            input: { path: "#{home}/.ssh/id_rsa" })

      expect(handler.handles?(symbolic)).to be(true)
    end
  end

  # Sitting ahead of the Gate means this handler sees the {Effect::Approval}
  # wrapper the Gate would otherwise unwrap first. Left alone, wrapping a
  # denied read would have LIFTED the denial: not a tool_call?, so declined
  # here, unwrapped by the Gate, approved. The unwrap lives in
  # {Sensitivity::Policy#denial} -- the object both axes already consult --
  # rather than being a second copy of the Gate's contract in this class.
  describe "an Approval wrapper" do
    let(:inner) { recording_inner }
    let(:handler) { described_class.new(sensitivity: policy, journal:, inner:) }

    def wrapped(effect) = Lain::Effect::Approval.new(effect:)

    it "does not lift a denial by wrapping it" do
      result = handler.call(wrapped(reads("#{home}/.ssh/id_ed25519")))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("protected path")
      expect(inner.seen).to be_empty
    end

    it "does not lift one by wrapping it twice either" do
      expect(handler.handles?(wrapped(wrapped(reads("#{home}/.ssh/id_ed25519"))))).to be(true)
    end

    it "journals the wrapped refusal against the inner call's tool_use_id" do
      handler.call(wrapped(reads("#{home}/.ssh/id_ed25519", id: "tu_9")))

      expect(journal.size).to eq(1)
      expect(journal.first).to have_attributes(tool_use_id: "tu_9", path: "#{home}/.ssh/id_ed25519")
    end

    # Wrapping does not PROMOTE a gated path either -- it stays the Gate's,
    # which is the whole point of the wrapper.
    it "leaves a wrapped gated path to the gate" do
      expect(handler.handles?(wrapped(reads(".env")))).to be(false)
    end

    # The asymmetry, asserted so nobody "tidies" it away: `gates?` must NOT
    # unwrap, because the Gate unwraps before consulting it (gate.rb:73), and
    # teaching it to would change WHEN the gate fires. `denial` must, because
    # this handler runs before that unwrap ever happens.
    it "is unwrapped by #denial and deliberately not by #gates?" do
      effect = wrapped(reads("#{home}/.ssh/id_ed25519"))

      expect(policy.denial(effect)).to have_attributes(path: "#{home}/.ssh/id_ed25519")
      expect(policy.gates?(effect)).to be(false)
    end
  end

  # `handles?` and `perform` each ask, and the two questions can straddle a
  # board change: {CLI::Wiring::ToolsetBuild::LiveSensitivity} -- what BOTH
  # production chains are wired with -- re-reads `board.call` on every call,
  # which is the property T11's own spec asserts by moving the board slot
  # between two calls. So "the second answer equals the first" holds for a
  # fixed Policy and not for the delegator, and a flip to nil must not become
  # a NoMethodError on the synchronous dispatch path.
  describe "when the policy's answer changes between handles? and perform" do
    # Denies once, then denies nothing -- a board that lost its policy between
    # the two questions, in the smallest shape that reproduces it.
    def flipping(first)
      Class.new do
        def initialize(first) = (@answers = [first, nil])
        def denial(_effect) = @answers.shift
      end.new(first)
    end

    it "declines to the inner handler rather than crashing on a vanished denial" do
      inner = recording_inner
      effect = reads("#{home}/.ssh/id_ed25519")
      handler = described_class.new(sensitivity: flipping(policy.denial(effect)), journal:, inner:)

      expect { handler.call(effect) }.not_to raise_error
      expect(handler.call(effect)).to eq(Lain::Tool::Result.ok("inner ran"))
      expect(journal).to be_empty
    end

    it "still raises UnhandledEffect when it declines with no inner handler" do
      effect = reads("#{home}/.ssh/id_ed25519")
      handler = described_class.new(sensitivity: flipping(policy.denial(effect)), journal:)

      expect { handler.call(effect) }.to raise_error(Lain::Effect::Handler::UnhandledEffect)
    end

    # The window is not hypothetical: this is T11's own liveness property,
    # driven through the delegator both production chains hold.
    it "is reachable through LiveSensitivity, whose board really can move" do
      slot = [board(policy)]
      live = Lain::CLI::Wiring::ToolsetBuild::LiveSensitivity.new(board: -> { slot.first })
      effect = reads("#{home}/.ssh/id_ed25519")

      expect(live.denial(effect)).not_to be_nil

      slot[0] = board(Lain::Sensitivity::Policy::Null.instance)

      expect(live.denial(effect)).to be_nil
    end
  end

  # The whole reason this is a handler AHEAD of the gate rather than a gate
  # policy answer: a Gate policy is boolean and every boolean is approvable.
  describe "ahead of the gate" do
    let(:gate) { Lain::Effect::Handler::Gate.new(policy: Lain::Effect::Handler::Gate::ApproveAll.new, inner: live) }
    let(:chain) { described_class.new(sensitivity: policy, journal:, inner: gate) }

    it "still refuses a denied path under ApproveAll" do
      result = chain.call(reads("#{home}/.ssh/id_ed25519"), Lain::Session.new)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("protected path")
    end

    # The complement, and the one that proves the chain is really composed:
    # the same ApproveAll that cannot lift a denial DOES lift a gated path.
    it "lets ApproveAll approve a gated path, which is what makes a denial different", :seam do
      dir = Dir.mktmpdir
      File.write(File.join(dir, ".env"), "TOKEN=shhh")
      approving = described_class.new(
        sensitivity: denying(Lain::Sensitivity.new(home:, cwd: dir)),
        journal:, inner: Lain::Effect::Handler::Gate.new(
          policy: Lain::Effect::Handler::Gate::ApproveAll.new, inner: live,
          sensitivity: Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: dir))
        )
      )

      expect(approving.call(reads(File.join(dir, ".env")), Lain::Session.new).content).to include("TOKEN=shhh")
    ensure
      FileUtils.remove_entry(dir)
    end

    it "hands a declined effect to the gate, which then applies its own policy", :seam do
      denying = described_class.new(
        sensitivity: policy, journal:,
        inner: Lain::Effect::Handler::Gate.new(policy: Lain::Effect::Handler::Gate::DenyAll.new, inner: live,
                                               sensitivity: Lain::Sensitivity::Policy.new(sensitivity: classifier))
      )

      expect(denying.call(reads(".env"), Lain::Session.new).content).to include("approval denied")
      expect(journal).to be_empty
    end
  end

  # ONE Null for the role, not two. A Null answering only `denial` would be an
  # object this layer accepts and the Gate rejects (NoMethodError: gates?),
  # which contradicts the premise that both layers take the same object.
  describe "the default policy" do
    it "denies nothing, so a chain that wired no policy behaves as it did before this boundary" do
      inner = recording_inner
      effect = reads("#{home}/.ssh/id_ed25519")

      expect(described_class.new(inner:).call(effect)).to eq(Lain::Tool::Result.ok("inner ran"))
      expect(inner.seen).to eq([effect])
    end

    it "is the same shared Null the Gate defaults to, so either layer takes either object" do
      handler = described_class.new(inner: recording_inner)

      expect(handler.instance_variable_get(:@sensitivity)).to equal(Lain::Sensitivity::Policy::Null.instance)
      expect(Lain::Sensitivity::Policy::Null.instance).to respond_to(:denial, :gates?)
    end

    it "defines no Null of its own for a Gate to choke on" do
      expect(described_class.const_defined?(:Null, false)).to be(false)
    end

    # The substitutability that matters, driven rather than asserted: the very
    # object this handler defaults to goes into a Gate and answers its duck.
    it "hands its own default to a Gate, which accepts it" do
      gate = Lain::Effect::Handler::Gate.new(sensitivity: Lain::Sensitivity::Policy::Null.instance, inner: live)

      expect(gate.handles?(reads(".env"))).to be(false)
    end
  end

  describe "an effect it declines with no inner handler" do
    it "raises UnhandledEffect, the base class's contract, rather than dropping it" do
      expect { described_class.new(sensitivity: policy).call(reads("README.md")) }
        .to raise_error(Lain::Effect::Handler::UnhandledEffect)
    end
  end
end
