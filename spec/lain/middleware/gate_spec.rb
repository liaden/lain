# frozen_string_literal: true

# A policy that records every call it was asked about and answers a fixed
# verdict. Being ASKED is what "gated" means, so the examples read that off
# the record rather than inferring it from a refusal's wording.
# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module MiddlewareGateSpecSupport
  class SpyPolicy
    attr_reader :asked, :contexts

    def initialize(verdict:)
      @verdict = verdict
      @asked = []
      @contexts = []
    end

    def call(effect, context)
      @asked << effect
      @contexts << context
      @verdict
    end
  end
end

RSpec.describe Lain::Middleware::Gate do
  def tool(tool_name, gated: false)
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { "the #{tool_name} tool" }
      define_method(:requires_approval?) { gated }
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }
      def perform(_input, _invocation) = Lain::Tool::Result.ok("ran")
    end.new
  end

  let(:safe) { tool(:safe) }
  let(:dangerous) { tool(:dangerous, gated: true) }
  let(:toolset) { Lain::Toolset.new([safe, dangerous]) }

  def tool_call(name, input = {}, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name:, input:)
  end

  def spy(verdict: false) = MiddlewareGateSpecSupport::SpyPolicy.new(verdict:)

  # The tool the env carries is resolved ONCE, upstream, by the runner; here it
  # is handed in, so an unheld name is the runner's stand-in and nothing else.
  def held(name, set = toolset) = set.include?(name) ? set.fetch(name) : Lain::Toolset::Unheld.new(name)

  # One pass through the gate over a downstream that records what reached it.
  # Answers the result and the effects that got past.
  def through(gate, effect, tool: held(effect.approval? ? effect.effect.name : effect.name), context: nil)
    reached = []
    env = gate.call({ effect:, tool:, context: }) do |inner|
      reached << inner.fetch(:effect)
      inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
    end
    [env.fetch(:result), reached]
  end

  describe "ungated tools" do
    it "passes straight downstream without consulting the policy" do
      policy = spy

      result, reached = through(described_class.new(policy:), tool_call("safe"))

      expect(result).to eq(Lain::Tool::Result.ok("downstream ran"))
      expect(reached).to eq([tool_call("safe")])
      expect(policy.asked).to be_empty
    end
  end

  describe "a gated tool, denied" do
    it "answers an is_error Result rather than raising, and nothing reaches downstream" do
      result, reached = through(described_class.new(policy: described_class::DenyAll.new), tool_call("dangerous"))

      expect(result).to have_attributes(is_error: true, content: 'approval denied for tool "dangerous"')
      expect(reached).to be_empty
    end
  end

  describe "a gated tool, approved" do
    it "passes downstream and its result comes back" do
      result, reached = through(described_class.new(policy: described_class::ApproveAll.new), tool_call("dangerous"))

      expect(result).to eq(Lain::Tool::Result.ok("downstream ran"))
      expect(reached).to eq([tool_call("dangerous")])
    end
  end

  describe "DenyAll is the default policy" do
    it "denies a gated call when no policy is given" do
      expect(through(described_class.new, tool_call("dangerous")).first).to have_attributes(is_error: true)
    end
  end

  describe "the sentence a refusal is reported as" do
    it "is the injected one, with the tool's name in it" do
      gate = described_class.new(denial: "nobody can approve %<name>s")

      expect(through(gate, tool_call("dangerous")).first.content).to eq('nobody can approve "dangerous"')
    end
  end

  describe "an explicit Effect::Approval wrapper" do
    it "is gated regardless of the wrapped tool's own tier" do
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe"))

      expect(through(described_class.new(policy: described_class::DenyAll.new), wrapped).first)
        .to have_attributes(is_error: true, content: /denied/)
    end

    it "sends the call it wraps downstream once approved" do
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe", { text: "unwrapped" }))

      _, reached = through(described_class.new(policy: described_class::ApproveAll.new), wrapped)

      expect(reached).to eq([tool_call("safe", { text: "unwrapped" })])
    end
  end

  describe "a name the toolset does not hold" do
    it "is not gated, and passes downstream for the interpreter to refuse by name" do
      policy = spy

      _, reached = through(described_class.new(policy:), tool_call("ghost"))

      expect(policy.asked).to be_empty
      expect(reached).to eq([tool_call("ghost")])
    end
  end

  describe "one tool, by construction" do
    # The regression this guards: a gate holding its own Toolset could decide
    # tier against a different map than the interpreter runs from, running a
    # tier-3 call ungated. The gate reads the tier off the tool the env
    # carries -- the very object the interpreter will run.
    it "reads the tier off the tool it is handed, not off the name" do
      policy = spy

      through(described_class.new(policy:), tool_call("safe"), tool: dangerous)

      expect(policy.asked).to eq([tool_call("safe")])
    end

    it "does not accept a toolset of its own to diverge from" do
      expect { described_class.new(toolset: Lain::Toolset.new([safe])) }.to raise_error(ArgumentError)
    end
  end

  # ---- the path boundary, decided at the gate rather than in a tool ----------
  #
  # The whole point of putting it HERE is that no tool changes: `read_file`
  # still declares itself tier 1, and what makes one call reach a human is the
  # PATH it names. Pre-read, and content is deliberately not judged here.
  describe "a sensitive path on an otherwise ungated tool" do
    let(:shipped) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::Bash.new]) }
    let(:sensitivity) do
      Lain::Sensitivity::Policy.new(
        sensitivity: Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project")
      )
    end

    def asks?(effect, sensitivity:)
      policy = spy
      through(described_class.new(policy:, sensitivity:), effect, tool: held(effect.name, shipped))
      policy.asked.any?
    end

    it "makes a gated path require approval, though the tool declares none" do
      expect(shipped.fetch("read_file").requires_approval?).to be(false)
      expect(asks?(tool_call("read_file", { "path" => ".env" }), sensitivity:)).to be(true)
    end

    # The policy is really consulted, not merely held: a denial must come back
    # as an is_error Result rather than reaching the reader.
    it "sends the gated path through the approval policy, and a denial withholds the read" do
      gate = described_class.new(policy: described_class::DenyAll.new, sensitivity:)

      result, reached = through(gate, tool_call("read_file", { "path" => ".env" }), tool: shipped.fetch("read_file"))

      expect(result).to have_attributes(is_error: true, content: /denied/)
      expect(reached).to be_empty
    end

    it "leaves an ordinary path to pass downstream untouched" do
      expect(asks?(tool_call("read_file", { "path" => "README.md" }), sensitivity:)).to be(false)
    end

    # `||`, not a replacement: the tier axis still decides on its own, so a
    # policy that gates nothing cannot ungate a tool that declares itself tier 3.
    it "keeps an already-gated tool gated, whatever the sensitivity policy says" do
      effect = tool_call("bash", { "command" => "ls", "cwd" => "README.md" })

      expect(asks?(effect, sensitivity:)).to be(true)
      expect(asks?(effect, sensitivity: Lain::Sensitivity::Policy::Null.instance)).to be(true)
    end

    # A name the toolset does not hold passes so the interpreter reports it,
    # rather than being gated on the strength of a path in an input nothing
    # will ever read. `read_file` IS in the path table, which is the case that
    # makes the difference.
    it "does not ask about a tool the toolset does not hold, sensitive path or not" do
      bare = Lain::Toolset.new([Lain::Tools::Bash.new])
      effect = tool_call("read_file", { "path" => ".env" })
      policy = spy

      through(described_class.new(policy:, sensitivity:), effect, tool: held("read_file", bare))

      expect(policy.asked).to be_empty
    end
  end

  # The Null default, stated over the WHOLE shipped registry rather than one
  # sample: "byte-identically to today" is a claim about every tool, and the
  # partition below is what a policy that quietly gated everything would break.
  describe "the default sensitivity policy" do
    let(:shipped) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

    it "is the Null policy, which gates nothing" do
      expect(described_class.new.instance_variable_get(:@sensitivity)).to be(Lain::Sensitivity::Policy::Null.instance)
    end

    # `.env` in every path-ish field the tool declares, so a Null that gated
    # anything would land in this partition rather than passing unnoticed.
    it "gates exactly bash when every shipped tool is offered" do
      gated = ToolRegistry.names.select do |name|
        policy = spy
        through(described_class.new(policy:), tool_call(name, { "path" => ".env", "cwd" => ".env" }),
                tool: shipped.fetch(name))
        policy.asked.any?
      end

      expect(gated).to match_array(%w[bash])
    end
  end

  # The panel's probes, kept at the gate because the gate is where a user meets
  # this boundary. Two of them arrived asserting a defect and are inverted here
  # to guard the fix.
  describe "what the gate asks the classifier, and what hostile input does to it" do
    let(:home) { "/home/tester" }
    let(:classifier) { Lain::Sensitivity.new(home:, cwd: "/home/tester/project") }
    let(:path_policy) { Lain::Sensitivity::Policy.new(sensitivity: classifier) }
    let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::Bash.new, Lain::Tools::Glob.new]) }

    def reads(path) = tool_call("read_file", { "path" => path })

    def asks?(effect)
      policy = spy
      through(described_class.new(policy:, sensitivity: path_policy), effect)
      policy.asked.any?
    end

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
      expect(asks?(reads("#{home}/.ssh/id_rsa"))).to be(true)
      expect(asks?(reads("#{home}/Downloads/x"))).to be(true)
      expect(asks?(reads("README.md"))).to be(false)
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
      # `Effect::ToolCall` does not constrain `input`, so an Array once reached
      # `Array#[]("path")` and a nil reached `nil["path"]`.
      "a bare Array input" => ["read_file", [1, 2]],
      "a nil input" => ["read_file", nil],
      "a raw JSON String input" => ["read_file", '{"path":".env"}']
    }

    hostile.each do |label, (name, input)|
      it "does not raise on #{label}" do
        expect { asks?(tool_call(name, input)) }.not_to raise_error
      end
    end

    # Not merely "does not raise": unreadable bytes are hostile data, and this
    # boundary has to fail CLOSED on them.
    it "gates rather than waves through a path nothing can classify" do
      expect(asks?(reads("note\0.md"))).to be(true)
      expect(asks?(reads(".env".encode("UTF-16LE")))).to be(true)
    end

    # The fail-open the panel demonstrated end to end, inverted. {Tool::Input}
    # COERCES, so a gate that declined a Pathname let ReadFile read the file,
    # and `TOKEN=shhh` came back with no approval asked -- while the same path
    # spelled as a String was refused. Driven through the real runner because
    # the leak was the RESULT, not the predicate.
    it "refuses a Pathname read, as it already refused the same path as a String", :seam do
      dir = Dir.mktmpdir
      path = File.join(dir, ".env")
      File.write(path, "TOKEN=shhh")
      gate = described_class.new(
        policy: described_class::DenyAll.new,
        sensitivity: Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: dir))
      )
      readers = Lain::Toolset.new([Lain::Tools::ReadFile.new])

      expect(asks?(reads(Pathname.new(path)))).to be(true)
      expect(through(gate, reads(Pathname.new(path)), tool: readers.fetch("read_file")).first.content)
        .to include("approval denied")
      expect(dispatch_call("read_file", { "path" => path }, toolset: readers, layers: [gate],
                                                            context: Lain::Session.new).content)
        .to include("approval denied")
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe "what the policy receives" do
    it "is the ToolCall itself, not the Approval wrapper, and the env's context" do
      policy = spy(verdict: true)

      through(described_class.new(policy:), Lain::Effect::Approval.new(effect: tool_call("safe")),
              context: "some context")

      expect(policy.asked).to eq([tool_call("safe")])
      expect(policy.contexts).to eq(["some context"])
    end
  end
end
