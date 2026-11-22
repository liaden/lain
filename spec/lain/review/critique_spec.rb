# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The role spawn a critique asks for its children, recorded: which checkout
# each child was lent, and the (role, mode, prompt) it was spawned with. Its
# `seam` answers the one member a critique reads -- the child's context, for
# the model whose window it sizes against and the response it reserves.
class CritiqueSpecSpawn
  Seam = Struct.new(:context_factory, :provider)

  def initialize(context: Lain::Context.new(model: "critic-model", max_tokens: 512), fails: {},
                 provider: Lain::Provider::Mock.new)
    @context = context
    @provider = provider
    @fails = fails
    @calls = []
  end

  attr_reader :calls

  def seam = Seam.new(-> { @context }, @provider)

  def within(worker_env) = Lent.new(self, worker_env)

  def spawned(worker_env, role, mode, prompt, model)
    @calls << { worker_env:, role:, mode:, prompt:, model: }
    ordinal = @calls.size
    raise @fails.fetch(ordinal) if @fails.key?(ordinal)

    Lain::Tool::Result.ok("findings from child #{ordinal}")
  end

  # One lent spawn, so a call records the checkout it was made inside.
  class Lent
    def initialize(spawn, worker_env)
      @spawn = spawn
      @worker_env = worker_env
    end

    def call(role, mode, prompt, model: Lain::Tools::Subagent::ModelChoice::Null)
      @spawn.spawned(@worker_env, role, mode, prompt, model)
    end
  end
end

# The checkout a critique reads through, recorded: which revision was held, and
# whether the hold ended. The real {Lain::Review::Critique::Checkouts} is driven
# against git in its own group below.
class CritiqueSpecCheckouts
  def initialize
    @held = []
    @ended = 0
  end

  attr_reader :held, :ended

  def env = Lain::WorkerEnv.new(cwd: "/checkout/of/head", env: {})

  def hold(revision)
    @held << revision
    yield env
  ensure
    @ended += 1 unless @held.empty?
  end
end

RSpec.describe Lain::Review::Critique do
  def file_section(path, body_lines, width: 40)
    body = Array.new(body_lines) { |i| "#{i.even? ? "-" : "+"}#{format("%<i>05d", i:)}".ljust(width, "x") }
    <<~HEAD + "#{body.join("\n")}\n"
      diff --git a/#{path} b/#{path}
      index 1111111..2222222 100644
      --- a/#{path}
      +++ b/#{path}
      @@ -1,#{body_lines} +1,#{body_lines} @@
    HEAD
  end

  def commit_record(sha:, paths:)
    numstat = paths.map { |path| Lain::Review::Source::FileStat.new(path: -path, added: 1, deleted: 1) }
    Lain::Review::Source::Commit.new(sha:, subject: "s #{sha}", body: "", numstat: numstat.freeze)
  end

  # `files` is `{path => body_lines}`, and `commits` splits those paths in
  # order, so a fixture says how the walk groups them.
  def changeset_of(files, commits: 1, width: 40, widths: {})
    diff = files.map { |path, lines| file_section(path, lines, width: widths.fetch(path, width)) }.join
    per = [(files.size / commits.to_f).ceil, 1].max
    records = files.keys.each_slice(per).with_index.map { |slice, i| commit_record(sha: "c#{i}", paths: slice) }
    Lain::Review::Changeset.new(source: source_over(diff, records))
  end

  def source_over(diff, records)
    DiffSource.over(instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, commits: records.freeze,
                                                                       base_ref: "b" * 40, head_ref: "h" * 40))
  end

  def many_files(count, lines) = Array.new(count) { |i| [format("lib/f%03d.rb", i), lines] }.to_h

  def window(tokens, provenance: Lain::ContextWindow::PROBED)
    Lain::CLI::Backend::WindowBook::Served.new(model: "critic-model", window_tokens: tokens, provenance:)
  end

  let(:spawn) { CritiqueSpecSpawn.new }
  let(:checkouts) { CritiqueSpecCheckouts.new }
  let(:journal) { [] }

  around do |example|
    Dir.mktmpdir("lain-critique-slots") do |root|
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  # A held changeset as the critique reads one, which is how the skill dispatch hands it over.
  def diffed(changeset) = described_class::Diff.new(changeset)

  def critique(changeset, window: window(32_768), instructions: "# critique\nReview it.", spawn: self.spawn)
    described_class.new(subject: diffed(changeset), spawn:, window:, checkouts:, journal:, slots: @slots,
                        instructions:)
  end

  # What a child's own request budget raises when its provider refuses the
  # whole prompt: the harness's words, with the server's body demoted to the
  # cause where no finding can pick it up.
  def over_window
    Lain::Middleware::RequestBudget::OverWindow.new(
      "not answered: ollama refused the diff_critic child's task at 41000 tokens against the " \
      "32768-token context it loaded, so no model saw it",
      moves: -> { ". Hand it less to read." }, prompt_tokens: 41_000, window_tokens: 32_768, source: "ollama",
      model: "critic-model"
    )
  end

  # What the child is sent beyond its prompt, in the estimate's own unit: the
  # role's prelude, the response it may write, and the reserve for the tool
  # schemas and message framing.
  def request_estimate(prompt, max_tokens: 512)
    prelude = Lain::Role::Catalog.fetch(described_class::ROLE).prelude(slots: @slots)
    described_class.tokens(prompt) + described_class.tokens(prelude) + max_tokens +
      described_class::SCHEMA_RESERVE_TOKENS
  end

  describe "a held changeset critiqued one chunk per child" do
    let(:changeset) { changeset_of({ "lib/a.rb" => 4, "lib/b.rb" => 4 }, commits: 2) }

    it "spawns the diff critic over a fresh root once per chunk, inside the checkout of the reviewed head" do
      critique(changeset).call

      expect(checkouts.held).to eq(["h" * 40])
      expect(spawn.calls.map { |call| [call[:role], call[:mode], call[:worker_env].cwd] })
        .to eq([[:diff_critic, :fresh, "/checkout/of/head"]] * 2)
    end

    it "hands each child the instructions and only its own chunk's hunks" do
      critique(changeset, instructions: "# critique\nReview it.").call

      first, second = spawn.calls.map { |call| call[:prompt] }
      expect(first).to include("# critique\nReview it.", "lib/a.rb", "@@ -1,4 +1,4 @@", "+00001")
      expect(first).not_to include("lib/b.rb")
      expect(second).to include("lib/b.rb")
      expect(second).not_to include("lib/a.rb")
    end

    it "merges the findings in chunk order, naming every chunk" do
      findings = critique(changeset).call

      expect(findings).to match(
        %r{chunk 1 of 2.*lib/a\.rb.*findings from child 1.*chunk 2 of 2.*lib/b\.rb.*findings from child 2}m
      )
    end

    it "journals one record per chunk, carrying where it sits and what came back" do
      critique(changeset).call

      expect(journal.map { |record| [record.class, record.ordinal, record.count, record.paths, record.outcome] })
        .to eq([[described_class::CritiqueChunk, 1, 2, ["lib/a.rb"], "answered"],
                [described_class::CritiqueChunk, 2, 2, ["lib/b.rb"], "answered"]])
      expect(journal.map(&:text)).to eq(["findings from child 1", "findings from child 2"])
      expect(journal.map(&:head_ref).uniq).to eq(["h" * 40])
      expect(journal.map(&:role).uniq).to eq(["diff_critic"])
    end

    it "journals under the type its constant pins" do
      critique(changeset).call

      expect(journal.map { |record| record.to_journal["type"] }.uniq)
        .to eq([described_class::CritiqueChunk::JOURNAL_TYPE])
    end

    it "keeps critiquing the other chunks when one child fails, and says which one did" do
      failing = CritiqueSpecSpawn.new(fails: { 1 => Lain::Error.new("the provider fell over") })
      findings = described_class.new(subject: diffed(changeset), spawn: failing, window: window(32_768),
                                     checkouts:, journal:, slots: @slots, instructions: "# critique").call

      expect(failing.calls.size).to eq(2)
      expect(findings).to include("the provider fell over", "findings from child 2")
      expect(journal.map(&:outcome)).to eq(%w[failed answered])
      expect(checkouts.ended).to eq(1)
    end

    it "records a quota error as a failed chunk, worded as an actor words it" do
      quota = Lain::Provider::HTTP::QuotaError.new("limit hit")
      failing = CritiqueSpecSpawn.new(fails: { 1 => quota })
      described_class.new(subject: diffed(changeset), spawn: failing, window: window(32_768), checkouts:, journal:,
                          slots: @slots, instructions: "# critique").call

      expect(journal.first.outcome).to eq("failed")
      expect(journal.first.text).to include(Lain::Tools::Subagent::Actor.cause(quota))
    end

    it "words another provider failure as its class and message" do
      failing = CritiqueSpecSpawn.new(fails: { 1 => Lain::Error.new("the provider fell over") })
      described_class.new(subject: diffed(changeset), spawn: failing, window: window(32_768), checkouts:, journal:,
                          slots: @slots, instructions: "# critique").call

      expect(journal.first.text).to end_with("Lain::Error: the provider fell over")
    end

    it "still loads an old record whose outcome is refused" do
      old = described_class::CritiqueChunk.new(head_ref: "h" * 40, ordinal: 1, count: 1, critic: 1, model: nil,
                                               label: "a", paths: ["a"], role: "diff_critic", brief_key: "k",
                                               outcome: "refused", text: "chunk 1 of 1 (a) was not critiqued: x")
      expect(old.outcome).to eq("refused")
    end

    # The failure's words ARE the finding, so the finding has to read as one.
    # The RECORD names the chunk, because it travels on its own with no heading
    # above it; the merged prose does not, because {Brief#heading} said it one
    # line earlier.
    it "names the chunk in a refused record's text, and once only in the merged prose" do
      failing = CritiqueSpecSpawn.new(fails: { 1 => Lain::Error.new("the provider fell over") })
      findings = described_class.new(subject: diffed(changeset), spawn: failing, window: window(32_768),
                                     checkouts:, journal:, slots: @slots, instructions: "# critique").call

      expect(journal.first.text).to start_with("chunk 1 of 2")
      expect(journal.first.text).to include("the provider fell over")
      expect(findings.scan("chunk 1 of 2").size).to eq(1)
      expect(findings).to include("the provider fell over")
    end

    # A failure with no words is still a finding, and the one blank-answer
    # sentence serves the raise path as well as the answer path.
    it "says the critic came back with nothing when a failure carries no message" do
      failing = CritiqueSpecSpawn.new(fails: { 1 => Lain::Error.new("  ") })
      described_class.new(subject: diffed(changeset), spawn: failing, window: window(32_768), checkouts:, journal:,
                          slots: @slots, instructions: "# critique").call

      expect(journal.first.outcome).to eq("failed")
      expect(journal.first.text).to eq("chunk 1 of 2 (#{journal.first.label}) was not critiqued: " \
                                       "#{described_class::NOTHING_SAID}")
    end

    # The child's own budget refuses an over-window prompt in words. What must
    # not survive into a finding is the server's JSON body, which names neither
    # the chunk nor anything a human can do.
    it "carries the child's worded over-window refusal, and no provider payload" do
      failing = CritiqueSpecSpawn.new(fails: { 1 => over_window })
      findings = described_class.new(subject: diffed(changeset), spawn: failing, window: window(32_768),
                                     checkouts:, journal:, slots: @slots, instructions: "# critique").call

      expect(journal.first.text).to start_with("chunk 1 of 2")
      expect(journal.first.text).to include("32768-token context")
      expect(findings).not_to include("{")
      expect(findings).to include("findings from child 2")
    end
  end

  describe "a large changeset is critiqued in chunks, not truncated" do
    let(:changeset) { changeset_of(many_files(70, 100)) }

    it "spawns one child per chunk, and together the chunks carry every file" do
      critique(changeset).call

      prompts = spawn.calls.map { |call| call[:prompt] }
      expect(prompts.size).to be > 1
      expect(many_files(70, 100).keys).to all(satisfy { |path| prompts.one? { |prompt| prompt.include?(path) } })
    end

    it "names every chunk in the merged findings" do
      findings = critique(changeset).call

      count = spawn.calls.size
      labels = (1..count).map { |ordinal| "chunk #{ordinal} of #{count}" }
      expect(labels.reject { |label| findings.include?(label) }).to be_empty
    end
  end

  describe "chunks fit the child's window" do
    it "keeps every child request under a 32768-token window across 7,000 changed lines" do
      critique(changeset_of(many_files(70, 100))).call

      expect(spawn.calls.map { |call| request_estimate(call[:prompt]) }).to all(be <= 32_768)
    end

    it "sizes to the window it is given rather than to a fixed line count" do
      critique(changeset_of(many_files(70, 100)), window: window(65_536)).call
      wide = spawn.calls.size
      spawn.calls.clear

      critique(changeset_of(many_files(70, 100)), window: window(16_384)).call

      expect(spawn.calls.size).to be > wide
    end

    # The line ceiling is derived at the changeset's MEAN bytes per line, so a
    # chunk of the wide files packs past the window at that ceiling; what is
    # asserted is that the packing measured the chunks rather than trusting it.
    it "keeps chunks under the window when some files' lines are far wider than the rest" do
      files = many_files(60, 100)
      wide = files.keys.last(10).to_h { |path| [path, 400] }
      critique(changeset_of(files, widths: wide)).call

      expect(spawn.calls.map { |call| request_estimate(call[:prompt]) }).to all(be <= 32_768)
    end
  end

  # A child is told it may read around a hunk, and every read's result rides
  # its NEXT request. A chunk packed to the brim leaves that request no room, so
  # the chunk's content may take only half of what the instructions and the
  # response reserve leave -- and diff text is estimated at three bytes a token,
  # where real tokenizers land on code, rather than four.
  describe "chunks leave room for the child's reads" do
    def diff_tokens(text) = (Lain::Canonical.dump(text).bytesize + 2) / 3

    it "keeps every first request, estimated at three bytes a token, under 60% of the window" do
      critique(changeset_of(many_files(70, 100))).call

      prelude = Lain::Role::Catalog.fetch(described_class::ROLE).prelude(slots: @slots)
      estimates = spawn.calls.map { |call| diff_tokens(call[:prompt]) + diff_tokens(prelude) + 512 }
      expect(estimates.size).to be > 1
      expect(estimates).to all(be < 0.6 * 32_768)
    end
  end

  describe "a response reserve that leaves no room" do
    it "refuses naming the reserve and the window before any file is blamed" do
      big = CritiqueSpecSpawn.new(context: Lain::Context.new(model: "critic-model", max_tokens: 16_384))

      expect { critique(changeset_of({ "lib/a.rb" => 4 }), window: window(1_024), spawn: big).call }
        .to raise_error(described_class::Refused) { |error|
          # The reserve floor is a quarter of a small window, so 256 here, not half the window.
          expect(error.message).to include("256-token response reserve", "1024-token window")
          expect(error.message).not_to include("lib/a.rb")
        }
      expect(big.calls).to be_empty
      expect(checkouts.held).to be_empty
    end

    it "reserves 4,096, not the whole 16,384 cap, on a 32,768 window" do
      big = CritiqueSpecSpawn.new(context: Lain::Context.new(model: "critic-model", max_tokens: 16_384))

      critique(changeset_of({ "lib/a.rb" => 600 }), spawn: big).call

      expect(big.calls).not_to be_empty
    end
  end

  describe "a line-packed chunk over the window" do
    # One long file of short lines sets a line ceiling its wide-lined
    # neighbours pack far past. Nothing needs splitting; the chunker packs by
    # lines, and the refusal has to say that rather than blame a file.
    it "says the chunker packs by line count and cannot split a file, not that a file needs splitting" do
      files = { "lib/long.rb" => 800 }.merge(Array.new(40) { |i| [format("doc/w%02d.md", i), 20] }.to_h)
      widths = files.keys.drop(1).to_h { |path| [path, 900] }

      expect { critique(changeset_of(files, widths:)).call }.to raise_error(described_class::Refused) { |error|
        expect(error.message).to include("packs by line count", "cannot split a file")
        expect(error.message).not_to include("without splitting a file")
      }
      expect(spawn.calls).to be_empty
    end
  end

  describe "an empty round" do
    it "refuses a changeset with no file in it before cutting a checkout" do
      expect { critique(changeset_of({})).call }.to raise_error(described_class::Refused, /nothing/)
      expect(checkouts.held).to be_empty
    end
  end

  describe "what a child is told about where its reads land" do
    let(:prompts) do
      critique(changeset_of({ "lib/a.rb" => 4 })).call
      spawn.calls.map { |call| call[:prompt] }
    end

    it "says a relative path resolves in the checkout and an absolute path is not confined" do
      expect(prompts.first).to include("relative path", "absolute path")
      expect(prompts.first).not_to include("not anyone's working tree")
    end

    it "mentions other reviewers only when there are other chunks" do
      expect(prompts.first).not_to include("Other reviewers")
    end

    it "carries the same account in the role's persona" do
      persona = @slots.render_role(described_class::ROLE)

      expect(persona).to include("relative path", "absolute path")
      expect(persona).not_to include("not anyone's working tree")
    end
  end

  describe "a chunk that cannot fit refuses the critique before any spend" do
    let(:changeset) { changeset_of({ "lib/small.rb" => 10, "lib/huge.rb" => 3_700 }, width: 64) }

    it "spawns no child and holds no checkout" do
      expect { critique(changeset).call }.to raise_error(described_class::Refused)

      expect(spawn.calls).to be_empty
      expect(checkouts.held).to be_empty
    end

    it "names the file, its estimate and the window" do
      expect { critique(changeset).call }.to raise_error(described_class::Refused) { |error|
        estimate = error.message[/(\d+) tokens/, 1].to_i
        expect(error.message).to include("lib/huge.rb", "32768")
        expect(estimate).to be > 58_000
      }
    end
  end

  describe "a window nobody vouches for" do
    it "refuses by name before any spawn rather than sizing to a guess" do
      changeset = changeset_of({ "lib/a.rb" => 4 })

      expect { critique(changeset, window: window(32_768, provenance: Lain::ContextWindow::GUESSED)).call }
        .to raise_error(described_class::Refused, /critic-model is guessed.*--num-ctx.*published table/)
      expect(spawn.calls).to be_empty
      expect(checkouts.held).to be_empty
    end
  end

  describe "several critics reading each chunk" do
    let(:changeset) { changeset_of({ "lib/a.rb" => 4, "lib/b.rb" => 4 }, commits: 2) }

    def critics(count, **)
      described_class.new(subject: diffed(changeset), spawn:, window: window(32_768), checkouts:, journal:,
                          slots: @slots, instructions: "# critique", critics: count, **)
    end

    it "spawns each chunk's critics one at a time, chunk by chunk" do
      critics(3).call

      expect(spawn.calls.size).to eq(6)
      expect(spawn.calls.map do |call|
        call[:prompt][/chunk \d of 2/]
      end).to eq((["chunk 1 of 2"] * 3) + (["chunk 2 of 2"] * 3))
    end

    it "journals a record per critic, numbered 1 to 3 within the chunk" do
      critics(3).call

      expect(journal.map { |record| [record.ordinal, record.critic] })
        .to eq([[1, 1], [1, 2], [1, 3], [2, 1], [2, 2], [2, 3]])
    end

    it "lists each critic's findings under its own heading and says how many read the chunk" do
      findings = critics(3).call

      expect(findings.scan("3 critics read this chunk").size).to eq(2)
      expect(findings)
        .to match(/critic 1.*findings from child 1.*critic 2.*findings from child 2.*critic 3.*findings from child 3/m)
    end

    it "renders one critic exactly as before" do
      findings = critics(1).call

      expect(findings).to include("findings from child 1", "findings from child 2")
      expect(findings).not_to include("critics read this chunk", "### critic")
    end

    it "records the model that read each chunk, nil when none was named" do
      critique(changeset).call
      expect(journal.map(&:model)).to eq([nil, nil])
    end

    it "journals the default critic as number 1" do
      critique(changeset).call

      expect(journal.map(&:critic)).to eq([1, 1])
    end

    it "names a bad count through the one public check" do
      expect { described_class.refuse_bad_critics!(0) }.to raise_error(described_class::Refused, /got 0/)
      expect { described_class.refuse_bad_critics!("abc") }.to raise_error(described_class::Refused, /got "abc"/)
      expect(described_class.refuse_bad_critics!(described_class::MAX_CRITICS)).to be_nil
    end

    it "refuses a count below 1 before spawning" do
      expect { critics(0).call }.to raise_error(described_class::Refused, /critics/)
      expect(spawn.calls).to be_empty
    end

    it "refuses a count above the cap before spawning or cutting a checkout" do
      expect { critics(described_class::MAX_CRITICS + 1).call }
        .to raise_error(described_class::Refused, /critics.*#{described_class::MAX_CRITICS}/o)
      expect(spawn.calls).to be_empty
      expect(checkouts.held).to be_empty
    end

    it "accepts the cap itself" do
      critics(described_class::MAX_CRITICS).call

      expect(spawn.calls.size).to eq(described_class::MAX_CRITICS * 2)
    end
  end

  describe "a named reviewer model" do
    let(:changeset) { changeset_of({ "lib/a.rb" => 4 }) }
    let(:cross_lab_window) do
      Lain::CLI::Backend::WindowBook::Served.new(model: "glm-5.3:cloud", window_tokens: 16_384,
                                                 provenance: Lain::ContextWindow::PROBED)
    end

    def cross_lab(**)
      described_class.new(subject: diffed(changeset), spawn:, window: cross_lab_window, checkouts:, journal:,
                          slots: @slots, instructions: "# critique", model: "glm-5.3:cloud", **)
    end

    it "binds every spawned critic to that model" do
      cross_lab.call

      expect(spawn.calls.map { |call| call[:model].model }).to eq(["glm-5.3:cloud"])
    end

    it "records the named model on every chunk's record" do
      cross_lab(critics: 2).call

      expect(journal.map(&:model)).to eq(["glm-5.3:cloud"] * 2)
    end

    it "names the model that read the diff in the headline" do
      expect(cross_lab.call).to include("read on glm-5.3:cloud")
    end

    it "sizes chunks to the reviewer's window rather than the chat model's" do
      small = changeset_of(many_files(70, 100))
      reviewer = described_class.new(subject: diffed(small), spawn:, window: cross_lab_window, checkouts:, journal:,
                                     slots: @slots, instructions: "# critique", model: "glm-5.3:cloud")
      chat = described_class.new(subject: diffed(small), spawn:, window: window(131_072), checkouts:, journal:,
                                 slots: @slots, instructions: "# critique")

      reviewer.call
      reviewer_chunks = spawn.calls.size
      spawn.calls.clear
      chat.call

      expect(reviewer_chunks).to be > spawn.calls.size
    end

    it "refuses once, by name, before any checkout or spawn, a model the run's provider does not serve" do
      unserved = Struct.new(:serving) { def serves?(_model) = serving }
                       .new(Lain::Provider::Serving::NOT_SERVED)
      refusing = CritiqueSpecSpawn.new(provider: unserved)

      expect do
        described_class.new(subject: diffed(changeset), spawn: refusing, window: cross_lab_window,
                            checkouts:, journal:, slots: @slots, instructions: "# critique",
                            critics: 3, model: "glm-5.3:cloud").call
      end.to raise_error(Lain::Tools::Subagent::ModelChoice::Unserved, /glm-5\.3:cloud/)
      expect(refusing.calls).to be_empty
      expect(checkouts.held).to be_empty
      expect(journal).to be_empty
    end

    it "refuses by name a model the window book has never heard of" do
      blind = Struct.new(:x) { def resolve(model) = raise(Lain::ContextWindow::UnknownModel, "no #{model}") }.new(0)

      expect do
        described_class.new(subject: diffed(changeset), spawn:, window: blind, checkouts:, journal:, slots: @slots,
                            instructions: "# critique", model: "glm-5.3:cloud").call
      end.to raise_error(described_class::Refused, /glm-5\.3:cloud/)
      expect(spawn.calls).to be_empty
    end

    it "renders the reviewer's text exactly, markdown and odd whitespace included" do
      odd = "## Finding\n\n  * **bold**  and `code`\t\ttabbed\n\n\n    indented   \n"
      verbatim = Class.new(CritiqueSpecSpawn) do
        define_method(:spawned) { |*args| super(*args) && Lain::Tool::Result.ok(odd) }
      end.new

      findings = described_class.new(subject: diffed(changeset), spawn: verbatim, window: cross_lab_window,
                                     checkouts:, journal:, slots: @slots, instructions: "# critique",
                                     model: "glm-5.3:cloud").call

      expect(findings).to include(odd)
      expect(journal.first.text).to eq(odd)
    end

    it "refuses by name, before any spawn, a reviewer window nobody vouches for" do
      guessed = Lain::CLI::Backend::WindowBook::Served.new(model: "glm-5.3:cloud", window_tokens: 16_384,
                                                           provenance: Lain::ContextWindow::GUESSED)
      expect do
        described_class.new(subject: diffed(changeset), spawn:, window: guessed, checkouts:, journal:, slots: @slots,
                            instructions: "# critique", model: "glm-5.3:cloud").call
      end.to raise_error(described_class::Refused, /glm-5\.3:cloud/)
      expect(spawn.calls).to be_empty
    end
  end

  describe "a held round with no reviewed revision" do
    it "refuses a one-sided changeset, which has no head commit to check out" do
      changeset = instance_double(Lain::Review::Changeset, sides: Lain::Review::Source::HEAD_SIDE_ONLY,
                                                           head_ref: "c" * 64)

      expect { critique(changeset).call }.to raise_error(described_class::Refused, /revision/)
      expect(spawn.calls).to be_empty
    end
  end

  describe "the chunk record" do
    it "is deeply frozen" do
      record = described_class::CritiqueChunk.new(head_ref: "h" * 40, ordinal: 1, count: 1, label: "s c0",
                                                  paths: ["lib/a.rb"], role: :diff_critic, brief_key: "k",
                                                  outcome: "answered", text: "fine")

      expect(record).to be_deeply_frozen
    end

    it "refuses an outcome outside the closed set" do
      expect do
        described_class::CritiqueChunk.new(head_ref: "h" * 40, ordinal: 1, count: 1, label: "s c0",
                                           paths: ["lib/a.rb"], role: :diff_critic, brief_key: "k",
                                           outcome: "maybe", text: "fine")
      end.to raise_error(ArgumentError, /outcome/)
    end
  end

  describe Lain::Review::Critique::Patch, :seam do
    let(:token) { "sk-live-3333333333333333" }

    around do |example|
      Dir.mktmpdir("lain-critique-patch") do |root|
        @repo = File.join(File.realpath(root), "repo")
        FileUtils.cp_r(SeedRepo.at({ "README.md" => "seed\n" }), @repo)
        @base = SeedRepo.git(@repo, "rev-parse", "HEAD").stdout.strip
        SeedRepo.git(@repo, "checkout", "-q", "-b", "feature")
        File.write(File.join(@repo, "creds.rb"), "x = 1\nAPI_KEY=#{token}\n")
        SeedRepo.git(@repo, "add", "-A")
        SeedRepo.git(@repo, "commit", "-q", "-m", "add creds")
        example.run
      end
    end

    it "is built from the masked hunks, never the token" do
      source = Lain::Review::Source::LocalBranch.new(base: @base, repo_root: @repo)
      patch = described_class.of(Lain::Review::Changeset.new(source:).file("creds.rb"))

      expect(patch).to include("+API_KEY=<redacted:1>")
      expect(patch).not_to include(token)
    end
  end

  describe Lain::Review::Critique::Checkouts, :seam do
    def git(dir, *) = SeedRepo.git(dir, *).stdout

    around do |example|
      Dir.mktmpdir("lain-critique-checkouts") do |root|
        @root = File.realpath(root)
        @repo = File.join(@root, "repo")
        FileUtils.cp_r(SeedRepo.at({ "lib.rb" => "committed\n" }), @repo)
        File.write(File.join(@repo, "lib.rb"), "uncommitted\n")
        example.run
      end
    end

    def checkouts = described_class.new(repo_root: @repo, root: File.join(@root, "worktrees"))

    def worktrees = git(@repo, "worktree", "list", "--porcelain").scan(/^worktree /).size

    it "lends a checkout of the revision's committed bytes, never the working tree" do
      head = git(@repo, "rev-parse", "HEAD").strip
      read = checkouts.hold(head) { |worker_env| File.read(worker_env.resolve("lib.rb")) }

      expect(read).to eq("committed\n")
    end

    it "releases the checkout when the block returns" do
      checkouts.hold(git(@repo, "rev-parse", "HEAD").strip) { |_worker_env| :done }

      expect(worktrees).to eq(1)
    end

    it "releases the checkout when the block raises" do
      head = git(@repo, "rev-parse", "HEAD").strip

      expect { checkouts.hold(head) { |_worker_env| raise Interrupt } }.to raise_error(Interrupt)
      expect(worktrees).to eq(1)
    end
  end
end
