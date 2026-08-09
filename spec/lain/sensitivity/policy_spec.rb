# frozen_string_literal: true

require "tmpdir"

module SensitivityPolicySpecSupport
  # The table this spec drives from, written out rather than read off the
  # subject: an assertion that iterates `described_class::PATH_FIELDS` passes
  # whatever that table says, including an empty one.
  #
  # `ast_search`, `code_outline` and `file_symbols` are here because the panel
  # drove them against a real `.env` and got the secret's own bytes back --
  # `ast_search path=.env pattern="$A = $B"` returns the captured VALUES, which
  # is byte-for-byte what `read_file` returns and what this boundary exists to
  # gate. An earlier edition of this file allowlisted the three as deliberately
  # outside; that made a green suite state three known bypasses as intended.
  # There is no allowlist now, which is the point: EVERY shipped tool that takes
  # a path is in this table.
  DECLARED = { "read_file" => "path", "glob" => "path", "grep" => "path", "list_files" => "path",
               "edit_file" => "path", "write_file" => "path",
               "ast_search" => "path", "code_outline" => "path", "file_symbols" => "path",
               "bash" => "cwd", "core_exec" => "cwd" }.freeze

  # The field spellings a path can arrive under, asked of the tool's own
  # {Lain::Tool::Input} declaration rather than of the table under test.
  PATH_ISH = %w[path cwd].freeze

  def self.path_fields(name)
    model = ToolRegistry.build(name).input_model
    model ? model.fields.keys & PATH_ISH : []
  end

  def self.takes_a_path = ToolRegistry.names.reject { |name| path_fields(name).empty? }
end

RSpec.describe Lain::Sensitivity::Policy do
  subject(:policy) { described_class.new(sensitivity:) }

  let(:home) { "/home/tester" }
  let(:cwd) { "/home/tester/project" }
  let(:rules) { Lain::Sensitivity::Rules.empty }
  let(:sensitivity) { Lain::Sensitivity.new(home:, cwd:, rules:) }

  let(:declared) { SensitivityPolicySpecSupport::DECLARED }

  def call(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  describe "the tool-to-field table" do
    it "maps every path-taking tool to the field that names its path" do
      expect(described_class::PATH_FIELDS).to eq(declared)
    end

    # Drift guard, and the reason the table is data rather than a case: each
    # field must really be declared on that tool's own Tool::Input, so a
    # renamed field fails HERE rather than by silently gating nothing.
    it "names a field every one of those tools really declares" do
      declared.each do |name, field|
        fields = ToolRegistry.build(name).input_model.fields.keys
        expect(fields).to include(field), "#{name} declares no #{field} field"
      end
    end

    # A newly shipped tool that takes a path must fail by NAME here rather than
    # arriving ungated in silence -- {ToolRegistry}'s own pattern, one property
    # over. There is deliberately no allowlist to land in: the table and the
    # shipped set must be the SAME set, so the only way to satisfy this example
    # is to decide what the new tool's path means to the boundary.
    it "covers every shipped tool that takes a path, with nothing allowlisted out" do
      expect(SensitivityPolicySpecSupport.takes_a_path).to match_array(declared.keys)
    end
  end

  describe "#gates?" do
    it "gates a read_file naming .env" do
      expect(policy.gates?(call("read_file", { "path" => ".env" }))).to be(true)
    end

    it "leaves an ordinary path alone" do
      expect(policy.gates?(call("read_file", { "path" => "README.md" }))).to be(false)
    end

    # Every entry in the table, driven through its OWN field. `.env` is a
    # basename glob, so it gates wherever it sits and the same fixture serves
    # both axes.
    it "gates every tool in the table through the field that tool declares" do
      declared.each do |name, field|
        expect(policy.gates?(call(name, { field => ".env" }))).to be(true), "#{name}.#{field} was not gated"
      end
    end

    it "leaves every tool in the table alone for an ordinary value in the same field" do
      declared.each do |name, field|
        expect(policy.gates?(call(name, { field => "README.md" }))).to be(false), "#{name}.#{field} was gated"
      end
    end

    # The table is per TOOL, not "any field spelled path". A command tool's
    # `path` and a file tool's `cwd` are fields neither declares, so reading
    # them would be reading input the tool will never act on.
    it "reads only the field the table names for that tool" do
      expect(policy.gates?(call("bash", { "path" => ".env" }))).to be(false)
      expect(policy.gates?(call("read_file", { "cwd" => ".env" }))).to be(false)
    end

    it "declines a tool the table does not name at all" do
      expect(policy.gates?(call("todo_write", { "path" => ".env" }))).to be(false)
    end

    # `glob`'s path and `bash`'s cwd are both optional, so absence is the
    # common case rather than an error.
    it "declines when the field is absent" do
      expect(policy.gates?(call("glob", { "pattern" => "**/*.rb" }))).to be(false)
    end

    it "declines a field whose value is not a path at all" do
      expect(policy.gates?(call("read_file", { "path" => 42 }))).to be(false)
      expect(policy.gates?(call("read_file", { "path" => nil }))).to be(false)
    end

    # The fail-OPEN this class had, and the reason it was not a theoretical one:
    # {Tool::Input} COERCES rather than refuses, so a value the policy declined
    # to judge and the value the tool then acts on are different objects. A
    # Pathname is the case where that coercion lands on a REAL path -- the gate
    # saw a non-String and declined, ReadFile read the file, and the bytes came
    # back with no approval asked.
    #
    # {Sensitivity#classify} takes a String OR a Pathname, so the classifier was
    # never the limit; this class narrowed it. Same argument as the Symbol/String
    # key spellings above: whichever spelling is not read fails open.
    it "gates a Pathname exactly as it gates the same path spelled as a String" do
      expect(policy.gates?(call("read_file", { "path" => Pathname.new(".env") }))).to be(true)
      expect(policy.gates?(call("read_file", { "path" => Pathname.new("README.md") }))).to be(false)
    end

    # The benign half of the same miss, kept so the asymmetry is stated rather
    # than left to luck: an Array coerces to its own `inspect`, which names no
    # file, so declining it leaks nothing. Pathname was the one that bit because
    # `to_path` is the one coercion that yields a path somebody can open.
    it "still declines an Array, which coerces to a name no file has" do
      expect(policy.gates?(call("read_file", { "path" => [".env"] }))).to be(false)
      expect(Lain::Tools::ReadFile::Input.build({ "path" => [".env"] }).path).to eq('[".env"]')
    end

    # A parsed provider payload has String keys ({Approval::Escalation::Triage}
    # reads one); specs and in-process callers write Symbols. Reading only one
    # spelling fails OPEN on the other, which is the direction this boundary
    # must never fail in.
    it "reads the field under either key spelling" do
      expect(policy.gates?(call("read_file", { path: ".env" }))).to be(true)
      expect(policy.gates?(call("read_file", { "path" => ".env" }))).to be(true)
    end

    # Not ordinary, rather than `gated?`: a DENIED path answers false to
    # Verdict#gated?, so a policy asking that question would wave `~/.ssh/id_rsa`
    # straight through -- ungating the most sensitive class of path there is.
    # {Effect::Handler::Sensitivity} refuses a denial outright and is a
    # different card; until it lands this is all there is, and after it lands a
    # gate on a denied path costs at most one prompt for a file already refused.
    it "gates a denied path too, since a denial is not ordinary either" do
      expect(sensitivity.classify("~/.ssh/id_rsa")).to have_attributes(denied?: true, gated?: false)
      expect(policy.gates?(call("read_file", { "path" => "~/.ssh/id_rsa" }))).to be(true)
    end

    it "gates a path nothing can read lexically, rather than waving it through" do
      expect(policy.gates?(call("read_file", { "path" => "notes\0.md" }))).to be(true)
    end

    # The classifier is INJECTED and its home is injected in turn, so a
    # home-anchored rule has to arrive through both. A policy holding a table
    # of its own would answer this from the wrong home.
    it "gates a home-anchored path through the injected home, not the process's" do
      expect(policy.gates?(call("list_files", { "path" => "#{home}/Downloads" }))).to be(true)
      expect(policy.gates?(call("list_files", { "path" => "/home/someone-else/Downloads" }))).to be(false)
    end

    # Same argument, project config half: what a `[sensitivity]` table adds must
    # reach this boundary without the policy knowing the table exists.
    context "when the project's config widened the gated set" do
      let(:rules) { Lain::Sensitivity::Rules.from({ "gated" => ["*.private"] }) }

      it "gates what the project named" do
        expect(policy.gates?(call("read_file", { "path" => "notes.private" }))).to be(true)
      end
    end

    # {Effect::ToolCall} does not constrain `input`, and this policy runs on the
    # SYNCHRONOUS dispatch path BEFORE {Tool::Input} validation -- so whatever
    # the provider sent arrives here first. Indexing a non-Hash with a String is
    # `Array#[]("path")`, a TypeError, and `nil["path"]` is a NoMethodError:
    # both escape {Effect::Handler::Gate#gated_tool_call?}, where nothing raised
    # before this card, because the pre-T11 gate read only `effect.name`.
    #
    # A raise here fails the turn, and the repair somebody reaches for under
    # time pressure is a `rescue` answering false -- which is this boundary
    # failing OPEN. Declining a shape that carries no readable path is the same
    # answer without the trap.
    it "declines rather than raises when the input is not a Hash at all" do
      [[1, 2], nil, "raw", 42].each do |input|
        expect { policy.gates?(call("read_file", input)) }.not_to raise_error
        expect(policy.gates?(call("read_file", input))).to be(false)
      end
    end

    # The String case is worth its own line: `String#[]` is substring search, so
    # a raw JSON payload -- the streaming shape the Provider is meant to have
    # parsed already -- would have had a FRAGMENT of itself read as a path.
    # Harmless by luck (`"path"` classifies ordinary), and not a rule anybody
    # wrote, which is why the Hash check replaces it.
    it "does not read a raw JSON String input as though it held fields" do
      expect(policy.gates?(call("read_file", '{"path":".env"}'))).to be(false)
    end

    it "declines an effect that is not a tool call at all" do
      wrapped = Lain::Effect::Approval.new(effect: call("read_file", { "path" => ".env" }))

      expect(policy.gates?(wrapped)).to be(false)
      expect(policy.gates?(Lain::Effect::ModelCall.new(request: nil))).to be(false)
    end
  end

  # The three tools an earlier edition of this table left out, kept as the
  # regression guard the panel's probe became. The assertions are in PAIRS on
  # purpose: each drives the real tool against a real `.env` to show what it
  # would return ungated, then asserts the policy gates it. The first half is
  # what makes the second half worth having -- "ast_search is gated" alone
  # cannot tell a reader whether gating it protects anything.
  describe "the read-only AST tools, which read a file just as read_file does" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    attr_reader :tmpdir

    let(:cwd) { tmpdir }
    let(:invocation) { Lain::Tool::Invocation.new(tool_use_id: "tu", context: Lain::Session.new) }
    let(:secret) do
      path = File.join(tmpdir, ".env")
      File.write(path, %(AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI"\nSTRIPE_KEY = "sk_live_51H8xQ2"\n))
      path
    end

    # The most obvious pattern a model would reach for returns the captured
    # VALUES, not just the keys -- the same bytes read_file returns.
    it "gates ast_search, which otherwise hands back the secret's own bytes" do
      result = Lain::Tools::AstSearch.new.call({ "path" => secret, "language" => "ruby", "pattern" => "$A = $B" },
                                               invocation)

      expect(result.content).to include("wJalrXUtnFEMI", "sk_live_51H8xQ2")
      expect(policy.gates?(call("ast_search", { "path" => secret }))).to be(true)
    end

    # A smaller leak -- key names rather than values -- and still an enumeration
    # of what the file holds.
    it "gates file_symbols, which otherwise enumerates the secret's key names" do
      result = Lain::Tools::FileSymbols.new.call({ "path" => secret, "language" => "ruby" }, invocation)

      expect(result.content).to include("AWS_SECRET_ACCESS_KEY")
      expect(policy.gates?(call("file_symbols", { "path" => secret }))).to be(true)
    end

    # The mild one: its pattern catalog finds no ruby definitions in a KEY=value
    # file, so this fixture leaks nothing through it. It still OPENS the file,
    # and the argument for gating it is about what it MAY read rather than what
    # this fixture happens to produce -- which is why the leak assertion here is
    # about the read succeeding rather than about bytes.
    it "gates code_outline, which otherwise opens the file regardless of what it finds" do
      result = Lain::Tools::CodeOutline.new.call({ "path" => secret, "language" => "ruby" }, invocation)

      expect(result.is_error).to be(false)
      expect(policy.gates?(call("code_outline", { "path" => secret }))).to be(true)
    end

    it "leaves all three alone for an ordinary path, so the boundary is still the path" do
      ordinary = File.join(tmpdir, "notes.rb")

      %w[ast_search file_symbols code_outline].each do |name|
        expect(policy.gates?(call(name, { "path" => ordinary }))).to be(false), "#{name} was gated for notes.rb"
      end
    end
  end

  describe Lain::Sensitivity::Policy::Null do
    subject(:null) { described_class.instance }

    # The whole of what "an unwired chat behaves byte-identically to today"
    # means, said over the entire table rather than one sample: nothing in it
    # gates, including the paths the real policy above gates.
    it "gates nothing, for every tool the real table names" do
      declared.each do |name, field|
        expect(null.gates?(call(name, { field => ".env" }))).to be(false), "#{name} was gated by the Null policy"
        expect(null.gates?(call(name, { field => "~/.ssh/id_rsa" }))).to be(false)
      end
    end

    # Total over anything at all, because it ignores its argument -- which is
    # also why nothing was on fire before the Hash guard landed: production
    # wires this one, so the raise the real policy had could not be reached
    # until a classifier was wired. Pinned so the Null cannot quietly grow an
    # opinion about its input.
    it "answers without raising whatever the input is" do
      [nil, [1, 2], "raw", { "path" => ".env" }].each do |input|
        expect { null.gates?(call("read_file", input)) }.not_to raise_error
      end
    end

    # A shared frozen instance for {Middleware::RefuseSecretWrites::NullOracle}'s
    # reason: a fresh one per default would make two otherwise identical Seams
    # compare unequal.
    it "is one shared frozen instance" do
      expect(null).to be(described_class.instance)
      expect(null).to be_frozen
    end

    # It is the default of BOTH layers, so it has to answer both ducks -- a
    # Null only one of them accepts would contradict the premise that the gate
    # and the denial handler take the same injected object.
    it "answers both layers' ducks, which is what lets one object serve both" do
      expect(null).to respond_to(:gates?, :denial)
      expect(null.denial(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file",
                                                    input: { "path" => "/home/tester/.ssh/id_rsa" }))).to be_nil
    end
  end

  # T12's half of the same question, asked of the SAME object so the two axes
  # read one table. Covered here rather than only through the handler that
  # consults it: a method whose only test lives in a consumer is a method a
  # refactor can delete without anything noticing.
  describe "#denial" do
    let(:denied) { "#{home}/.ssh/id_ed25519" }

    it "answers a Denial naming the call, the tool, the path and the verdict" do
      denial = policy.denial(call("read_file", { "path" => denied }))

      expect(denial).to be_a(Lain::Sensitivity::Denial)
      expect(denial).to have_attributes(tool_use_id: "tu_1", tool: "read_file", path: denied, reason: :protected)
      expect(denial.verdict).to have_attributes(denied?: true, explanation: "a protected path")
    end

    it "answers nil for a GATED path, which is the gate's to decide and not this one's" do
      expect(policy.denial(call("read_file", { "path" => ".env" }))).to be_nil
      expect(policy.gates?(call("read_file", { "path" => ".env" }))).to be(true)
    end

    it "answers nil for an ordinary path, and for a tool the table does not name" do
      expect(policy.denial(call("read_file", { "path" => "README.md" }))).to be_nil
      expect(policy.denial(call("web_search", { "path" => denied }))).to be_nil
    end

    it "names the tool a WRITE refusal refused, so the Journal can tally by verb" do
      expect(policy.denial(call("write_file", { "path" => denied })).tool).to eq("write_file")
      expect(policy.denial(call("bash", { "cwd" => "#{home}/.gnupg" })).tool).to eq("bash")
    end

    # {#path_in} reads `effect.name`, which these have not got. A NoMethodError
    # on the dispatch path invites a `rescue` answering "not denied", which is
    # this boundary failing OPEN.
    it "answers nil rather than raising for an effect that names no tool" do
      expect(policy.denial(Lain::Effect::ModelCall.new(request: nil))).to be_nil
    end

    describe "an Approval wrapper" do
      def wrapped(effect) = Lain::Effect::Approval.new(effect:)

      # Without this, wrapping LIFTS a denial: the handler sits ahead of the
      # Gate, so it sees the wrapper, declines, and the Gate then unwraps and
      # approves. The unwrap belongs here because this class already owns
      # "which effects name paths".
      it "is looked through, so wrapping cannot lift a denial" do
        expect(policy.denial(wrapped(call("read_file", { "path" => denied })))).not_to be_nil
      end

      it "is looked through however many times it is applied" do
        deep = (1..6).inject(call("read_file", { "path" => denied })) { |effect, _| wrapped(effect) }

        expect(policy.denial(deep)).to have_attributes(path: denied, tool_use_id: "tu_1")
      end

      # The asymmetry, pinned so it is not "tidied" away: Gate unwraps BEFORE
      # it consults `gates?`, so teaching `gates?` to unwrap would change when
      # the gate fires.
      it "is deliberately NOT looked through by #gates?" do
        expect(policy.gates?(wrapped(call("read_file", { "path" => ".env" })))).to be(false)
      end

      it "does not promote a wrapped gated path into a denial" do
        expect(policy.denial(wrapped(call("read_file", { "path" => ".env" })))).to be_nil
      end
    end
  end

  describe "construction" do
    it "requires a classifier rather than reaching for one" do
      expect { described_class.new }.to raise_error(ArgumentError)
    end

    it "is frozen, so it can be shared by a parent gate and its children's" do
      expect(policy).to be_frozen
    end
  end

  # T23. The listing filter is this object's SECOND answer over the SAME
  # classifier, rather than something a caller builds beside it. That is what
  # makes "the gate refused a path the listing enumerated" unrepresentable: the
  # classifier is exposed nowhere, so there is no second filter to construct
  # from a different one.
  describe "#filter" do
    def sift(subject_filter, path) = subject_filter.sift([path]) { |row| [row] }

    it "answers a real filter over this policy's own classifier" do
      expect(policy.filter).to be_a(Lain::Sensitivity::Filter)
    end

    # Identity, not equality: two filters built from one classifier would still
    # agree, so only sameness says the wiring reached THIS policy's filter.
    it "is the same filter every time, so a caller cannot hold a stale one" do
      expect(policy.filter).to equal(policy.filter)
    end

    # Built at construction rather than memoized on first read, because this
    # object freezes itself -- a lazy `@filter ||=` raises FrozenError the
    # first time anybody asks, which is a trap worth not laying.
    it "is already built by the time the policy is frozen" do
      expect(policy.filter).to be_frozen
    end

    # The property the whole shape exists for, stated as behaviour: what the
    # gate gates is what the filter withholds, because there is one classifier.
    it "withholds exactly what the gate gates" do
      gated = "#{cwd}/.env"

      expect(policy.gates?(call("read_file", { "path" => gated }))).to be(true)
      expect(sift(policy.filter, gated).withheld.map(&:reason)).to eq([:credential])
    end

    it "keeps a row the gate would let through" do
      ordinary = "#{cwd}/README.md"

      expect(policy.gates?(call("read_file", { "path" => ordinary }))).to be(false)
      expect(sift(policy.filter, ordinary).kept).to eq([ordinary])
    end

    it "carries this project's own rules into the filter, not just the built-ins" do
      declared = Lain::Sensitivity::Rules.from({ "denied" => ["*.secret"] })
      configured = described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd:, rules: declared))

      expect(sift(configured.filter, "#{cwd}/prod.secret").withheld.map(&:reason)).to eq([:configured])
    end
  end

  # The Null's own second answer, and it needs no new object: a policy that
  # gates nothing withholds nothing, and {Filter::Null} already means exactly
  # that.
  describe "Null#filter" do
    it "is the Null filter, so a run that wired no classifier lists as it always did" do
      expect(described_class::Null.instance.filter).to be(Lain::Sensitivity::Filter::Null.instance)
    end

    it "withholds nothing" do
      sifted = described_class::Null.instance.filter.sift(["/home/tester/.ssh/id_rsa"]) { |row| [row] }

      expect([sifted.kept, sifted.withheld]).to eq([["/home/tester/.ssh/id_rsa"], []])
    end
  end
end
