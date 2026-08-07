# frozen_string_literal: true

require "digest"
require "fileutils"
require "shellwords"
require "stringio"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ConsentSpecSupport
  # A repository that pre-approves one bash call outright: the cloned-repo
  # hazard, literally. A LITERAL fixture, never sliced from a constant in the
  # subject -- an entry built from `Config::Answers::ALLOW` would still match
  # itself after a rename that broke every real config on disk.
  ALLOWS_BASH = <<~TOML
    [[approval.allow]]
    tool = "bash"
    input = { command = "rm -rf /tmp/scratch" }
  TOML

  # The queue rung's stand-in: answers a fixed verdict the way
  # {Lain::Approval::Queue#adjudicate} does, without parking a fiber, and
  # remembers whether it was asked at all -- which is the whole of "the call
  # reaches the queue".
  class Parked
    Answer = Data.define(:approved, :surface) do
      def approved? = approved
    end

    attr_reader :asked

    def initialize(approved: false, surface: "tty")
      @answer = Answer.new(approved:, surface:)
      @asked = []
    end

    def adjudicate(effect, _context)
      @asked << effect.tool_use_id
      @answer
    end
  end

  # A confirmer that answers a fixed value and records what it was shown, so an
  # example can tell "asked and refused" from "never asked".
  class Asked
    attr_reader :projects

    def initialize(answer)
      @answer = answer
      @projects = []
    end

    def call(project)
      @projects << project
      @answer
    end
  end

  # Everything the notice seam was told, in order.
  class Notices
    include Enumerable

    def initialize = @said = []
    def call(message) = @said << message
    def each(&block) = @said.each(&block)
  end
end

RSpec.describe Lain::Project::Consent do
  def parked(**) = ConsentSpecSupport::Parked.new(**)
  def asked(answer) = ConsentSpecSupport::Asked.new(answer)
  def notices = ConsentSpecSupport::Notices.new
  def allows_bash = ConsentSpecSupport::ALLOWS_BASH

  # Every example builds its own throwaway root AND its own XDG state home: the
  # subject's whole business is a mark under `$XDG_STATE_HOME`, so no example
  # may go near the real one (remembered_spec.rb's posture, one directory over).
  def with_root
    Dir.mktmpdir do |tmp|
      @home = File.realpath(tmp)
      root = File.realpath(File.join(@home, "checkout").tap { |dir| FileUtils.mkdir_p(dir) })
      state = File.join(@home, "state")
      yield root, Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => @home }), @home
    end
  end

  def write_config(root, body)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(File.join(root, ".lain", "config.toml"), body)
  end

  # THE REAL RESOLVER, driven exactly as `exe/lain`'s `resolved_project` drives
  # it: `Resolver.new(home:).call(cwd:, root:)`, with `root:` present only when
  # a flag named one.
  #
  # Nothing here hands `detected_by:` to a `Project` constructor any more, and
  # that was a defect rather than a shortcut. Every fixture used to pass
  # `cwd: root` alongside a hand-written `detected_by: :flag` -- which happens
  # to be exactly what T6's `--cwd` default produces, so ACs 2 and 3 were right
  # by COINCIDENCE rather than by construction. A fixture that supplies the
  # rung it means to test cannot test it; the resolver has to be the one that
  # says `:flag`.
  def flagged_project(root, paths:, home: @home, cwd: nil)
    Lain::Project::Resolver.new(home:, paths:).call(root:, cwd: cwd || root).project
  end

  def walked_project(root, paths:, home: @home, cwd: nil)
    Lain::Project::Resolver.new(home:, paths:).call(cwd: cwd || root).project
  end

  def consent_for(root, paths:, flag: false, cwd: nil, **rest)
    project = flag ? flagged_project(root, paths:, cwd:) : walked_project(root, paths:, cwd:)
    described_class.for(project:, paths:, **rest)
  end

  # The mark's path, re-derived LITERALLY rather than asked of the subject: a
  # spec that computes it through `Record#path_for` would agree with any recipe
  # the subject grew, including a truncated digest.
  def mark_path(root, paths) = File.join(paths.state_home, "consent", Digest::SHA256.hexdigest(root))

  let(:bash) { Lain::Tools::Bash.new }
  let(:tools) { Lain::Toolset.new([bash, Lain::Tools::ReadFile.new]) }
  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:effect) do
    Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "rm -rf /tmp/scratch" })
  end

  # The rung as {Lain::Approval::Escalation.for} builds it, driven directly:
  # "the rules rung abstains" and "the rules rung allows it" are statements
  # about THIS object's Ruling, and reading it here is what keeps them from
  # being inferred from a ladder outcome three rungs away.
  def rules_rung(consent)
    Lain::Approval::Escalation::Rules.new(
      rules: consent.rules, tools:, faults: Lain::Approval::Escalation::Faults.new(journal)
    )
  end

  def ladder_over(consent, queue) = Lain::Approval::Escalation.for(queue:, tools:, journal:, rules: consent.rules)

  describe "an unconsented root" do
    it "ignores its approval table, so the rules rung abstains" do
      with_root do |root, paths|
        write_config(root, allows_bash)

        ruling = rules_rung(consent_for(root, paths:)).call(effect, nil)

        expect(ruling).to be_abstain
        expect(ruling).not_to be_fault
      end
    end

    it "lets the call reach the queue, which is what an abstention is for", :seam do
      with_root do |root, paths|
        write_config(root, allows_bash)
        queue = parked

        ladder_over(consent_for(root, paths:), queue).call(effect, nil)

        expect(queue.asked).to eq(["tu_1"])
      end
    end

    # The count is the line's substance: it is what tells a user how much
    # authority the file is asking for. So the fixture carries TWO allows and
    # one deny -- one entry would let `count: 1` and `count: answers.deny.length`
    # both pass while saying something false about any other file.
    it "reports the ignored table once, naming the file and how many shapes it asks for" do
      with_root do |root, paths|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "bash"
          input = { command = "id" }

          [[approval.allow]]
          tool = "bash"
          input = { command = "whoami" }

          [[approval.deny]]
          tool = "bash"
          input = { command = "rm -rf /" }
        TOML
        said = notices

        consent_for(root, paths:, notice: said)

        expect(said.count).to eq(1)
        expect(said.first).to include(File.join(root, ".lain", "config.toml"), "2 call shape")
      end
    end

    # T6 landed, so there IS a flag to name. `--root` ALONE, because
    # `exe/lain`'s `project_override` defaults `--cwd` to the root -- the
    # remedy must be the command the binary actually needs, not the longer one.
    it "names the remedy, as one flag over this root" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        said = notices

        consent_for(root, paths:, notice: said)

        expect(said.first).to include("lain chat --root #{root}")
        expect(said.first).not_to include("--cwd")
      end
    end

    it "shell-escapes the root, so the remedy survives a path with a space in it" do
      Dir.mktmpdir do |tmp|
        home = File.realpath(tmp)
        root = File.realpath(File.join(home, "my repo").tap { |dir| FileUtils.mkdir_p(dir) })
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(home, "state"), "HOME" => home })
        write_config(root, allows_bash)
        said = notices

        described_class.for(project: walked_project(root, paths:, home:), paths:, notice: said)

        expect(said.first).to include("--root #{Shellwords.escape(root)}")
        expect(said.first).not_to include("--root #{root} ")
      end
    end

    it "says nothing when the table grants nothing, so an ordinary project sees no startup line" do
      with_root do |root, paths|
        said = notices

        consent_for(root, paths:, notice: said)

        expect(said.to_a).to be_empty
      end
    end
  end

  # T6's flag, driven through the REAL resolver on the exact call `exe/lain`'s
  # `resolved_project` makes. These three examples exist because the fixtures
  # below used to ASSERT the rung they meant to test: they passed
  # `detected_by: :flag` to a `Project` constructor and `cwd: root` beside it,
  # which is what T6 later made the default -- so ACs 2 and 3 were right by
  # coincidence. Now the resolver has to say `:flag`, and the coincidence is an
  # assertion.
  describe "the rung a flag actually produces" do
    it "answers :flag for a named root, which is what consent reads" do
      with_root do |root, paths|
        expect(flagged_project(root, paths:).detected_by).to eq(described_class::FLAG)
      end
    end

    it "puts cwd at the root when only the root is named, which is what --root alone sends" do
      with_root do |root, paths|
        project = flagged_project(root, paths:)

        expect([project.root, project.cwd]).to eq([root, root])
      end
    end

    # The same directory WITHOUT the flag: a walked project never answers
    # `:flag`, so nothing about the ordinary invocation can consent by accident.
    it "answers a walked rung when no flag names the root" do
      with_root do |root, paths|
        write_config(root, allows_bash)

        expect(walked_project(root, paths:).detected_by).not_to eq(described_class::FLAG)
      end
    end
  end

  describe "an explicitly named root" do
    it "is consented by that fact, so the rules rung allows the matching call" do
      with_root do |root, paths|
        write_config(root, allows_bash)

        ruling = rules_rung(consent_for(root, paths:, flag: true)).call(effect, nil)

        expect(ruling).to be_allow
        expect(ruling.reason).to include("[[approval.allow]]")
      end
    end

    it "never reaches the queue, because a deterministic rung already answered", :seam do
      with_root do |root, paths|
        write_config(root, allows_bash)
        queue = parked

        allowed = ladder_over(consent_for(root, paths:, flag: true), queue).call(effect, nil)

        expect(allowed).to be(true)
        expect(queue.asked).to be_empty
      end
    end

    it "says nothing at startup, because nothing was ignored" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        said = notices

        consent_for(root, paths:, flag: true, notice: said)

        expect(said.to_a).to be_empty
      end
    end

    it "asks no human, because naming the directory IS the intent" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        confirm = asked(false)

        consent = consent_for(root, paths:, flag: true, confirm:)

        expect(consent).to be_granted
        expect(confirm.projects).to be_empty
      end
    end
  end

  describe "consent across sessions" do
    it "survives into a later session that names no root" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        consent_for(root, paths:, flag: true)

        later = consent_for(root, paths:)

        expect(later).to be_granted
        expect(rules_rung(later).call(effect, nil)).to be_allow
      end
    end

    it "is keyed per root, so a twin carrying the same config is still unconsented" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        twin = File.realpath(File.join(File.dirname(root), "twin").tap { |dir| FileUtils.mkdir_p(dir) })
        write_config(twin, allows_bash)
        consent_for(root, paths:, flag: true)

        expect(consent_for(twin, paths:)).not_to be_granted
        expect(rules_rung(consent_for(twin, paths:)).call(effect, nil)).to be_abstain
      end
    end

    it "records the root beside its hash, so the state directory reads to a human" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        consent_for(root, paths:, flag: true)

        expect(File.read(mark_path(root, paths))).to eq("#{root}\n")
      end
    end

    # N5: the keying claim, which no example made until this one -- every other
    # project here has `cwd == root`, so reading the mark off the CWD would
    # have been indistinguishable from reading it off the root.
    it "keys on the root, so a session started in a subdirectory inherits the decision" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        sub = File.join(root, "services", "ingest")
        FileUtils.mkdir_p(sub)
        consent_for(root, paths:, flag: true)

        expect(consent_for(root, paths:, cwd: sub)).to be_granted
      end
    end
  end

  # S1: a `--root` is an intent about THIS session. It must not become a
  # standing decision about a repository that has nothing to grant yet, because
  # a consented root is silent by design -- so the table added later would be
  # honoured with nobody asked and no line printed.
  describe "a root with nothing to grant" do
    it "records no mark, even when it is named explicitly" do
      with_root do |root, paths|
        consent_for(root, paths:, flag: true)

        expect(File.exist?(mark_path(root, paths))).to be(false)
      end
    end

    it "records no mark when the config carries only refusals" do
      with_root do |root, paths|
        write_config(root, "[[approval.deny_tool]]\ntool = \"bash\"\n")

        consent_for(root, paths:, flag: true)

        expect(File.exist?(mark_path(root, paths))).to be(false)
      end
    end

    it "still asks about an allow table added to it later, rather than honouring it in silence" do
      with_root do |root, paths|
        consent_for(root, paths:, flag: true)
        write_config(root, allows_bash)
        said = notices

        later = consent_for(root, paths:, notice: said)

        expect(later).not_to be_granted
        expect(rules_rung(later).call(effect, nil)).to be_abstain
        expect(said.count).to eq(1)
      end
    end
  end

  # S2/S3: presence is not the test, and the key is not a filename. Each of
  # these EXISTS at the mark's path and none of them is a grant.
  describe "a mark that is not one" do
    def prepare(root, paths)
      write_config(root, allows_bash)
      path = mark_path(root, paths)
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    it "does not grant from a directory sitting where the mark belongs" do
      with_root do |root, paths|
        FileUtils.mkdir_p(prepare(root, paths))

        expect(consent_for(root, paths:)).not_to be_granted
      end
    end

    it "does not grant from a dangling symlink" do
      with_root do |root, paths|
        File.symlink(File.join(root, "nowhere"), prepare(root, paths))

        expect(consent_for(root, paths:)).not_to be_granted
      end
    end

    it "does not grant from a truncated or corrupt mark" do
      with_root do |root, paths|
        File.write(prepare(root, paths), "")

        expect(consent_for(root, paths:)).not_to be_granted
      end
    end

    it "does not grant from a mark naming a DIFFERENT root, which is what a digest collision looks like" do
      with_root do |root, paths|
        File.write(prepare(root, paths), "/somewhere/else\n")

        expect(consent_for(root, paths:)).not_to be_granted
      end
    end

    it "keys on the full digest, not a truncation of it" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        consent_for(root, paths:, flag: true)

        recorded = Dir.children(File.join(paths.state_home, "consent"))

        expect(recorded).to eq([Digest::SHA256.hexdigest(root)])
        expect(recorded.first.length).to eq(64)
      end
    end

    it "writes through a symlink rather than replacing it, so a managed state home survives" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        real = File.join(File.dirname(root), "elsewhere")
        File.write(real, "")
        path = mark_path(root, paths)
        FileUtils.mkdir_p(File.dirname(path))
        File.symlink(real, path)

        consent_for(root, paths:, flag: true)

        expect(File.symlink?(path)).to be(true)
        expect(File.read(real)).to eq("#{root}\n")
      end
    end
  end

  describe "the first-run confirmation" do
    it "consents when a human says yes, and the answer sticks" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        confirm = asked(true)

        expect(consent_for(root, paths:, confirm:)).to be_granted
        expect(confirm.projects.map(&:root)).to eq([root])
        expect(consent_for(root, paths:)).to be_granted
      end
    end

    it "refuses when nobody can be asked, and records nothing to ask past" do
      with_root do |root, paths|
        write_config(root, allows_bash)

        consent = consent_for(root, paths:)

        expect(consent).not_to be_granted
        expect(File.exist?(mark_path(root, paths))).to be(false)
      end
    end

    # S4: a closed stream is the ORDINARY headless shape, and the escalation
    # trigger says an unsurfaceable prompt answers "not consented". It must not
    # be able to answer "crash" instead.
    it "refuses, and does not take the chat down, when the confirmer itself raises" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        exploding = ->(_project) { raise IOError, "closed stream" }
        said = notices

        consent = consent_for(root, paths:, confirm: exploding, notice: said)

        expect(consent).not_to be_granted
        expect(File.exist?(mark_path(root, paths))).to be(false)
        # Not swallowed in silence: the table it could not ask about is named.
        expect(said.count).to eq(1)
      end
    end

    it "treats a truthy non-Boolean as a refusal, because only yes is consent" do
      with_root do |root, paths|
        write_config(root, allows_bash)

        expect(consent_for(root, paths:, confirm: asked("y"))).not_to be_granted
      end
    end

    it "asks nobody when the table grants nothing, so a prompt is rare by construction" do
      with_root do |root, paths|
        write_config(root, <<~TOML)
          [[approval.deny_tool]]
          tool = "bash"
        TOML
        confirm = asked(true)

        consent_for(root, paths:, confirm:)

        expect(confirm.projects).to be_empty
      end
    end
  end

  describe "the asymmetry: config may restrict without consent" do
    it "honors a tool-wide refusal from an unconsented root, because a refusal grants nothing" do
      with_root do |root, paths|
        write_config(root, <<~TOML)
          [[approval.deny_tool]]
          tool = "bash"
        TOML

        ruling = rules_rung(consent_for(root, paths:)).call(effect, nil)

        expect(ruling).to be_deny
        expect(ruling.reason).to include("[[approval.deny_tool]]")
      end
    end

    it "honors a shaped refusal from an unconsented root too" do
      with_root do |root, paths|
        write_config(root, <<~TOML)
          [[approval.deny]]
          tool = "bash"
          input = { command = "rm -rf /tmp/scratch" }
        TOML

        expect(rules_rung(consent_for(root, paths:)).call(effect, nil)).to be_deny
      end
    end

    it "drops the allow and keeps the deny when an unconsented root writes both" do
      with_root do |root, paths|
        write_config(root, "#{allows_bash}\n[[approval.deny_tool]]\ntool = \"read_file\"\n")

        consent = consent_for(root, paths:)

        expect(consent.remembered.decide(call_for(bash, { "command" => "rm -rf /tmp/scratch" }))).to be_nil
        expect(consent.remembered.decide(call_for(Lain::Tools::ReadFile.new, { "path" => "README.md" }))).to be_deny
      end
    end

    it "denies a shape a consented root both allows and denies" do
      with_root do |root, paths|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "bash"
          input = { command = "rm -rf /tmp/scratch" }

          [[approval.deny]]
          tool = "bash"
          input = { command = "rm -rf /tmp/scratch" }
        TOML

        expect(rules_rung(consent_for(root, paths:, flag: true)).call(effect, nil)).to be_deny
      end
    end
  end

  # MA-1 (`approval/rule.rb`): the hazard consent must not open. A per-root yes
  # is only safe while what it turns on matches WHOLE call shapes, so these are
  # the examples that would catch a wiring which widened the match.
  describe "what a consented root does NOT grant" do
    def allowed?(consent, input)
      rules_rung(consent).call(Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:), nil).allow?
    end

    it "does not allow a command the entry is merely a prefix of" do
      with_root do |root, paths|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "bash"
          input = { command = "git status" }
        TOML
        consent = consent_for(root, paths:, flag: true)

        expect(allowed?(consent, { "command" => "git status" })).to be(true)
        expect(allowed?(consent, { "command" => "git status; rm -rf /" })).to be(false)
        expect(allowed?(consent, { "command" => "git -c core.fsmonitor=id status" })).to be(false)
      end
    end

    it "does not allow the same command carrying a field the entry never named" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        consent = consent_for(root, paths:, flag: true)

        expect(allowed?(consent, { "command" => "rm -rf /tmp/scratch", "timeout" => 5 })).to be(false)
      end
    end

    it "does not carry to another tool" do
      with_root do |root, paths|
        write_config(root, allows_bash)
        consent = consent_for(root, paths:, flag: true)
        read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => "README.md" })

        expect(rules_rung(consent).call(read, nil)).to be_abstain
      end
    end
  end

  describe "a project with nothing to say" do
    it "wires no rules at all when there is no config file, so the rung is as it was" do
      with_root do |root, paths|
        consent = consent_for(root, paths:)

        expect(consent.rules).to be_empty
        expect(rules_rung(consent).call(effect, nil)).to be_abstain
      end
    end

    it "wires no rules from a consented root whose config carries no approval table" do
      with_root do |root, paths|
        write_config(root, "[epics]\nhome = \"repo\"\n")

        expect(consent_for(root, paths:, flag: true).rules).to be_empty
      end
    end
  end

  describe "a config that will not load" do
    it "does not prevent launch, and reports the problem once" do
      with_root do |root, paths|
        write_config(root, "[[approval.allow]]\ntool = \"bash\"\ninput = { command = [\"nope\"] }\n")
        said = notices

        consent = consent_for(root, paths:, flag: true, notice: said)

        expect(consent.rules).to be_empty
        expect(consent).not_to be_granted
        expect(said.count).to eq(1)
        expect(said.first).to include("not in force")
      end
    end

    it "grants nothing from an unparseable file, even with an explicit root" do
      with_root do |root, paths|
        write_config(root, "this is not toml <<<")

        expect(rules_rung(consent_for(root, paths:, flag: true)).call(effect, nil)).to be_abstain
      end
    end

    it "stays silent about a broken config when nobody passed a notice" do
      with_root do |root, paths|
        write_config(root, "this is not toml <<<")

        expect { consent_for(root, paths:, flag: true) }.not_to raise_error
      end
    end

    # WHICH layer refuses depends on the rung, and driving the REAL resolver is
    # what surfaced it -- a hand-built Project hid this entirely.
    #
    # `--root` short-circuits rung 1, so nothing opens the file until this class
    # does, and this class swallows it. A WALKED project reads the same file at
    # rung 2 first ({Resolver::Declarations#declared_root}, looking for `root =`),
    # so an unparseable config refuses THERE -- upstream of consent, rendered by
    # `exe/lain` as one line. Consent is total either way; it is simply not the
    # only thing that opens that file, and AC 8's "does not prevent launch"
    # holds for a malformed `[approval]` TABLE rather than for unparseable TOML.
    it "is refused by the resolver, not by consent, when a WALKED project's config will not parse" do
      with_root do |root, paths|
        write_config(root, "this is not toml <<<")

        expect { walked_project(root, paths:) }.to raise_error(Lain::Config::Malformed)
      end
    end
  end

  describe "the value itself" do
    it "is frozen, because a rule rides wherever a ladder rides" do
      with_root do |root, paths|
        expect(consent_for(root, paths:)).to be_frozen
      end
    end

    it "keeps its default state home out of an example's way" do
      expect(described_class::Unattended.new.call(nil)).to be(false)
    end

    # `new` is a public door, so the strict coercion has to hold THERE too and
    # not merely at the one caller that happens to pass Booleans today: a
    # truthy non-Boolean is not consent, whichever door it arrives through.
    it "reads a truthy non-Boolean as unconsented, and honours no allow table for it" do
      answers = Lain::Config::Answers.new(allow: [{ "tool" => "bash", "input" => { "command" => "id" } }])

      consent = described_class.new(granted: "yes", answers:)

      expect(consent).not_to be_granted
      expect(consent.rules).to be_empty
    end
  end

  def call_for(tool, input) = Lain::Approval::Rule::Call.for(tool:, input:)
end
