# frozen_string_literal: true

require "tmpdir"

module SensitivityPolicySpecSupport
  # The table this spec drives from, written out rather than read off the
  # subject: an assertion that iterates `described_class::PATH_FIELDS` passes
  # whatever that table says, including an empty one.
  #
  # `ast_search` and `file_symbols` are here because the panel drove them
  # against a real `.env` and got the secret's own bytes back --
  # `ast_search path=.env pattern="$A = $B"` returns the captured VALUES, which
  # is byte-for-byte what `read_file` returns and what this boundary exists to
  # gate. An earlier edition of this file allowlisted them as deliberately
  # outside; that made a green suite state known bypasses as intended.
  # There is no allowlist now, which is the point: EVERY shipped tool that takes
  # a path is in this table.
  DECLARED = { "read_file" => "path", "glob" => "path", "grep" => "path", "list_files" => "path",
               "edit_file" => "path", "write_file" => "path",
               "ast_search" => "path", "file_symbols" => "path",
               "bash" => "cwd" }.freeze

  # The field spellings a path can arrive under, asked of the tool's own
  # {Lain::Tool::Input} declaration rather than of the table under test.
  PATH_ISH = %w[path cwd].freeze

  def self.path_fields(name)
    model = ToolRegistry.build(name).input_model
    model ? model.fields.keys & PATH_ISH : []
  end

  def self.takes_a_path = ToolRegistry.names.reject { |name| path_fields(name).empty? }

  # A classifier that keeps every path it was asked about.
  class Counting
    attr_reader :asked

    def initialize(inner)
      @inner = inner
      @asked = []
    end

    def classify(path, **)
      @asked << path
      @inner.classify(path, **)
    end
  end
end

RSpec.describe Lain::Sensitivity::Policy do
  subject(:policy) { described_class.new(sensitivity:) }

  let(:home) { "/home/tester" }
  let(:cwd) { "/home/tester/project" }
  let(:rules) { Lain::Sensitivity::Rules.empty }
  let(:sensitivity) { Lain::Sensitivity.new(home:, cwd:, rules:) }

  let(:declared) { SensitivityPolicySpecSupport::DECLARED }

  def call(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  describe "the read tools" do
    it "are every path-taking tool but the three that write or run" do
      expect(described_class::PATH_FIELDS.keys - described_class::READ_TOOLS).to eq(%w[edit_file write_file bash])
      expect(described_class::READ_TOOLS - described_class::PATH_FIELDS.keys).to be_empty
    end
  end

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
      expect(policy.gates?(call("read_file", { "path" => ".env" }), cwd:)).to be(true)
    end

    it "leaves an ordinary path alone" do
      expect(policy.gates?(call("read_file", { "path" => "README.md" }), cwd:)).to be(false)
    end

    # Every entry in the table, driven through its OWN field. `.env` is a
    # basename glob, so it gates wherever it sits and the same fixture serves
    # both axes.
    it "gates every tool in the table through the field that tool declares" do
      declared.each do |name, field|
        expect(policy.gates?(call(name, { field => ".env" }), cwd:)).to be(true), "#{name}.#{field} was not gated"
      end
    end

    it "leaves every tool in the table alone for an ordinary value in the same field" do
      declared.each do |name, field|
        expect(policy.gates?(call(name, { field => "README.md" }), cwd:)).to be(false), "#{name}.#{field} was gated"
      end
    end

    # The table is per TOOL, not "any field spelled path". A command tool's
    # `path` and a file tool's `cwd` are fields neither declares, so reading
    # them would be reading input the tool will never act on.
    it "reads only the field the table names for that tool" do
      expect(policy.gates?(call("bash", { "path" => ".env" }), cwd:)).to be(false)
      expect(policy.gates?(call("read_file", { "cwd" => ".env" }), cwd:)).to be(false)
    end

    it "declines a tool the table does not name at all" do
      expect(policy.gates?(call("todo_write", { "path" => ".env" }), cwd:)).to be(false)
    end

    # `glob`'s path and `bash`'s cwd are both optional, so absence is the
    # common case rather than an error.
    it "declines when the field is absent" do
      expect(policy.gates?(call("glob", { "pattern" => "**/*.rb" }), cwd:)).to be(false)
    end

    it "declines a field whose value is not a path at all" do
      expect(policy.gates?(call("read_file", { "path" => 42 }), cwd:)).to be(false)
      expect(policy.gates?(call("read_file", { "path" => nil }), cwd:)).to be(false)
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
      expect(policy.gates?(call("read_file", { "path" => Pathname.new(".env") }), cwd:)).to be(true)
      expect(policy.gates?(call("read_file", { "path" => Pathname.new("README.md") }), cwd:)).to be(false)
    end

    # The benign half of the same miss, kept so the asymmetry is stated rather
    # than left to luck: an Array coerces to its own `inspect`, which names no
    # file, so declining it leaks nothing. Pathname was the one that bit because
    # `to_path` is the one coercion that yields a path somebody can open.
    it "still declines an Array, which coerces to a name no file has" do
      expect(policy.gates?(call("read_file", { "path" => [".env"] }), cwd:)).to be(false)
      expect(Lain::Tools::ReadFile::Input.build({ "path" => [".env"] }).path).to eq('[".env"]')
    end

    # A parsed provider payload has String keys ({Approval::Escalation::Triage}
    # reads one); specs and in-process callers write Symbols. Reading only one
    # spelling fails OPEN on the other, which is the direction this boundary
    # must never fail in.
    it "reads the field under either key spelling" do
      expect(policy.gates?(call("read_file", { path: ".env" }), cwd:)).to be(true)
      expect(policy.gates?(call("read_file", { "path" => ".env" }), cwd:)).to be(true)
    end

    # Not ordinary, rather than `gated?`: a DENIED path answers false to
    # Verdict#gated?, so a policy asking that question would wave `~/.ssh/id_rsa`
    # straight through -- ungating the most sensitive class of path there is.
    # {Middleware::Sensitivity} refuses a denial outright and is a
    # different card; until it lands this is all there is, and after it lands a
    # gate on a denied path costs at most one prompt for a file already refused.
    it "gates a denied path too, since a denial is not ordinary either" do
      expect(sensitivity.classify("~/.ssh/id_rsa")).to have_attributes(denied?: true, gated?: false)
      expect(policy.gates?(call("read_file", { "path" => "~/.ssh/id_rsa" }), cwd:)).to be(true)
    end

    it "gates a path nothing can read lexically, rather than waving it through" do
      expect(policy.gates?(call("read_file", { "path" => "notes\0.md" }), cwd:)).to be(true)
    end

    # The classifier is INJECTED and its home is injected in turn, so a
    # home-anchored rule has to arrive through both. A policy holding a table
    # of its own would answer this from the wrong home.
    it "gates a home-anchored path through the injected home, not the process's" do
      expect(policy.gates?(call("list_files", { "path" => "#{home}/Downloads" }), cwd:)).to be(true)
      expect(policy.gates?(call("list_files", { "path" => "/home/someone-else/Downloads" }), cwd:)).to be(false)
    end

    # Same argument, project config half: what a `[sensitivity]` table adds must
    # reach this boundary without the policy knowing the table exists.
    context "when the project's config widened the gated set" do
      let(:rules) { Lain::Sensitivity::Rules.from({ "gated" => ["*.private"] }) }

      it "gates what the project named" do
        expect(policy.gates?(call("read_file", { "path" => "notes.private" }), cwd:)).to be(true)
      end
    end

    # {Effect::ToolCall} does not constrain `input`, and this policy runs on the
    # SYNCHRONOUS dispatch path BEFORE {Tool::Input} validation -- so whatever
    # the provider sent arrives here first. Indexing a non-Hash with a String is
    # `Array#[]("path")`, a TypeError, and `nil["path"]` is a NoMethodError:
    # both escape {Middleware::Gate#call}, where nothing raised
    # before this card, because the earlier gate read only `effect.name`.
    #
    # A raise here fails the turn, and the repair somebody reaches for under
    # time pressure is a `rescue` answering false -- which is this boundary
    # failing OPEN. Declining a shape that carries no readable path is the same
    # answer without the trap.
    it "declines rather than raises when the input is not a Hash at all" do
      [[1, 2], nil, "raw", 42].each do |input|
        expect { policy.gates?(call("read_file", input), cwd:) }.not_to raise_error
        expect(policy.gates?(call("read_file", input), cwd:)).to be(false)
      end
    end

    # The String case is worth its own line: `String#[]` is substring search, so
    # a raw JSON payload -- the streaming shape the Provider is meant to have
    # parsed already -- would have had a FRAGMENT of itself read as a path.
    # Harmless by luck (`"path"` classifies ordinary), and not a rule anybody
    # wrote, which is why the Hash check replaces it.
    it "does not read a raw JSON String input as though it held fields" do
      expect(policy.gates?(call("read_file", '{"path":".env"}'), cwd:)).to be(false)
    end

    it "declines an effect that is not a tool call at all" do
      wrapped = Lain::Effect::Approval.new(effect: call("read_file", { "path" => ".env" }))

      expect(policy.gates?(wrapped, cwd:)).to be(false)
      expect(policy.gates?(Lain::Effect::ModelCall.new(request: nil), cwd:)).to be(false)
    end
  end

  # The two tools an earlier edition of this table left out, kept as the
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
      expect(policy.gates?(call("ast_search", { "path" => secret }), cwd:)).to be(true)
    end

    # A smaller leak -- key names rather than values -- and still an enumeration
    # of what the file holds.
    it "gates file_symbols, which otherwise enumerates the secret's key names" do
      result = Lain::Tools::FileSymbols.new.call({ "path" => secret, "language" => "ruby" }, invocation)

      expect(result.content).to include("AWS_SECRET_ACCESS_KEY")
      expect(policy.gates?(call("file_symbols", { "path" => secret }), cwd:)).to be(true)
    end

    it "leaves both alone for an ordinary path, so the boundary is still the path" do
      ordinary = File.join(tmpdir, "notes.rb")

      %w[ast_search file_symbols].each do |name|
        expect(policy.gates?(call(name, { "path" => ordinary }), cwd:)).to be(false), "#{name} was gated for notes.rb"
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
        expect(null.gates?(call(name, { field => ".env" }), cwd:)).to be(false), "#{name} was gated by the Null policy"
        expect(null.gates?(call(name, { field => "~/.ssh/id_rsa" }), cwd:)).to be(false)
      end
    end

    # Total over anything at all, because it ignores its argument -- which is
    # also why nothing was on fire before the Hash guard landed: production
    # wires this one, so the raise the real policy had could not be reached
    # until a classifier was wired. Pinned so the Null cannot quietly grow an
    # opinion about its input.
    it "answers without raising whatever the input is" do
      [nil, [1, 2], "raw", { "path" => ".env" }].each do |input|
        expect { null.gates?(call("read_file", input), cwd:) }.not_to raise_error
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
                                                    input: { "path" => "/home/tester/.ssh/id_rsa" }), cwd:)).to be_nil
    end
  end

  # The denial half of the same question, asked of the SAME object so the two
  # axes read one table. Covered here rather than only through the handler that
  # consults it: a method whose only test lives in a consumer is a method a
  # refactor can delete without anything noticing.
  describe "#denial" do
    let(:denied) { "#{home}/.ssh/id_ed25519" }

    it "answers a Denial naming the call, the tool, the path and the verdict" do
      denial = policy.denial(call("read_file", { "path" => denied }), cwd:)

      expect(denial).to be_a(Lain::Sensitivity::Denial)
      expect(denial).to have_attributes(tool_use_id: "tu_1", tool: "read_file", path: denied, reason: :protected)
      expect(denial.verdict).to have_attributes(denied?: true, explanation: "a protected path")
    end

    it "answers nil for a GATED path, which is the gate's to decide and not this one's" do
      expect(policy.denial(call("read_file", { "path" => ".env" }), cwd:)).to be_nil
      expect(policy.gates?(call("read_file", { "path" => ".env" }), cwd:)).to be(true)
    end

    it "answers nil for an ordinary path, and for a tool the table does not name" do
      expect(policy.denial(call("read_file", { "path" => "README.md" }), cwd:)).to be_nil
      expect(policy.denial(call("web_search", { "path" => denied }), cwd:)).to be_nil
    end

    it "names the tool a WRITE refusal refused, so the Journal can tally by verb" do
      expect(policy.denial(call("write_file", { "path" => denied }), cwd:).tool).to eq("write_file")
      expect(policy.denial(call("bash", { "cwd" => "#{home}/.gnupg" }), cwd:).tool).to eq("bash")
    end

    it "reads a command whose cwd field holds a NUL byte without raising" do
      confined = policy.confined(roots: [cwd])

      expect { confined.denial(call("bash", { "command" => "cat notes", "cwd" => "bad\0dir" }), cwd:) }
        .not_to raise_error
    end

    # {#path_in} reads `effect.name`, which these have not got. A NoMethodError
    # on the dispatch path invites a `rescue` answering "not denied", which is
    # this boundary failing OPEN.
    it "answers nil rather than raising for an effect that names no tool" do
      expect(policy.denial(Lain::Effect::ModelCall.new(request: nil), cwd:)).to be_nil
    end

    describe "an Approval wrapper" do
      def wrapped(effect) = Lain::Effect::Approval.new(effect:)

      # Without this, wrapping LIFTS a denial: the handler sits ahead of the
      # Gate, so it sees the wrapper, declines, and the Gate then unwraps and
      # approves. The unwrap belongs here because this class already owns
      # "which effects name paths".
      it "is looked through, so wrapping cannot lift a denial" do
        expect(policy.denial(wrapped(call("read_file", { "path" => denied })), cwd:)).not_to be_nil
      end

      it "is looked through however many times it is applied" do
        deep = (1..6).inject(call("read_file", { "path" => denied })) { |effect, _| wrapped(effect) }

        expect(policy.denial(deep, cwd:)).to have_attributes(path: denied, tool_use_id: "tu_1")
      end

      # The asymmetry, pinned so it is not "tidied" away: Gate unwraps BEFORE
      # it consults `gates?`, so teaching `gates?` to unwrap would change when
      # the gate fires.
      it "is deliberately NOT looked through by #gates?" do
        expect(policy.gates?(wrapped(call("read_file", { "path" => ".env" })), cwd:)).to be(false)
      end

      it "does not promote a wrapped gated path into a denial" do
        expect(policy.denial(wrapped(call("read_file", { "path" => ".env" })), cwd:)).to be_nil
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

  describe "#root" do
    let(:anchored) { described_class.new(sensitivity:, home:, root: cwd) }

    it "is the root it was configured with, and nil when none was" do
      expect([anchored.root, policy.root]).to eq([cwd, nil])
    end

    it "is the same root through a confinement, and nil for the null policy" do
      null = described_class::Null.instance

      expect([anchored.confined(roots: ["/w"]).root, null.root, null.confined(roots: ["/w"]).root])
        .to eq([cwd, nil, nil])
    end
  end

  describe "#home" do
    let(:anchored) { described_class.new(sensitivity:, home:) }

    it "is the home it was configured with, and nil when none was" do
      expect([anchored.home, policy.home]).to eq([home, nil])
    end

    it "is the same home through a confinement" do
      expect(anchored.confined(roots: ["/w"]).home).to eq(home)
    end

    it "is nil on the Null and its confinement" do
      null = described_class::Null.instance
      expect([null.home, null.confined(roots: ["/w"]).home]).to eq([nil, nil])
    end
  end

  # The listing filter is one of this object's answers over the SAME classifier,
  # rather than something a caller builds beside it. That is what keeps "the
  # gate refused a path the listing enumerated" out: `Filter.new` happens in
  # exactly one place in `lib/`, inside this class, and every reader takes the
  # filter that came with the gate. A discipline rather than an impossibility --
  # {Filter} is a public constructor over anything answering `#classify`.
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

      expect(policy.gates?(call("read_file", { "path" => gated }), cwd:)).to be(true)
      expect(sift(policy.filter, gated).withheld.map(&:reason)).to eq([:credential])
    end

    it "gates and withholds a file whose name names a secret, on one table" do
      Dir.mktmpdir("lain-policy-name") do |dir|
        root = File.realpath(dir)
        File.write(File.join(root, "password.txt"), "hunter2\n")
        named = described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:))
        rows = Dir.children(root).map { |name| File.join(root, name) }

        expect(named.gates?(call("read_file", { "path" => "password.txt" }), cwd: root)).to be(true)
        expect(named.filter.sift(rows) { |row| [row] })
          .to have_attributes(kept: [], withheld: [have_attributes(reason: :named)])
      end
    end

    # A leased worker and `/mode plan` run in a checkout outside the root, so
    # the call's cwd is a base too, for the gate, the listing and bash alike.
    it "agrees with bash in a checkout outside the root", :seam do
      Dir.mktmpdir("lain-policy-checkout") do |dir|
        base = File.realpath(dir)
        home = File.join(base, "home")
        root = File.join(home, "app")
        checkout = File.join(home, ".local", "state", "lain", "worktrees", "abc", "w1")
        FileUtils.mkdir_p([root, File.join(home, ".ssh")])
        secret = File.join(checkout, "secrets", "prod.yml")
        FileUtils.mkdir_p(File.dirname(secret))
        File.write(secret, "hunter2\n")
        File.chmod(0o644, secret)
        project = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag)
        paths = Lain::Paths.new(env: { "HOME" => home })
        table = Lain::CLI::Wiring::BoardBuild.rules(project:, paths:)
        board = Lain::CLI::Wiring::BoardBuild.policy(project:, paths:, table:)
        factory = Lain::CLI::Wiring::BoardBuild.classifiers(project:, paths:, table:)
        sub = File.join(checkout, "sub")
        FileUtils.mkdir_p(sub)

        { checkout => "secrets/prod.yml", sub => "../secrets/prod.yml" }.each do |cwd, relative|
          worker = factory.for(Lain::WorkerEnv.new(cwd:, env: {}, checkout:))
          bash = Lain::Approval::Rule::Call.for(tool: Lain::Tools::Bash.new(verdict: Lain::Shell::Verdict.new),
                                                input: { "command" => "cat #{relative}", "cwd" => cwd })

          [secret, relative].each do |path|
            expect(board.gates?(call("read_file", { "path" => path }), cwd:, within: checkout)).to be(true), path
          end
          expect(board.filter.sift([secret], within: checkout) { |row| [row] }.kept).to be_empty
          expect(Lain::Approval::ComposedTerm.new(sensitivity: worker).decide(bash)).to be_nil
        end
      end
    end

    it "takes a session's checkout as the base, and its cwd when it has none" do
      leased = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/w/co/sub", env: {}, checkout: "/w/co"))
      plain = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/w/app", env: {}))

      expect([described_class.base_of(leased), described_class.base_of(plain)]).to eq(["/w/co", "/w/app"])
    end

    it "keeps a row the gate would let through" do
      ordinary = "#{cwd}/README.md"

      expect(policy.gates?(call("read_file", { "path" => ordinary }), cwd:)).to be(false)
      expect(sift(policy.filter, ordinary).kept).to eq([ordinary])
    end

    it "carries this project's own rules into the filter, not just the built-ins" do
      declared = Lain::Sensitivity::Rules.from({ "denied" => ["*.secret"] })
      configured = described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd:, rules: declared))

      expect(sift(configured.filter, "#{cwd}/prod.secret").withheld.map(&:reason)).to eq([:configured])
    end
  end

  # The fourth phrasing of the one question, and the reason it is a message on
  # this object rather than a reader handing the classifier out: a survey has to
  # ask about a path it is about to LIST, and asking the policy is what puts the
  # walk on the same table as the gate rather than beside it.
  describe "#classify" do
    let(:rules) { Lain::Sensitivity::Rules.from({ "denied" => ["*.secret"] }) }

    it "answers this policy's own classifier, project rules included" do
      expect(policy.classify("#{cwd}/prod.secret")).to have_attributes(level: :denied, reason: :configured)
    end

    it "answers ordinary for a path no table names" do
      expect(policy.classify("#{cwd}/README.md")).to be_ordinary
    end

    # The property that makes a survey safe to wire this way, stated as
    # behaviour: what the gate gates is what this answers not-ordinary about,
    # because there is one classifier behind both.
    it "agrees with the gate, path for path" do
      gated = "#{cwd}/prod.secret"

      expect(policy.gates?(call("read_file", { "path" => gated }), cwd:)).to be(true)
      expect(policy.classify(gated)).not_to be_ordinary
    end
  end

  describe "#classify within a tree" do
    it "reads a secret directory name below that tree, though it sits outside the project" do
      expect(policy.classify("/srv/other/secrets/prod", within: "/srv/other")).to have_attributes(named?: true)
    end

    it "judges the same path ordinary without the tree" do
      expect(policy.classify("/srv/other/secrets/prod")).to be_ordinary
    end

    it "is accepted and ignored by the Null" do
      expect(described_class::Null.instance.classify("/srv/other/secrets/prod", within: "/srv/other")).to be_ordinary
    end
  end

  describe "#marks" do
    it "answers this policy's own classifier" do
      expect(policy.marks("#{cwd}/a/.ssh")).to eq(sensitivity.marks("#{cwd}/a/.ssh")).and be_any
    end

    it "answers none on the Null and passes the confined policy's through" do
      expect(described_class::Null.instance.marks("#{cwd}/a/.ssh")).to eq([]).and be_frozen
      expect(policy.confined(roots: []).marks("#{cwd}/a/.ssh")).to eq(sensitivity.marks("#{cwd}/a/.ssh"))
    end

    it "answers lifts from its classifier, none on the Null, and the confined policy's through" do
      expect(policy.lifts("#{cwd}/a")).to eq(sensitivity.lifts("#{cwd}/a"))
      expect(described_class::Null.instance.lifts("#{cwd}/a")).to eq([]).and be_frozen
      expect(policy.confined(roots: []).lifts("#{cwd}/a")).to eq(sensitivity.lifts("#{cwd}/a"))
    end
  end

  describe "#related?" do
    let(:rules) { Lain::Sensitivity::Rules.from({ "related" => ["~/dev/pitchcraft"] }) }

    it "answers this policy's own classifier about a related directory" do
      expect(policy.related?("#{home}/dev/pitchcraft/notes.md")).to be(true)
      expect(policy.related?("#{home}/dev/other/notes.md")).to be(false)
    end

    it "answers false on the Null, so a run that wired no classifier still asks" do
      expect(described_class::Null.instance.related?("#{home}/dev/pitchcraft/notes.md")).to be(false)
    end

    it "answers false to in_related_tree? on the Null" do
      expect(described_class::Null.instance.in_related_tree?("#{home}/dev/pitchcraft")).to be(false)
    end
  end

  # The Null answers it too, because a run that wired no classifier must still
  # be able to walk a tree -- and everything it sees is ordinary, which is the
  # same posture its `gates?` already takes.
  describe "Null#classify" do
    it "answers an ordinary verdict for anything at all" do
      expect(described_class::Null.instance.classify("/home/tester/.ssh/id_rsa")).to be_ordinary
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

  # A link's name says nothing about what it opens, so the path is judged twice:
  # as written and where it lands, and the stricter verdict wins.
  describe "judging a path where it lands" do
    around do |example|
      Dir.mktmpdir("lain-policy-landing") do |dir|
        @base = File.realpath(dir)
        FileUtils.mkdir_p([File.join(@base, "home", ".ssh"), File.join(@base, "project"), File.join(@base, "worker")])
        File.write(File.join(@base, "home", ".ssh", "id_qa"), "key\n")
        example.run
      end
    end

    let(:home) { File.join(@base, "home") }
    let(:cwd) { File.join(@base, "project") }

    def link(name, target, under: cwd) = File.symlink(target, File.join(under, name))
    def read(path) = call("read_file", { "path" => path })

    it "refuses a link to a denied file, naming the link as the model wrote it" do
      link("notes.txt", File.join(home, ".ssh", "id_qa"))

      expect(policy.denial(read("notes.txt"), cwd:)).to have_attributes(path: "notes.txt", reason: :protected)
    end

    it "gates a link to a gated file" do
      File.write(File.join(cwd, ".env.local"), "PLAIN=1\n")
      link("readme2.txt", ".env.local")

      expect(policy.gates?(read("readme2.txt"), cwd:)).to be(true)
      expect(policy.denial(read("readme2.txt"), cwd:)).to be_nil
    end

    it "gates a write through a link" do
      FileUtils.mkdir_p(File.join(cwd, "config"))
      link("cfg.txt", "config/master.key")

      expect(policy.gates?(call("write_file", { "path" => "cfg.txt", "content" => "x" }), cwd:)).to be(true)
    end

    it "leaves a link to an ordinary file ordinary" do
      File.write(File.join(cwd, "b.txt"), "plain\n")
      link("a.txt", "b.txt")

      expect(policy.gates?(read("a.txt"), cwd:)).to be(false)
    end

    it "resolves a relative link against the cwd it is given, not the classifier's" do
      link("notes.txt", File.join(home, ".ssh", "id_qa"), under: File.join(@base, "worker"))

      expect(policy.denial(read("notes.txt"), cwd: File.join(@base, "worker"))).not_to be_nil
      expect(policy.denial(read("notes.txt"), cwd:)).to be_nil
    end

    it "gates a dangling link and a looping one as malformed, and raises for neither" do
      link("gone", "missing")
      link("loop", "loop")

      %w[gone loop].each do |name|
        expect(policy.gates?(read(name), cwd:)).to be(true), "#{name} was not gated"
        expect(policy.denial(read(name), cwd:)).to be_nil
        expect(policy.judge(name, cwd:)).to have_attributes(level: :gated, reason: :malformed)
      end
    end

    # `~/.kube/config` is denied only under home, so this fails without the
    # re-spelling; an `id_*` under any `.ssh` is denied anywhere and could not.
    it "judges a home-anchored rule on a landing under a home that is itself a link" do
      FileUtils.mkdir_p(File.join(home, ".kube"))
      File.write(File.join(home, ".kube", "config"), "token: x\n")
      linked_home = File.join(@base, "home-link")
      File.symlink(home, linked_home)
      spelled = described_class.new(sensitivity: Lain::Sensitivity.new(home: linked_home, cwd:), home: linked_home)
      link("k", File.join(linked_home, ".kube", "config"))

      expect(spelled.denial(read("k"), cwd:)).to have_attributes(reason: :protected)
    end

    it "refuses a dangling link whose target would be a denied file" do
      link("ak", File.join(home, ".ssh", "id_new"))

      expect(policy.denial(call("write_file", { "path" => "ak", "content" => "x" }), cwd:))
        .to have_attributes(path: "ak", reason: :protected)
    end

    it "refuses a dangling link whose .. climbs out of a linked directory onto a denied file" do
      FileUtils.mkdir_p(File.join(home, ".ssh", "config.d"))
      link("sd", File.join(home, ".ssh", "config.d"))
      link("dk", "sd/../id_kern")

      expect(policy.denial(read("dk"), cwd:)).to have_attributes(reason: :protected)
    end

    it "refuses a chain of dangling links ending on a denied file" do
      link("hop", File.join(home, ".ssh", "id_new"))
      link("ak", "hop")

      expect(policy.denial(read("ak"), cwd:)).to have_attributes(reason: :protected)
    end

    it "classifies an absolute path that lands on itself once, not once per spelling" do
      counting = SensitivityPolicySpecSupport::Counting.new(sensitivity)
      File.write(File.join(cwd, "b.txt"), "plain\n")

      described_class.new(sensitivity: counting).judge(File.join(cwd, "b.txt"), cwd:)

      expect(counting.asked).to eq([File.join(cwd, "b.txt")])
    end

    it "withholds a listing row under a linked directory as the gate would refuse it" do
      link("keys", File.join(home, ".ssh"))
      row = File.join(cwd, "keys", "id_qa")

      expect(policy.filter.sift([row]) { |each| [each] }.withheld.map(&:reason)).to eq([:protected])
    end
  end

  # {#judge} is the oracle: {#mask_paths} takes a shortcut through each
  # directory's real path, and only a link may take the long way round.
  describe "#mask_paths against #judge, name by name" do
    around do |example|
      Dir.mktmpdir("lain-policy-listed") do |dir|
        @base = File.realpath(dir)
        real_home = File.join(@base, "realhome")
        dirs = %w[.ssh .aws .kube project/sub project/.lain project/~nobody tokens]
        FileUtils.mkdir_p(dirs.map { File.join(real_home, _1) })
        File.write(File.join(real_home, ".ssh", "id_rsa"), "key\n")
        File.write(File.join(real_home, ".kube", "config"), "token: x\n")
        File.write(File.join(real_home, "tokens", "tokens.txt"), "t\n")
        File.symlink(real_home, File.join(@base, "home"))
        example.run
      end
    end

    let(:home) { File.join(@base, "home") }
    let(:real_root) { File.join(@base, "realhome", "project") }
    let(:listing) do
      %w[README.md .env sub/plain.txt key_link abs_key_link envlink linkdir linkdir/id_rsa aws shadow
         tokdir tokdir/tokens.txt readme.key absent.env ./sub/plain.txt sub/../.env kubedir/config
         .lain/config.rb ~notes.txt ~nobody/x]
    end

    def listed_policy(root, cwd: root)
      described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd:, root:), home:, root:)
    end

    def judged(policy, names, cwd) = names.filter_map { judged_mask(policy, _1, cwd) }.uniq(&:first)

    def judged_mask(policy, name, cwd)
      verdict = policy.judge(name.start_with?("~") ? File.join(cwd, name) : name, cwd:)
      [File.realpath(name, cwd), verdict.reason] if described_class.masks?(verdict)
    rescue SystemCallError
      nil
    end

    def masked(policy, names, cwd) = policy.mask_paths(names, cwd:).map { [_1.path, _1.reason] }

    def plant(root)
      { "README.md" => "r\n", ".env" => "A=1\n", "sub/plain.txt" => "p\n", ".lain/config.rb" => "c\n",
        "~notes.txt" => "n\n", "~nobody/x" => "x\n" }
        .each { |name, body| File.write(File.join(root, name), body) }
      { "key_link" => "../.ssh/id_rsa", "abs_key_link" => File.join(home, ".ssh", "id_rsa"), "envlink" => ".env",
        "linkdir" => "../.ssh", "aws" => "../.aws/credentials", "shadow" => "/etc/shadow",
        "tokdir" => File.join(home, "tokens"), "readme.key" => "README.md", "kubedir" => File.join(home, ".kube") }
        .each { |name, target| File.symlink(target, File.join(root, name)) }
    end

    it "masks every symlink escape as judge does, with the root spelled through the linked home and at its real path" do
      plant(real_root)

      [File.join(home, "project"), real_root].product(["", "sub"]).each do |root, below|
        policy = listed_policy(root, cwd: File.join(root, below))
        names = [*listing, *listing.first(8).map { File.join(root, _1) }]

        names.each do |name|
          expect(masked(policy, [name], root)).to eq(judged(policy, [name], root)),
                                                  "#{name} under #{root}, classifier cwd at #{File.join(root, below)}"
        end
        expect(masked(policy, names, root)).to eq(judged(policy, names, root))
      end
    end

    it "does 1 realpath per directory over a plain listing, with judge's verdicts" do
      dirs = [".", *Array.new(19) { "d#{_1}" }]
      dirs.each { FileUtils.mkdir_p(File.join(real_root, _1)) }
      names = Array.new(300) { |i| File.join(dirs[i % 20], "f#{i}.txt").delete_prefix("./") }
      names.each { File.write(File.join(real_root, _1), "x\n") }
      policy = listed_policy(real_root)
      own = Thread.current
      calls = 0
      allow(File).to receive(:realpath).and_wrap_original do |original, *args|
        calls += 1 if Thread.current.equal?(own)
        original.call(*args)
      end
      stray = Thread.new { loop { File.realpath(real_root) } }

      masks = begin
        masked(policy, names, real_root)
      ensure
        stray.kill.join
      end

      expect(calls).to be <= 21
      expect(masks).to eq(judged(policy, names, real_root))
    end

    it "lands a listed name starting with ~ under the root, never in home" do
      plant(real_root)
      FileUtils.mkdir_p(File.join(real_root, "~"))
      File.write(File.join(real_root, "~", "plain.txt"), "p\n")
      root = File.join(home, "project")
      asked = []
      sensitivity = Class.new(SimpleDelegator) do
        define_method(:classify) { |path, **kw| asked.push(path).then { super(path, **kw) } }
      end.new(Lain::Sensitivity.new(home:, cwd: root, root:))
      policy = described_class.new(sensitivity:, home:, root:)

      masks = policy.mask_paths(%w[~notes.txt ~/plain.txt ~nobody/x], cwd: root)

      expect(masks).to be_empty
      expect(asked).not_to be_empty
      expect(asked).to all(start_with("#{root}/").or(start_with("#{real_root}/")))
    end

    it "still reads a named ~ as home on the gate path" do
      root = File.join(home, "project")
      policy = listed_policy(root)

      expect(policy.judge("~/.ssh/id_rsa", cwd: root))
        .to eq(policy.judge(File.join(home, ".ssh", "id_rsa"), cwd: root))
        .and have_attributes(reason: :protected)
      expect(policy.judge("~/.kube/config", cwd: root))
        .to eq(policy.judge(File.join(home, ".kube", "config"), cwd: root))
        .and have_attributes(reason: :protected)
    end
  end

  describe "#mask_paths" do
    around do |example|
      Dir.mktmpdir("lain-policy-masks") do |dir|
        @base = File.realpath(dir)
        FileUtils.mkdir_p(%w[home/.ssh home/Documents project/config elsewhere].map { File.join(@base, _1) })
        { "home/.ssh/id_qa" => "key\n", "home/Documents/plan.txt" => "x\n", "project/.env" => "A=1\n",
          "project/config/master.key" => "k\n", "project/api_token.txt" => "t\n", "project/README.md" => "r\n",
          "elsewhere/notes.txt" => "n\n" }.each { |path, body| File.write(File.join(@base, path), body) }
        File.symlink(".env", File.join(@base, "project", "settings.txt"))
        example.run
      end
    end

    let(:home) { File.join(@base, "home") }
    let(:cwd) { File.join(@base, "project") }
    let(:id_key) { File.join(home, ".ssh", "id_qa") }
    let(:listing) { [".env", "config/master.key", "settings.txt", "api_token.txt", "README.md", id_key] }

    def masked(files, by: policy) = by.mask_paths(files, cwd:).map { [_1.path, _1.reason] }

    it "masks every file the Policy does not call ordinary, where it lands, each once and with its reason" do
      expect(masked(listing)).to eq([[File.join(cwd, ".env"), :credential],
                                     [File.join(cwd, "config", "master.key"), :credential],
                                     [File.join(cwd, "api_token.txt"), :named],
                                     [id_key, :protected]])
    end

    it "masks a symlink's landing rather than the link" do
      expect(masked(["settings.txt"])).to eq([[File.join(cwd, ".env"), :credential]])
    end

    it "masks a project's own gated rule" do
      File.write(File.join(cwd, "plan.internal"), "i\n")
      internal = Lain::Sensitivity::Rules.from({ "gated" => %w[*.internal] })
      configured = described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd:, rules: internal))

      expect(masked(["plan.internal"], by: configured)).to eq([[File.join(cwd, "plan.internal"), :configured]])
    end

    it "masks a file whose name is not valid UTF-8" do
      File.write(File.join(cwd, "bad\xFFname.txt".b), "x\n")

      expect(masked(["bad\xFFname.txt"]).map(&:last)).to eq([:malformed])
    end

    it "masks a link's landing when only the link's name is sensitive, with the name's reason" do
      File.symlink("README.md", File.join(cwd, "readme.key"))

      expect(masked(["readme.key"])).to eq([[File.join(cwd, "README.md"), :credential]])
    end

    it "never masks a file under the project's .git, whatever names it" do
      FileUtils.mkdir_p(File.join(cwd, ".git"))
      File.write(File.join(cwd, ".git", "index"), "i\n")
      File.symlink(".git/index", File.join(cwd, "idx.pem"))
      File.write(File.join(cwd, ".git-credentials"), "c\n")
      FileUtils.mkdir_p(File.join(cwd, ".github"))
      File.write(File.join(cwd, ".github", "x.pem"), "k\n")
      rooted = described_class.new(sensitivity:, home:, root: cwd)

      expect(masked(%w[idx.pem .git-credentials .github/x.pem], by: rooted).map(&:first))
        .to eq([File.join(cwd, ".git-credentials"), File.join(cwd, ".github", "x.pem")])
    end

    it "never masks a file in a linked worktree's git dir, which lies outside the project" do
      admin = File.join(@base, "main", ".git", "worktrees", "project")
      FileUtils.mkdir_p(admin)
      File.write(File.join(admin, "index"), "i\n")
      File.write(File.join(cwd, ".git"), "gitdir: #{admin}\n")
      File.symlink(File.join(admin, "index"), File.join(cwd, "idx.pem"))
      rooted = described_class.new(sensitivity:, home:, root: cwd)

      expect(masked(%w[idx.pem], by: rooted)).to be_empty
    end

    it "leaves out a dangling link and a name that does not exist" do
      File.symlink("missing.env", File.join(cwd, "gone.env"))

      expect(masked(%w[gone.env absent.env])).to be_empty
    end

    it "counts a secret directory name below `within`, though it sits outside the project" do
      FileUtils.mkdir_p(File.join(@base, "elsewhere", "secrets"))
      File.write(File.join(@base, "elsewhere", "secrets", "prod"), "p\n")
      prod = File.join(@base, "elsewhere", "secrets", "prod")

      expect(policy.mask_paths([prod], cwd:, within: File.join(@base, "elsewhere")).map(&:reason)).to eq([:named])
      expect(policy.mask_paths([prod], cwd:)).to be_empty
    end

    it "agrees with the listing filter on every row the filter withholds as a secret" do
      rows = [*listing.map { File.expand_path(_1, cwd) }, File.join(home, "Documents", "plan.txt")]
      withheld = ->(row) { policy.filter.sift([row], within: cwd) { [_1] }.withheld }
      secret = rows.select { |row| withheld.call(row).any? { described_class.masks?(_1) } }

      expect(policy.mask_paths(rows, cwd:).map(&:path)).to eq(secret.map { File.realpath(_1) }.uniq)
    end

    it "is a deeply frozen value" do
      expect(policy.mask_paths(listing, cwd:)).to all(satisfy { Ractor.shareable?(_1) })
    end

    describe "a location verdict" do
      let(:documents) { File.join(home, "Documents", "plan.txt") }
      let(:outside) { File.join(@base, "elsewhere", "notes.txt") }
      let(:confined) { policy.confined(roots: [cwd]) }

      it "is not a mask when the path is out of scope" do
        expect(policy.judge(documents, cwd:).reason).to eq(:out_of_scope)
        expect(masked([documents])).to be_empty
      end

      it "is not a mask when a confined policy judges the path outside the project" do
        expect(confined.judge(outside, cwd:).reason).to eq(:outside_project)
        expect(masked([outside], by: confined)).to be_empty
      end
    end

    it "answers false from .masks? for a location verdict" do
      expect([described_class::OUTSIDE_PROJECT, Lain::Sensitivity::Verdict.new(level: :gated, reason: :out_of_scope)]
               .map { described_class.masks?(_1) }).to eq([false, false])
    end

    it "masks nothing under the Null policy" do
      expect(described_class::Null.instance.mask_paths(listing, cwd:)).to eq([])
    end
  end

  # A child's reads stay in its project, its related directories and its own
  # tree; anything else parks for a human, whatever its name.
  describe "#confined" do
    around do |example|
      Dir.mktmpdir("lain-policy-confined") do |dir|
        @base = File.realpath(dir)
        FileUtils.mkdir_p(%w[home/notes project/lib worker elsewhere].map { File.join(@base, _1) })
        example.run
      end
    end

    let(:home) { File.join(@base, "home") }
    let(:root) { File.join(@base, "project") }
    let(:worker) { File.join(@base, "worker") }
    let(:rules) { Lain::Sensitivity::Rules.new(related: ["~/notes"]) }
    let(:policy) do
      described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:, rules:), home:, root:)
    end
    let(:confined) { policy.confined(roots: [worker]) }

    def read(path) = call("read_file", { "path" => path })
    def glob(path, pattern) = call("glob", { "path" => path, "pattern" => pattern })

    it "gates a read outside every root as outside the project" do
      outside = File.join(@base, "elsewhere", "a.md")

      expect(confined.gates?(read(outside), cwd: root)).to be(true)
      expect(confined.judge(outside, cwd: root)).to have_attributes(level: :gated, reason: :outside_project)
      expect(Lain::Sensitivity::Verdict::REASONS).to include(:outside_project)
    end

    it "leaves a read in the project, a related directory or the child's own root ungated" do
      inside = [read("lib"), read(File.join(home, "notes", "a.md")), read(File.join(worker, "b.rb"))]

      expect(inside.map { confined.gates?(_1, cwd: root) }).to eq([false, false, false])
    end

    it "gates every read tool that names a path outside, and leaves a write to the gate's other rules" do
      outside = File.join(@base, "elsewhere")
      reads = described_class::READ_TOOLS.map { call(_1, { "path" => outside }) }

      expect(reads.map { confined.gates?(_1, cwd: root) }).to all(be(true))
      expect(confined.gates?(call("write_file", { "path" => File.join(outside, "x"), "content" => "" }), cwd: root))
        .to be(false)
    end

    it "answers outside? for a write not yet on disk by where its directory lands" do
      File.symlink(File.join(@base, "elsewhere"), File.join(root, "out"))
      project = policy.confined(roots: [root])

      expect(%w[lib/new.rb lib/new/deep.rb out/new.rb ../elsewhere/new/a.rb].map { project.outside?(_1, cwd: root) })
        .to eq([false, false, true, true])
    end

    it "gates a glob whose pattern climbs or reaches out of the roots, and one rooted at /" do
      expect(confined.gates?(glob(".", "../../**/*.md"), cwd: root)).to be(true)
      expect(confined.gates?(glob(".", "#{@base}/elsewhere/*.md"), cwd: root)).to be(true)
      expect(confined.gates?(glob("/", "**/*.md"), cwd: root)).to be(true)
      expect(confined.gates?(glob(".", "lib/**/*.rb"), cwd: root)).to be(false)
    end

    it "gates a link inside the project that lands outside it" do
      File.symlink(File.join(@base, "elsewhere"), File.join(root, "out"))

      expect(confined.gates?(read("out/a.md"), cwd: root)).to be(true)
    end

    it "keeps the policy's own denial of a path outside every root" do
      key = File.join(home, ".ssh", "id_rsa").tap { FileUtils.mkdir_p(File.dirname(_1)) && File.write(_1, "k") }

      expect(confined.judge(key, cwd: root)).to have_attributes(level: :denied, reason: :protected)
    end

    it "leaves list_files, glob and grep on a related directory itself ungated" do
      notes = File.join(home, "notes")
      walks = [call("list_files", { "path" => notes }), glob(notes, "**/*.md"),
               call("grep", { "path" => notes, "pattern" => "x" })]

      expect(walks.map { confined.gates?(_1, cwd: root) }).to eq([false, false, false])
    end

    it "gates a related directory's sibling that shares its prefix" do
      old = File.join(home, "notes-old")

      expect(confined.judge(old, cwd: root)).to have_attributes(level: :gated, reason: :outside_project)
      expect(confined.gates?(call("list_files", { "path" => old }), cwd: root)).to be(true)
    end

    it "keeps related? false and in_related_tree? true for the related directory itself, which masking relies on" do
      notes = File.join(home, "notes")

      expect([policy.related?(notes), policy.related?(File.join(notes, "a.md"))]).to eq([false, true])
      expect([policy.in_related_tree?(notes), policy.in_related_tree?(File.join(notes, "a.md"))]).to eq([true, true])
    end

    it "gates a sibling whose name only starts with the root's" do
      sibling = File.join(@base, "project-other", "a.rb")

      expect(confined.gates?(read(sibling), cwd: root)).to be(true)
    end

    it "fails closed on a link loop and on a directory it may not enter" do
      skip "root enters a directory whatever its mode" if Process.uid.zero?

      File.symlink("loop", File.join(root, "loop"))
      locked = File.join(root, "locked").tap { FileUtils.mkdir_p(File.join(_1, "inner")) }
      File.chmod(0o000, locked)

      expect(confined.judge("loop", cwd: root)).to have_attributes(reason: :malformed, oracle_approvable?: false)
      expect(confined.judge("locked/inner/a.rb", cwd: root)).to have_attributes(reason: :malformed)
    ensure
      File.chmod(0o755, locked) if locked
    end

    it "keeps the policy's own denials, listing filter and name rules" do
      expect(confined.denial(read(File.join(home, ".ssh", "id_rsa")), cwd: root)).to have_attributes(reason: :protected)
      expect(confined.filter).to be(policy.filter)
      expect(confined.gates?(read(".env"), cwd: root)).to be(true)
      expect(confined.related?(File.join(home, "notes", "a.md"))).to be(true)
    end

    it "keeps a credential reason outside its roots, which the secret oracle may not approve" do
      npmrc = File.join(@base, "elsewhere", ".npmrc").tap { File.write(_1, "//registry/:_authToken=x\n") }

      expect(confined.judge(npmrc, cwd: root)).to have_attributes(reason: :credential, oracle_approvable?: false)
    end

    it "still names a plain file outside its roots as outside the project" do
      notes = File.join(@base, "elsewhere", "notes.txt").tap { File.write(_1, "notes\n") }

      expect(confined.judge(notes, cwd: root)).to have_attributes(reason: :outside_project)
    end

    it "names a link's credential landing whether the out-of-scope side is its name or its landing" do
      documents = File.join(home, "Documents").tap { FileUtils.mkdir_p(_1) }
      File.write(File.join(root, ".npmrc"), "//registry/:_authToken=x\n")
      File.symlink(File.join(root, ".npmrc"), File.join(documents, "registry"))
      File.write(File.join(documents, "plain.txt"), "plain\n")
      File.symlink(File.join(documents, "plain.txt"), File.join(root, "lib", ".npmrc"))

      expect([confined.judge(File.join(documents, "registry"), cwd: root), confined.judge("lib/.npmrc", cwd: root)])
        .to all(have_attributes(reason: :credential))
    end

    it "answers outside? by containment, whatever the path's name is judged for" do
      documents = File.join(home, "Documents").tap { FileUtils.mkdir_p(_1) }
      ssh = File.join(home, ".ssh").tap { FileUtils.mkdir_p(_1) }

      paths = [documents, ssh, File.join(home, "notes"), File.join(worker, "a.rb")]

      expect(paths.map { confined.outside?(_1, cwd: root) }).to eq([true, true, false, false])
    end

    it "answers in_related_tree? as its policy does" do
      notes = File.join(home, "notes")

      expect([confined.in_related_tree?(notes), confined.in_related_tree?(File.join(@base, "elsewhere"))])
        .to eq([true, false])
    end

    it "confines again with more roots, keeping the ones it had" do
      again = confined.confined(roots: [File.join(@base, "elsewhere")])

      expect([read(File.join(worker, "a.rb")), read(File.join(@base, "elsewhere", "a.md")), read("lib")]
               .map { again.gates?(_1, cwd: root) }).to eq([false, false, false])
    end

    it "answers ordinary over the Null for a path inside its roots, and outside the project beyond them" do
      null = described_class::Null.instance.confined(roots: [worker])

      expect(null.judge(File.join(worker, "a.rb"), cwd: worker)).to be_ordinary
      expect(null.judge(File.join(root, "a.rb"), cwd: worker)).to have_attributes(reason: :outside_project)
    end

    it "holds a path under a root spelled with a trailing slash, and the root itself" do
      slashed = policy.confined(roots: ["#{worker}/"])

      expect([File.join(worker, "a.rb"), worker].map { slashed.gates?(read(_1), cwd: worker) }).to eq([false, false])
    end

    it "holds every path under the filesystem root" do
      expect(policy.confined(roots: ["/"]).gates?(read(File.join(@base, "elsewhere", "a.md")), cwd: root)).to be(false)
    end

    it "confines a policy with no project root to the roots it is given" do
      rootless = described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd: worker), home:)

      expect(rootless.confined(roots: [worker]).gates?(read(File.join(root, "lib")), cwd: worker)).to be(true)
      expect(rootless.confined(roots: [worker]).gates?(read("x.rb"), cwd: worker)).to be(false)
    end

    describe "the account database" do
      it "refuses a read of /etc/passwd, saying where the home directory really is" do
        denial = confined.denial(read("/etc/passwd"), cwd: root)

        expect(denial).to have_attributes(tool: "read_file", path: "/etc/passwd", reason: :account_database)
        expect(denial.verdict).to have_attributes(denied?: true)
        expect(denial.advice).to eq("the agent's home directory is #{home}")
        expect(Ractor.shareable?(denial.advice)).to be(true)
        expect(denial.verdict.explanation).not_to include("$HOME")
      end

      it "gives no home advice when the policy holds no home" do
        null = described_class::Null.instance.confined(roots: [worker])

        expect(null.denial(read("/etc/passwd"), cwd: worker).advice).to be_nil
      end

      it "refuses the backup copies the system keeps of both files" do
        expect(%w[/etc/passwd- /etc/group-].map { confined.denial(read(_1), cwd: root)&.reason })
          .to all(eq(:account_database))
      end

      it "refuses a walk rooted at /etc/group" do
        expect(confined.denial(glob("/etc/group", "*"), cwd: root)).to have_attributes(reason: :account_database)
      end

      it "refuses every read tool, a spelling that climbs back into /etc, and an Approval wrapper" do
        reads = described_class::READ_TOOLS.map { call(_1, { "path" => "/etc/passwd" }) }
        wrapped = Lain::Effect::Approval.new(effect: read("/etc/../etc/passwd"))

        expect([*reads, wrapped].map { confined.denial(_1, cwd: root)&.reason }).to all(eq(:account_database))
      end

      it "refuses a link in the project that lands on /etc/passwd" do
        File.symlink("/etc/passwd", File.join(root, "accounts"))

        expect(confined.denial(read("accounts"), cwd: root)).to have_attributes(reason: :account_database)
      end

      it "refuses it over the Null policy too" do
        null = described_class::Null.instance.confined(roots: [worker])

        expect(null.denial(read("/etc/passwd"), cwd: worker)).to have_attributes(reason: :account_database)
      end

      it "leaves other reads of /etc to the gate, and a write to the policy" do
        expect(confined.denial(read("/etc/hosts"), cwd: root)).to be_nil
        expect(confined.denial(call("write_file", { "path" => "/etc/passwd", "content" => "" }), cwd: root)).to be_nil
      end

      it "refuses a bash command that names the account database, with the same home advice" do
        denial = confined.denial(call("bash", { "command" => "cat /etc/passwd" }), cwd: root)

        expect(denial).to have_attributes(tool: "bash", reason: :account_database,
                                          advice: "the agent's home directory is #{home}")
      end

      it "refuses through bash what the policy refuses a read tool, as the read tool is refused" do
        paths = ["/etc/shadow", "/etc/sudoers", File.join(home, ".ssh", "id_rsa")]

        paths.each do |path|
          expected = confined.denial(read(path), cwd: root)
          actual = confined.denial(call("bash", { "command" => "cat #{path}" }), cwd: root)

          expect(expected).not_to be_nil
          expect(actual).to have_attributes(tool: "bash", reason: expected.reason, advice: expected.advice)
        end
      end

      it "leaves a path the project's own config denies to the shell rung" do
        rules = Lain::Sensitivity::Rules.from({ "denied" => ["*.secret"] })
        configured = described_class.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, rules:), home:, root:)
                                    .confined(roots: [worker])

        expect(configured.denial(call("bash", { "command" => "cat #{root}/prod.secret" }), cwd: root)).to be_nil
      end

      it "answers nil, without raising, for a bash call whose input is not a hash" do
        expect([["x"], "cat /etc/passwd"].map { confined.denial(call("bash", _1), cwd: root) }).to all(be_nil)
      end

      it "leaves a bash command that names no account file to the gate" do
        expect(confined.denial(call("bash", { "command" => "cat /etc/hosts" }), cwd: root)).to be_nil
      end

      it "leaves the main agent's read of /etc/passwd gated rather than refused" do
        expect(policy.denial(read("/etc/passwd"), cwd: root)).to be_nil
        expect(policy.gates?(read("/etc/passwd"), cwd: root)).to be(true)
      end
    end
  end
end
