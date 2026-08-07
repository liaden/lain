# frozen_string_literal: true

RSpec.describe Lain::Effect::Handler::Gate do
  def tool(tool_name, gated: false, &body)
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { "the #{tool_name} tool" }
      define_method(:requires_approval?) { gated }
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }
      define_method(:perform, &body)
    end.new
  end

  let(:safe) { tool(:safe) { |input, _invocation| Lain::Tool::Result.ok(input.fetch(:text, "safe")) } }
  let(:dangerous) { tool(:dangerous, gated: true) { |input, _invocation| Lain::Tool::Result.ok(input.fetch(:text, "ran")) } }
  let(:toolset) { Lain::Toolset.new([safe, dangerous]) }
  let(:live) { Lain::Effect::Handler::Live.new(toolset:) }

  def tool_call(name, input = {}, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name:, input:)
  end

  describe "ungated tools" do
    it "falls straight through to inner without consulting the policy" do
      # A bare double with nothing stubbed: if Approving ever asked it
      # anything, this would raise "received unexpected message" and fail
      # the example -- which is the point.
      untouched_policy = instance_double(described_class::DenyAll)
      approving = described_class.new(policy: untouched_policy, inner: live)

      expect(approving.call(tool_call("safe"))).to eq(Lain::Tool::Result.ok("safe"))
    end
  end

  describe "a gated tool, denied" do
    it "returns an is_error Result rather than raising, and never reaches inner" do
      approving = described_class.new(policy: described_class::DenyAll.new, inner: live)

      result = approving.call(tool_call("dangerous"))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("denied")
    end
  end

  describe "a gated tool, approved" do
    it "delegates to inner and returns its Result" do
      approving = described_class.new(policy: described_class::ApproveAll.new, inner: live)

      expect(approving.call(tool_call("dangerous", { text: "went through" })))
        .to eq(Lain::Tool::Result.ok("went through"))
    end
  end

  describe "DenyAll is the default policy" do
    it "denies a gated call when no policy is given" do
      approving = described_class.new(inner: live)
      expect(approving.call(tool_call("dangerous"))).to have_attributes(is_error: true)
    end
  end

  describe "an explicit Effect::Approval wrapper" do
    it "is gated regardless of the wrapped tool's own tier" do
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe"))
      approving = described_class.new(policy: described_class::DenyAll.new, inner: live)

      expect(approving.call(wrapped)).to have_attributes(is_error: true, content: /denied/)
    end

    it "runs the inner effect once approved" do
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe", { text: "unwrapped" }))
      approving = described_class.new(policy: described_class::ApproveAll.new, inner: live)

      expect(approving.call(wrapped)).to eq(Lain::Tool::Result.ok("unwrapped"))
    end
  end

  describe "an unknown tool named in a bare ToolCall" do
    it "is not gated, and falls through to inner to report the usual unknown-tool error" do
      approving = described_class.new(policy: described_class::DenyAll.new, inner: live)

      result = approving.call(tool_call("ghost"))
      expect(result).to have_attributes(is_error: true, content: /no tool named/)
    end
  end

  describe "an approved effect with no inner handler" do
    it "raises UnhandledEffect rather than silently doing nothing" do
      # A wrapper is handled regardless of inner, so this reaches the approve
      # branch and then finds nothing to run -- which must fail loudly.
      approving = described_class.new(policy: described_class::ApproveAll.new)
      wrapped = Lain::Effect::Approval.new(effect: tool_call("dangerous"))
      expect { approving.call(wrapped) }.to raise_error(Lain::Effect::Handler::UnhandledEffect)
    end
  end

  describe "one map, by construction" do
    # The regression this guards: a gate holding its own Toolset could decide
    # tier against a different map than the executor dispatches from, running a
    # tier-3 call ungated. Approving holds no Toolset -- it reads the tier off
    # the tool inner will actually run -- so the two cannot diverge.
    it "reads tier from the inner handler's toolset, not a second reference" do
      approving = described_class.new(policy: described_class::DenyAll.new, inner: live)

      expect(approving.call(tool_call("dangerous"))).to have_attributes(is_error: true, content: /denied/)
      expect(approving.call(tool_call("safe"))).to eq(Lain::Tool::Result.ok("safe"))
    end

    it "does not accept a toolset of its own to diverge from" do
      expect { described_class.new(toolset: Lain::Toolset.new([safe]), inner: live) }
        .to raise_error(ArgumentError)
    end
  end

  # ---- T11: the path boundary, decided at the gate rather than in a tool -----
  #
  # The whole point of putting it HERE is that no tool changes: `read_file`
  # still declares itself tier 1, and what makes one call reach a human is the
  # PATH it names. Pre-read, and content is deliberately not judged here.
  describe "a sensitive path on an otherwise ungated tool" do
    let(:shipped) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::Bash.new]) }
    let(:live_shipped) { Lain::Effect::Handler::Live.new(toolset: shipped) }
    let(:sensitivity) do
      Lain::Sensitivity::Policy.new(
        sensitivity: Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project")
      )
    end

    def gate(policy: described_class::DenyAll.new, **over)
      described_class.new(policy:, inner: live_shipped, **over)
    end

    it "makes a gated path require approval, though the tool declares none" do
      effect = tool_call("read_file", { "path" => ".env" })

      expect(shipped.fetch("read_file").requires_approval?).to be(false)
      expect(gate(sensitivity:).handles?(effect)).to be(true)
    end

    # The policy is really consulted, not merely held: a denial must come back
    # as an is_error Result rather than the file's bytes.
    it "sends the gated path through the approval policy, and a denial withholds the read" do
      result = gate(sensitivity:).call(tool_call("read_file", { "path" => ".env" }))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("denied")
    end

    it "leaves an ordinary path to fall through to the inner handler untouched" do
      effect = tool_call("read_file", { "path" => "README.md" })

      expect(gate(sensitivity:).handles?(effect)).to be(false)
    end

    # `||`, not a replacement: the tier axis still decides on its own, so a
    # policy that gates nothing cannot ungate a tool that declares itself tier 3.
    it "keeps an already-gated tool gated, whatever the sensitivity policy says" do
      effect = tool_call("bash", { "command" => "ls", "cwd" => "README.md" })

      expect(gate(sensitivity:).handles?(effect)).to be(true)
      expect(gate(sensitivity: Lain::Sensitivity::Policy::Null.instance).handles?(effect)).to be(true)
    end

    # The unknown-tool contract is unchanged, and it must be: a name inner does
    # not hold falls through so Live reports it, rather than being gated on the
    # strength of a path in an input nothing will ever read.
    it "still declines a tool the inner handler does not hold, sensitive path or not" do
      effect = tool_call("ghost", { "path" => ".env" })

      expect(gate(sensitivity:).handles?(effect)).to be(false)
      expect(gate(sensitivity:).call(effect)).to have_attributes(is_error: true, content: /no tool named/)
    end
  end

  # The Null default, stated over the WHOLE shipped registry rather than one
  # sample: "byte-identically to today" is a claim about every tool, and the
  # partition below is what a policy that quietly gated everything would break.
  describe "the default sensitivity policy" do
    let(:shipped) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }
    let(:bare) do
      described_class.new(policy: described_class::DenyAll.new,
                          inner: Lain::Effect::Handler::Live.new(toolset: shipped))
    end

    it "is the Null policy, which gates nothing" do
      expect(bare.instance_variable_get(:@sensitivity)).to be(Lain::Sensitivity::Policy::Null.instance)
    end

    # `.env` in every path-ish field the tool declares, so a Null that gated
    # anything would land in this partition rather than passing unnoticed.
    it "gates exactly bash and core_exec when every shipped tool is offered" do
      gated = ToolRegistry.names.select do |name|
        bare.handles?(tool_call(name, { "path" => ".env", "cwd" => ".env" }))
      end

      expect(gated).to match_array(%w[bash core_exec])
    end
  end

  # The panel's probes, kept at the gate because the gate is where a user meets
  # this boundary. Two of them arrived asserting a defect and are inverted here
  # to guard the fix.
  describe "what the gate asks the classifier, and what hostile input does to it" do
    let(:home) { "/home/tester" }
    let(:classifier) { Lain::Sensitivity.new(home:, cwd: "/home/tester/project") }
    let(:policy) { Lain::Sensitivity::Policy.new(sensitivity: classifier) }
    let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::Bash.new, Lain::Tools::Glob.new]) }
    let(:sensitive_gate) do
      described_class.new(policy: described_class::DenyAll.new, sensitivity: policy,
                          inner: Lain::Effect::Handler::Live.new(toolset:))
    end

    def reads(path) = tool_call("read_file", { "path" => path })

    # The `!ordinary?` decision, stated first as the classifier's own API so the
    # trap is visible rather than described: three levels, and `gated?` is TRUE
    # for exactly one of them. A policy asking `gated?` would ungate the DENIED
    # class -- the most sensitive there is -- and would pass every other example
    # in this file.
    it "sees a denied path answer gated? == false, which is why the policy asks !ordinary?" do
      expect(classifier.classify("#{home}/.ssh/id_rsa"))
        .to have_attributes(denied?: true, gated?: false, ordinary?: false)
      expect(classifier.classify("#{home}/Downloads/x"))
        .to have_attributes(denied?: false, gated?: true, ordinary?: false)
      expect(classifier.classify("README.md")).to have_attributes(ordinary?: true)
    end

    it "gates a denied path at the gate, not only a gated one" do
      expect(sensitive_gate.handles?(reads("#{home}/.ssh/id_rsa"))).to be(true)
      expect(sensitive_gate.handles?(reads("#{home}/Downloads/x"))).to be(true)
      expect(sensitive_gate.handles?(reads("README.md"))).to be(false)
    end

    # Every shape below is one a provider payload really can carry, because the
    # gate runs BEFORE {Tool::Input} validation. A raise here fails a turn, and
    # the repair it invites -- a rescue answering false -- is this boundary
    # failing open, so "does not raise" is a security property and not tidiness.
    hostile = {
      "a nil path" => ["read_file", { "path" => nil }],
      "an empty-string path" => ["read_file", { "path" => "" }],
      "an Integer path" => ["read_file", { "path" => 42 }],
      "an Array path" => ["read_file", { "path" => [".env", "b"] }],
      "a Hash path" => ["read_file", { "path" => { "a" => 1 } }],
      "a wholly empty input" => ["read_file", {}],
      "a bash with no cwd" => ["bash", { "command" => "ls" }],
      "a bash with a nil cwd" => ["bash", { "command" => "ls", "cwd" => nil }],
      "a NUL byte in the path" => ["read_file", { "path" => "note\0.md" }],
      "a UTF-16 path" => ["read_file", { "path" => ".env".encode("UTF-16LE") }],
      "an invalid-encoding path" => ["read_file", { "path" => (+"\xff\xfe.env").force_encoding("UTF-8") }],
      "a tool the toolset does not hold" => ["ghost", { "path" => ".env" }],
      "a tool the TABLE does not hold" => ["todo_write", { "path" => ".env" }],
      "an absurdly deep path" => ["read_file", { "path" => "../" * 4096 }],
      # The two the panel found raising. `Effect::ToolCall` does not constrain
      # `input`, so an Array reached `Array#[]("path")` and a nil reached
      # `nil["path"]` -- both escaping `handles?`, where nothing raised before
      # this card.
      "a bare Array input" => ["read_file", [1, 2]],
      "a nil input" => ["read_file", nil],
      "a raw JSON String input" => ["read_file", '{"path":".env"}']
    }

    hostile.each do |label, (name, input)|
      it "does not raise on #{label}" do
        expect { sensitive_gate.handles?(tool_call(name, input)) }.not_to raise_error
      end
    end

    # Not merely "does not raise": unreadable bytes are hostile data, and this
    # boundary has to fail CLOSED on them.
    it "gates rather than waves through a path nothing can classify" do
      expect(sensitive_gate.handles?(reads("note\0.md"))).to be(true)
      expect(sensitive_gate.handles?(reads(".env".encode("UTF-16LE")))).to be(true)
    end

    # The fail-open the panel demonstrated end to end, inverted. {Tool::Input}
    # COERCES, so before the fix the gate declined a Pathname, ReadFile read the
    # file, and `TOKEN=shhh` came back with no approval asked -- while the same
    # path spelled as a String was refused. Driven through `call` and not
    # `handles?` because the leak was the RESULT, not the predicate.
    it "refuses a Pathname read, as it already refused the same path as a String" do
      dir = Dir.mktmpdir
      path = File.join(dir, ".env")
      File.write(path, "TOKEN=shhh")
      gate = described_class.new(
        policy: described_class::DenyAll.new,
        sensitivity: Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: dir)),
        inner: Lain::Effect::Handler::Live.new(toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new]))
      )

      expect(gate.handles?(reads(Pathname.new(path)))).to be(true)
      expect(gate.call(reads(Pathname.new(path)), Lain::Session.new).content).to include("approval denied")
      expect(gate.call(reads(path), Lain::Session.new).content).to include("approval denied")
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe "the policy receives the unwrapped effect and the context" do
    it "hands the policy the ToolCall itself, not the Approval wrapper" do
      seen = nil
      policy = lambda do |effect, _context|
        seen = effect
        true
      end
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe"))
      approving = described_class.new(policy:, inner: live)

      approving.call(wrapped, "some context")

      expect(seen).to be_a(Lain::Effect::ToolCall)
      expect(seen.name).to eq("safe")
    end
  end
end
