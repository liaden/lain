# frozen_string_literal: true

require "fileutils"
require "openssl"
require "stringio"
require "tmpdir"

# A surface whose own rendering blows up mid-park: `adjudicate` unwinds and
# never returns, so neither the approval branch nor the masking branch runs.
# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock), the shape
# `ApprovalSpecSupport` already uses.
module RedactSpecSupport
  # `outstanding:` is accepted and discarded, but cannot be renamed to the
  # unused-argument underscore: it is a KEYWORD, so the name is the duck.
  class RaisingQueue
    def adjudicate(_effect, _context, outstanding: nil) # rubocop:disable Lint/UnusedMethodArgument
      raise IOError, "surface died"
    end
  end

  # A journal that refuses one kind of entry and keeps everything else, so the
  # failure record a refused write degrades into can be read back.
  class RefusingJournal
    def initialize(entries, refuses:)
      @entries = entries
      @refuses = refuses
    end

    def <<(entry)
      raise IOError, "journal closed" if entry.is_a?(@refuses)

      @entries << entry
    end
  end

  # A queue that RETURNS -- so a guard gated on `adjudicate` having returned
  # would call the read decided -- but whose settled pending cannot answer.
  # This is the case that separates "the call came back" from "a verdict was
  # reached", and only the second is safe to skip the mask on.
  class BrokenVerdict
    def adjudicate(_effect, _context, outstanding: nil) # rubocop:disable Lint/UnusedMethodArgument
      Object.new.tap { |verdict| def verdict.approved? = raise(NoMethodError, "not a pending") }
    end
  end
end

# The read side of the secret boundary: unreleased regions are masked out of a
# `read_file` result on the way OUT of the tool phase, so bytes nobody agreed to
# send never exist above the middleware -- never in an Event, never in a digest,
# never in the prompt-cache prefix.
#
# Almost every example drives the REAL {Lain::Tools::ReadFile} as the downstream
# app, over a real file, against a real Session, Ledger and Queue. That is not
# thoroughness for its own sake: the read-set claims below ("a masked read does
# not satisfy the edit contract") are only true if ReadFile's own
# `record_read` -- which runs BELOW this middleware and records a COMPLETE read
# -- is accounted for. A spec that drove a bare session with no ReadFile under
# it would go green while production stayed broken, which is exactly the shape
# this chunk keeps finding.
RSpec.describe Lain::Middleware::RedactSecretReads, :seam do
  subject(:middleware) { described_class.new(ledger:, queue:, journal:) }

  # Literal, never sliced from the detector's own tables: a fixture built out of
  # the constant it is meant to pin cannot fail when that constant is wrong.
  let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
  let(:one_secret) { "API_KEY=#{api_key}\n" }
  let(:dotenv) do
    "API_KEY=#{api_key}\n" \
      "DATABASE_PASSWORD=hunter2SecretValue\n" \
      "SESSION_SECRET=correct-horse-battery-staple\n"
  end
  let(:ordinary) { "x = 1\nDEBUG = true\nNote: this is important\n" }

  let(:dir) { @dir }
  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:journal_io) { StringIO.new }
  let(:queue_journal) { Lain::Journal.new(io: journal_io) }
  # 0.1s, so "a surface that never answers" costs the suite a tenth of a second
  # rather than the queue's five-minute human window. 0.01 flaked about 1 run
  # in 50 under a loaded box; this buys ten times the margin for the same
  # apparent speed, since the whole file spends well under a second here.
  let(:queue) { Lain::Approval::Queue.new(journal: queue_journal, timeout: 0.1) }
  let(:journal) { [] }
  let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {})) }

  around do |example|
    Dir.mktmpdir { |made| @dir = made and example.run }
  end

  def write(name, content)
    File.join(dir, name).tap { |path| File.write(path, content) }
  end

  def effect(path, name: "read_file", tool_use_id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id:, name:, input: { "path" => path })
  end

  # Through a real Stack, so the Env wrapping production does is exercised
  # rather than a bare Hash that happens to answer the same messages.
  def stack = Lain::Middleware::Stack.new([middleware])

  # The downstream app IS the real tool, so its `record_read` lands below this
  # middleware exactly as it does in a live dispatch.
  def dispatch(effect, subject_stack: stack, tool: Lain::Tools::ReadFile.new)
    subject_stack.call({ effect:, context: session }) do |inner|
      invocation = Lain::Tool::Invocation.new(tool_use_id: inner.fetch(:effect).tool_use_id,
                                              context: inner.fetch(:context))
      inner.merge(result: tool.call(inner.fetch(:effect).input, invocation))
    end
  end

  # A read whose pending a sibling fiber answers, or -- with no block -- one
  # nobody ever answers, which the queue's window denies.
  def read(path, tool_use_id: "tu_1", &answer)
    Sync do |task|
      run = task.async { dispatch(effect(path, tool_use_id:)) }
      answer&.call(queue)
      run.wait
    end
  end

  def approve(queue) = queue.dequeue.approve(surface: "spec")

  def redactions = journal.grep(Lain::Telemetry::ReadRedacted)

  def releases = journal.grep(Lain::Telemetry::ReadReleased)

  def decisions = journal_records(journal_io, "approval_decision")

  def parks = journal_records(journal_io, "approval_pending")

  describe "masking what nobody has released" do
    it "removes the region's bytes and stands a placeholder in their place" do
      path = write("notes.txt", one_secret)

      content = read(path).fetch(:result).content

      expect(content).not_to include(api_key)
      expect(content).to include("<redacted:1>")
    end

    it "keeps the surrounding structure, so a masked dotenv is still legible as one" do
      path = write(".env", dotenv)

      content = read(path).fetch(:result).content

      expect(content).to include("API_KEY=", "DATABASE_PASSWORD=", "SESSION_SECRET=")
      expect(content).not_to include(api_key, "hunter2SecretValue", "correct-horse-battery-staple")
    end

    # The ordinal is what makes three masked regions three DISTINCT
    # placeholders. It is not the region's length: a length would disclose how
    # long the secret is, which is a fact about the secret.
    it "numbers each masked region so the model can tell them apart" do
      path = write(".env", dotenv)

      content = read(path).fetch(:result).content

      expect(content).to include("<redacted:1>", "<redacted:2>", "<redacted:3>")
    end

    # The format and the walk that applies it belong to the region model, not to
    # this middleware: a survey's projection masks the same bytes the same way,
    # and a second copy of either is how the two arms drift on what a masked
    # region looks like. The literals above stay literal on purpose -- they are
    # what would catch a change to the shared rendering.
    it "renders the region model's own placeholder, with no second copy of the format here" do
      path = write("notes.txt", one_secret)

      content = read(path).fetch(:result).content

      expect(content).to include(format(Lain::Sensitivity::Regions::PLACEHOLDER, 1))
      expect(described_class.const_defined?(:PLACEHOLDER, false)).to be(false)
    end

    # The entropy detector reaches each full 64-character line of a key, and not
    # a short last one, so a mask built from those runs leaked the tail of half
    # the 3072-bit keys `openssl genrsa` writes (PKCS#8, whose last line is 24
    # characters). A real key, chosen so its last line is one the entropy
    # detector alone does not see -- the precondition is asserted, so this
    # cannot pass on a key that never exercised the gap.
    it "masks every line of an RSA key between BEGIN and END" do
      pem = Enumerator.produce { OpenSSL::PKey::RSA.generate(3072).private_to_pem }.lazy.take(24)
                      .find { |candidate| Lain::Sensitivity::Regions.detect(candidate.lines[-2]).empty? }
      expect(pem).to be_a(String)
      body = pem.lines[1..-2].map(&:chomp)
      path = write("deploy.pem", pem)

      content = read(path).fetch(:result).content

      expect(body.select { |line| content.include?(line) }).to be_empty
    end

    it "leaves a file with no regions byte-identical, and parks nothing" do
      path = write("plain.rb", ordinary)

      content = read(path).fetch(:result).content

      expect(content).to eq(ordinary)
      expect(queue.to_a).to be_empty
    end
  end

  describe "the release path" do
    it "returns the whole file when the pending is approved" do
      path = write("notes.txt", one_secret)

      content = read(path) { |q| approve(q) }.fetch(:result).content

      expect(content).to eq(one_secret)
    end

    it "releases the approved regions to the ledger" do
      path = write("notes.txt", one_secret)
      digest = Lain::Sensitivity::Regions.detect(one_secret).first.digest

      read(path) { |q| approve(q) }

      expect(ledger.released?(path, digest)).to be(true)
    end

    # The other half of "an unreleased region renders as a placeholder": a
    # RELEASED one renders as its real bytes, in the same file, in the same
    # read. That is what makes partial approval fall out of the design rather
    # than needing a mechanism, and it is the only shape that can tell masking
    # the unreleased regions from masking every region found.
    it "shows a released region's real bytes beside the masked ones" do
      path = write(".env", dotenv)
      ledger.release(path, [Lain::Sensitivity::Regions.detect(dotenv)[1]])

      content = read(path).fetch(:result).content

      expect(content).to include("hunter2SecretValue")
      expect(content).not_to include(api_key, "correct-horse-battery-staple")
      expect(content).to include("<redacted:1>", "<redacted:2>")
    end

    it "needs no pending at all once every region is released" do
      path = write("notes.txt", one_secret)
      read(path) { |q| approve(q) }

      second = read(path, tool_use_id: "tu_2")

      expect(second.fetch(:result).content).to eq(one_secret)
      expect(queue.to_a).to be_empty
    end

    # `withheld_in` hands the ledger `complete: true`, and that literal is a
    # CLAIM this middleware makes about its own scan: it refuses content it
    # could not fully read, and sets no size cap, so anything reaching the
    # ledger really was seen whole.
    #
    # The claim is what licenses the RECONCILE inside `outstanding` -- dropping
    # the releases for regions the file no longer holds. Say `false` and the
    # returned value is identical, every existing example stays green, and the
    # only difference is that a release outlives the bytes it was granted for:
    # approve a secret, let the file stop holding it, and the approval is still
    # sitting there when those exact bytes come back. Delete-then-restore is the
    # shape, and it sends the secret with nobody asked.
    #
    # `Sensitivity::Ledger`'s own spec covers what `complete:` MEANS. This is
    # the call site that decides which value it gets, and nothing pinned it.
    it "lets a release die with the bytes it was granted for" do
      path = write("notes.txt", one_secret)
      digest = Lain::Sensitivity::Regions.detect(one_secret).first.digest
      read(path) { |q| approve(q) }

      # The file stops holding that secret. This read is what reconciles.
      File.write(path, "DATABASE_PASSWORD=hunter2SecretValue\n")
      read(path, tool_use_id: "tu_2")

      expect(ledger.released?(path, digest)).to be(false)
    end

    it "so the same secret restored later is asked about again, not sent" do
      path = write("notes.txt", one_secret)
      read(path) { |q| approve(q) }
      File.write(path, "DATABASE_PASSWORD=hunter2SecretValue\n")
      read(path, tool_use_id: "tu_2")

      File.write(path, one_secret)
      content = read(path, tool_use_id: "tu_3").fetch(:result).content

      expect(content).not_to include(api_key)
      expect(content).to include("<redacted:1>")
    end

    # Fail-closed, inherited from the queue rather than reimplemented here.
    it "falls toward masking when nobody ever answers" do
      path = write("notes.txt", one_secret)

      content = read(path).fetch(:result).content

      expect(content).not_to include(api_key)
      expect(ledger.released?(path, Lain::Sensitivity::Regions.detect(one_secret).first.digest)).to be(false)
    end

    it "masks on a denial, and releases nothing" do
      path = write("notes.txt", one_secret)

      content = read(path) { |q| q.dequeue.deny(surface: "spec") }.fetch(:result).content

      expect(content).not_to include(api_key)
      expect(ledger).to be_empty
    end
  end

  describe "the edit contract a masked read must not satisfy" do
    let(:edit) { Lain::Tools::EditFile.new }

    def edit_call(path)
      edit.call({ "path" => path, "old_string" => "x = 1", "new_string" => "x = 2" },
                Lain::Tool::Invocation.new(tool_use_id: "tu_e", context: session))
    end

    # The content is what a model that saw the masked projection would send
    # back: the placeholder, not the secret.
    def write_call(path)
      Lain::Tools::WriteFile.new.call({ "path" => path, "content" => "API_KEY=<redacted:1>\n" },
                                      Lain::Tool::Invocation.new(tool_use_id: "tu_w", context: session))
    end

    it "refuses an edit after a masked read, naming the masking rather than a read that happened" do
      path = write("notes.txt", "x = 1\n#{one_secret}")
      read(path)

      expect { edit_call(path) }
        .to raise_error(Lain::Tool::ContractViolation, /read only in part/)
    end

    it "still reports the file as read, so the refusal is not the never-read one" do
      path = write("notes.txt", "x = 1\n#{one_secret}")
      read(path)

      expect(session.read?(path)).to be(false)
      expect(session.partially_read?(path)).to be(true)
    end

    it "allows the edit when every region was released during the read" do
      path = write("notes.txt", "x = 1\n#{one_secret}")
      read(path) { |q| approve(q) }

      expect { edit_call(path) }.not_to raise_error
      expect(session.read?(path)).to be(true)
    end

    # Worse than the edit case and for a different reason: a write replaces the
    # WHOLE file with what the model holds, and what the model holds is the
    # projection. So the secret is not clobbered by other bytes, it is replaced
    # on disk by the literal string `<redacted:1>` and gone.
    it "refuses a write_file over a masked file, which would replace the secret with its placeholder" do
      path = write("notes.txt", one_secret)
      read(path)

      expect { write_call(path) }.to raise_error(Lain::Tool::ContractViolation, /read only in part/)
      expect(File.read(path)).to eq(one_secret)
    end

    it "allows the write once every region was released during the read" do
      path = write("notes.txt", one_secret)
      read(path) { |q| approve(q) }

      expect { write_call(path) }.not_to raise_error
    end

    # write_file's contract is narrower than edit_file's -- it lets a CREATE
    # through over a nonexistent path -- and the masked guard must not close
    # that, which it cannot: a path that was read is a path that exists.
    it "still lets a create through over a path nothing has read" do
      expect { write_call(File.join(dir, "brand_new.txt")) }.not_to raise_error
    end

    it "leaves an ordinary file's complete read exactly as it was" do
      path = write("plain.rb", ordinary)
      read(path)

      expect(session.read?(path)).to be(true)
      expect(session.partially_read?(path)).to be(false)
    end
  end

  describe "what it journals" do
    let(:three) do
      "ALPHA_TOKEN=#{api_key}\n" \
        "BETA_TOKEN=ghp_ZK1mQ8vR3xT5wL9nB2jH7yD4sA6fG0pEqW1z\n" \
        "GAMMA_TOKEN=AKIAIOSFODNN7EXAMPLE\n"
    end

    it "records one ReadRedacted carrying how many were found and how many were already released" do
      path = write(".env", three)
      regions = Lain::Sensitivity::Regions.detect(three)
      ledger.release(path, [regions.first])

      read(path)

      expect(redactions).to contain_exactly(
        an_object_having_attributes(path:, regions: 3, released: 1, tool_use_id: "tu_1")
      )
    end

    # One line per state transition, not per call -- `Session#record_read`'s own
    # rule, which this seam has to match. A line per read would make a masked
    # file journal ten times over a read/edit loop where an unmasked one
    # journals once, i.e. noisiest exactly where the loop is.
    it "records one line however often a loop re-reads the same masked file" do
      path = write("notes.txt", one_secret)

      3.times { |n| read(path, tool_use_id: "tu_#{n}") }

      expect(redactions.length).to eq(1)
    end

    it "records again once the file grows a region nobody has ruled on" do
      path = write("notes.txt", one_secret)
      read(path)
      File.write(path, "#{one_secret}DATABASE_PASSWORD=hunter2SecretValue\n")

      read(path, tool_use_id: "tu_2")

      expect(redactions.length).to eq(2)
    end

    it "records nothing when nothing was masked" do
      read(write("plain.rb", ordinary))

      expect(redactions).to be_empty
    end

    # An approved read withheld nothing, so there is no redaction to record. What
    # says a secret was sent is its own record: the approval's decision names no
    # file and no count, and a `read_redacted` would resume the file as masked.
    it "records a release rather than a redaction when the human approved the whole file" do
      read(write("notes.txt", one_secret)) { |q| approve(q) }

      expect(redactions).to be_empty
      expect(releases.length).to eq(1)
    end

    it "records a human's release with its count, its file and the call it answered" do
      path = write(".env", "API_KEY=#{api_key}\nDATABASE_PASSWORD=hunter2SecretValue\n")

      read(path, tool_use_id: "tu_env") { |q| approve(q) }

      expect(releases).to contain_exactly(
        an_object_having_attributes(path:, regions: 2, tool_use_id: "tu_env", requester: "agent", surface: "spec")
      )
    end

    # The count is what THIS read released, from the snapshot it parked on: a
    # region released before the read was not this read's to send.
    it "counts only the regions this read released, not those released before it" do
      path = write(".env", three)
      ledger.release(path, [Lain::Sensitivity::Regions.detect(three).first])

      read(path) { |q| approve(q) }

      expect(releases).to contain_exactly(an_object_having_attributes(regions: 2))
    end

    it "records no release when the human refused" do
      read(write("notes.txt", one_secret)) { |q| q.dequeue.deny(surface: "spec") }

      expect(releases).to be_empty
    end

    it "keeps the released bytes out of the release record" do
      read(write("notes.txt", one_secret)) { |q| approve(q) }

      expect(releases.map(&:to_journal).to_s).not_to include(api_key)
    end

    # Evidence must not cost the read it describes: the release has happened,
    # so a journal that refuses the write still hands the model its file. Nor
    # may the loss be silent, since the secret went out: it degrades into the
    # journal's own failure record, naming what it stood in for.
    it "returns the released file and records the failure when the journal refuses the release" do
      path = write("notes.txt", one_secret)
      refusing = RedactSpecSupport::RefusingJournal.new(journal, refuses: Lain::Telemetry::ReadReleased)
      subject_stack = Lain::Middleware::Stack.new([described_class.new(ledger:, queue:, journal: refusing)])

      carried = Sync do |task|
        run = task.async { dispatch(effect(path), subject_stack:) }
        approve(queue)
        run.wait
      end

      expect(carried.fetch(:result).content).to eq(one_secret)
      expect(journal).to contain_exactly(
        a_hash_including("type" => "journal_error", "entry_class" => "Lain::Telemetry::ReadReleased",
                         "error" => "IOError: journal closed")
      )
    end

    # `Effect::ToolCall` coerces a missing id to "", which the record refuses.
    it "returns the released file and records the failure when the release record cannot be built" do
      path = write("notes.txt", one_secret)

      content = read(path, tool_use_id: "") { |q| approve(q) }.fetch(:result).content

      expect(content).to eq(one_secret)
      expect(releases).to be_empty
      expect(journal).to contain_exactly(
        a_hash_including("type" => "journal_error", "entry_class" => "Lain::Telemetry::ReadReleased",
                         "error" => /\AArgumentError: tool_use_id must name the released call/)
      )
    end

    it "keeps the released bytes out of the failure record" do
      read(write("notes.txt", one_secret), tool_use_id: "") { |q| approve(q) }

      expect(journal.to_s).not_to include(api_key)
    end

    # The record describes ONE read. `unreleased` is snapshotted before the
    # park and the ledger moves during it -- `ReadFile` is parallel_safe?, so a
    # sibling read of the same file can be approved while this one waits. A
    # `released` re-asked of the ledger afterwards reports what the RUN believes
    # now, not what this read sent, and lands a false count inside the guard
    # meant to keep it honest.
    it "counts what THIS read rendered, not what a sibling released while it waited" do
      path = write("notes.txt", one_secret)

      Sync do |task|
        denied = task.async { dispatch(effect(path, tool_use_id: "tu_denied")) }
        approved = task.async { dispatch(effect(path, tool_use_id: "tu_approved")) }
        queue.dequeue.deny(surface: "spec")
        queue.dequeue.approve(surface: "spec")
        [denied, approved].each(&:wait)
      end

      # The denied read masked its one region and sent nothing, so it released
      # NONE of what it found -- whatever the approving sibling did next.
      expect(redactions).to contain_exactly(
        an_object_having_attributes(tool_use_id: "tu_denied", regions: 1, released: 0)
      )
    end

    it "keeps the masked bytes out of the journal entirely" do
      read(write("notes.txt", one_secret))

      expect(redactions.map(&:to_journal).to_s).not_to include(api_key)
      expect(journal_io.string).not_to include(api_key)
    end
  end

  # One queue serves the whole fleet, so the CALL names who is asking, through
  # the context, exactly as a child's gate does. A read guard that never named
  # the child left every child's release reading as the parent's own.
  describe "a release asked for a child" do
    subject(:middleware) { described_class.new(ledger:, queue:, journal:, requester: "researcher") }

    it "names the child on the park, the decision and the release" do
      read(write("notes.txt", one_secret)) { |q| approve(q) }

      expect(parks).to contain_exactly(a_hash_including("requester" => "researcher"))
      expect(decisions).to contain_exactly(a_hash_including("requester" => "researcher", "tool_use_id" => "tu_1"))
      expect(releases).to contain_exactly(an_object_having_attributes(requester: "researcher"))
    end

    # A gated file is asked about twice for one call: at the path gate, then at
    # the release. So a call's id is not unique to one park, and a reader pairs
    # its records in order within the id.
    it "parks twice under one call's id behind a path gate, and each decision follows its own park" do
      sensitivity = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: "/home/nobody", cwd: dir))
      gate = Lain::Middleware::Gate.new(policy: queue, sensitivity:, denial: "denied %<name>s")
      gated = Lain::Middleware::Stack.new([middleware, gate])
      env = { effect: effect(write(".env", one_secret), tool_use_id: "tu_env"), tool: Lain::Tools::ReadFile.new,
              context: session }

      Sync do |task|
        run = task.async do
          gated.call(env) do |inner|
            invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_env", context: inner.fetch(:context))
            inner.merge(result: Lain::Tools::ReadFile.new.call(inner.fetch(:effect).input, invocation))
          end
        end
        2.times { approve(queue) }
        run.wait
      end

      approvals = Lain::Journal.records(journal_io.string.lines).select { _1["tool_use_id"] == "tu_env" }.to_a
      expect(approvals.map { |record| record["type"] })
        .to eq(%w[approval_pending approval_decision approval_pending approval_decision])
      expect(releases).to contain_exactly(an_object_having_attributes(tool_use_id: "tu_env", surface: "spec"))
    end

    # The context is wrapped, never replaced: the read-set the mask lands on is
    # still the reading worker's own session.
    it "still records a refused child's mask on the reading session" do
      path = write("notes.txt", one_secret)

      read(path) { |q| q.dequeue.deny(surface: "spec") }

      expect(session.masked_read?(path)).to be(true)
    end
  end

  describe "what it leaves alone" do
    it "passes an unguarded tool's result through untouched" do
      path = write("notes.txt", one_secret)
      carried = dispatch(effect(path, name: "list_files"),
                         tool: Lain::Tools::ReadFile.new)

      expect(carried.fetch(:result).content).to eq(one_secret)
      expect(queue.to_a).to be_empty
    end

    # The failing path is SECRET-SHAPED on purpose. A failed read carries a
    # message, not file bytes -- but the message quotes the path, so a
    # middleware that scanned error results would detect a region in its own
    # refusal, park a pending over a file that does not exist, and hand back a
    # masked `Tool::Result.ok` in place of the error. The model would read
    # "success" for a read that failed.
    it "passes an error result through untouched, since a failed read taught the model nothing" do
      carried = Sync { dispatch(effect(File.join(dir, "#{api_key}.txt"))) }

      expect(carried.fetch(:result)).to be_error
      expect(queue.to_a).to be_empty
      expect(redactions).to be_empty
    end
  end

  # `Tool::Result#content` is a String or an Array of provider content blocks.
  # `read_file` only ever produces a String today, so the Array arm is decided
  # deliberately rather than left to a `to_s` that would corrupt a legitimate
  # result: every block whose text this can read is masked, and a result holding
  # any block it CANNOT read is refused outright rather than forwarded.
  #
  # There is no partial-detection arm left. An earlier edition masked what it
  # understood, passed the rest through, and told the ledger the detection was
  # INCOMPLETE -- which is fail-open, since the part it passed through is the
  # part that would carry the secret out. Refusing instead is what lets
  # `withheld_in` tell the ledger `complete: true` truthfully.
  describe "a result carrying content blocks rather than a String" do
    let(:blocks) { [{ "type" => "text", "text" => one_secret }, { "type" => "text", "text" => "tail\n" }] }

    def block_dispatch(path, content = blocks)
      Sync do
        stack.call({ effect: effect(path), context: session }) do |inner|
          inner.merge(result: Lain::Tool::Result.ok(content))
        end
      end
    end

    it "masks each text block and leaves the shape of the result alone" do
      content = block_dispatch(write("notes.txt", one_secret)).fetch(:result).content

      expect(content.first["text"]).to include("<redacted:1>")
      expect(content.first["text"]).not_to include(api_key)
      expect(content[1]).to eq(blocks.last)
      expect(blocks.first["text"]).to eq(one_secret)
    end

    # Every spelling of "this block is text". Each of these was silently
    # UNSCANNED before, and an unscanned result has no regions, and a result
    # with no regions takes the early return -- so the secret went to the model
    # unmasked with nobody asked. Fail-open, in the class whose job is the
    # opposite.
    [["a bare String element", ->(secret) { [secret] }],
     ["a Symbol text key", ->(secret) { [{ type: "text", text: secret }] }]].each do |(shape, build)|
      it "masks text arriving as #{shape}" do
        content = block_dispatch(write("notes.txt", one_secret), build.call(one_secret)).fetch(:result).content

        expect(content.to_s).not_to include(api_key)
        expect(content.to_s).to include("<redacted:1>")
      end
    end

    # A block this cannot read cannot be vouched for, so the result is withheld
    # rather than passed through with the unreadable part intact. Loud and
    # inconvenient on purpose: whoever first returns image blocks from a guarded
    # tool has to decide what masking means for them.
    it "refuses a result carrying a block it cannot scan, rather than sending it" do
      image = [{ "type" => "text", "text" => one_secret },
               { "type" => "image", "source" => { "data" => "iVBORw0KGgo=" } }]

      result = block_dispatch(write("notes.txt", one_secret), image).fetch(:result)

      expect(result).to be_error
      expect(result.content).to include("cannot scan")
      expect(result.content).not_to include(api_key)
    end

    # `Ledger#outstanding` RECONCILES -- it drops the releases for regions the
    # file no longer holds -- and that is sound only over a scan that saw
    # everything. A refused result saw nothing it could vouch for, so the ledger
    # must not be asked at all: asking would forget a release for a region
    # nobody looked at, and re-prompt for an already-approved secret forever.
    # The refusal therefore has to come BEFORE the ledger call, which is an
    # ordering no assertion about the returned Result can see.
    #
    # The unseen region is a real one detected from other bytes, not a fake
    # digest: the claim is about what the ledger does with a release it holds,
    # and a digest no detector ever produced could not be reconciled away by any
    # implementation.
    it "never reconciles the ledger off a view it refused" do
      path = write("notes.txt", one_secret)
      elsewhere = Lain::Sensitivity::Regions.detect("DATABASE_PASSWORD=hunter2SecretValue\n").first
      ledger.release(path, [elsewhere])
      unscannable = [{ "type" => "image", "source" => { "data" => "iVBORw0KGgo=" } }]

      block_dispatch(path, unscannable)

      expect(ledger.released?(path, elsewhere.digest)).to be(true)
    end
  end

  # Every abnormal exit from the await. ReadFile recorded a COMPLETE read below
  # this middleware before the park began, and the masked set has no removal, so
  # a path that leaves here without a verdict is editable forever -- the control
  # failing OPEN, which is the one direction it exists to prevent. No bytes
  # leak on any of these; the read-set is what breaks.
  describe "an await that never produces a verdict" do
    let(:edit) { Lain::Tools::EditFile.new }
    let(:raising_queue) { RedactSpecSupport::RaisingQueue.new }

    def edit_call(path)
      edit.call({ "path" => path, "old_string" => "x = 1", "new_string" => "x = 2" },
                Lain::Tool::Invocation.new(tool_use_id: "tu_e", context: session))
    end

    it "records the mask when the surface raises out of the await" do
      path = write("notes.txt", "x = 1\n#{one_secret}")
      raising = described_class.new(ledger:, queue: raising_queue, journal:)

      Sync { dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([raising])) }

      expect(session.read?(path)).to be(false)
      expect(session.masked_read?(path)).to be(true)
      expect { edit_call(path) }.to raise_error(Lain::Tool::ContractViolation, /read only in part/)
    end

    # `Async::Stop` is not a StandardError, so no rescue anywhere sees it --
    # only the `ensure` does. This is the Ctrl-C path: the requester is stopped
    # while parked and the pending is abandoned.
    it "records the mask when the parked fiber is stopped outright" do
      path = write("notes.txt", "x = 1\n#{one_secret}")

      Sync do |task|
        run = task.async { dispatch(effect(path)) }
        # Let the read reach the park before stopping it.
        task.sleep(0.02)
        run.stop
        run.wait
      rescue Async::Stop
        nil
      end

      expect(session.read?(path)).to be(false)
      expect(session.masked_read?(path)).to be(true)
    end

    # The mask must be gated on a VERDICT, not on `adjudicate` having returned.
    # A guard written the easier way -- set the flag as soon as the call comes
    # back -- passes every other example in this group and fails open here.
    it "records the mask when the call returns but the verdict cannot be read" do
      path = write("notes.txt", "x = 1\n#{one_secret}")
      broken = described_class.new(ledger:, queue: RedactSpecSupport::BrokenVerdict.new, journal:)

      Sync { dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([broken])) }

      expect(session.read?(path)).to be(false)
      expect(session.masked_read?(path)).to be(true)
      expect { edit_call(path) }.to raise_error(Lain::Tool::ContractViolation, /read only in part/)
    end

    it "answers an error result rather than escaping into the ToolRunner" do
      path = write("notes.txt", one_secret)
      raising = described_class.new(ledger:, queue: raising_queue, journal:)

      carried = Sync { dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([raising])) }

      expect(carried.fetch(:result)).to be_error
      expect(carried.fetch(:result).content).to include("could not be checked")
    end

    # A raise escaping here leaves the turn with a tool_use no tool_result
    # answers, which wedges the state machine at awaiting_tools. The bytes must
    # not come back either: a read this class could not finish checking is one
    # whose secrets it cannot vouch for.
    it "never hands back the unchecked bytes when it fails" do
      path = write("notes.txt", one_secret)
      raising = described_class.new(ledger:, queue: raising_queue, journal:)

      carried = Sync { dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([raising])) }

      expect(carried.fetch(:result).content).not_to include(api_key)
    end
  end

  # Re-asking cannot produce a different answer without a human doing something
  # the model cannot prompt for, and each re-ask costs another full timeout
  # window. Left unremembered, a model told to re-read a denied file turns one
  # refusal into an unbounded series of five-minute stalls.
  describe "a decision it has already been given" do
    it "parks only once for the same unreleased regions, however often the file is read" do
      path = write("notes.txt", one_secret)

      3.times { |n| read(path, tool_use_id: "tu_#{n}") { |q| q.dequeue.deny(surface: "spec") if n.zero? } }

      expect(decisions.length).to eq(1)
    end

    it "still masks on every one of those reads" do
      path = write("notes.txt", one_secret)
      read(path) { |q| q.dequeue.deny(surface: "spec") }

      content = read(path, tool_use_id: "tu_2").fetch(:result).content

      expect(content).not_to include(api_key)
      expect(content).to include("<redacted:1>")
    end

    # A timeout is a decline for the queue's own reason -- an unattended gate
    # refuses -- so it must not be re-asked either.
    it "treats an unanswered window as an answer, not as a question still open" do
      path = write("notes.txt", one_secret)

      2.times { |n| read(path, tool_use_id: "tu_#{n}") }

      expect(decisions.length).to eq(1)
    end

    # Keyed by (path, digest), not by digest -- {Sensitivity::Ledger}'s own
    # rule, for its own reason. The identical bytes in two files are not the
    # same secret, so a "no" about one must not silently answer for the other:
    # that would mask the second file's regions without anyone ever being shown
    # the question, which is the same one-decision-travels failure the ledger
    # keys by path to prevent.
    it "does not let a decline at one path answer for the same bytes at another" do
      denied = write("denied.env", one_secret)
      other = write("other.env", one_secret)
      read(denied) { |q| q.dequeue.deny(surface: "spec") }

      read(other, tool_use_id: "tu_2") { |q| q.dequeue.deny(surface: "spec") }

      expect(decisions.length).to eq(2)
    end

    # A region nobody has been asked about yet is a NEW question, even at a path
    # where an earlier one was denied.
    it "asks again when the file grows a region nobody has ruled on" do
      path = write("notes.txt", one_secret)
      read(path) { |q| q.dequeue.deny(surface: "spec") }
      File.write(path, "#{one_secret}DATABASE_PASSWORD=hunter2SecretValue\n")

      read(path, tool_use_id: "tu_2") { |q| q.dequeue.deny(surface: "spec") }

      expect(decisions.length).to eq(2)
    end
  end

  describe "the trailer on a masked read" do
    it "says what was withheld, that the file is readable, and to tell the user which file" do
      path = write("notes.txt", one_secret)

      content = read(path) { |q| q.dequeue.deny(surface: "spec") }.fetch(:result).content

      expect(content).to end_with(
        "1 region is masked as <redacted:1>. The file is readable; " \
        "the release was declined. Tell the user which file you need unmasked."
      )
    end

    it "counts every withheld region" do
      path = write(".env", dotenv)

      content = read(path) { |q| q.dequeue.deny(surface: "spec") }.fetch(:result).content

      expect(content).to include("3 regions are masked as <redacted:1> to <redacted:3>.")
    end

    it "says a lapsed release timed out rather than was declined" do
      path = write("notes.txt", one_secret)

      content = read(path).fetch(:result).content

      expect(content).to include("the release timed out")
      expect(content).not_to include("declined")
    end

    it "keeps saying so on a later read, which is not asked again" do
      path = write("notes.txt", one_secret)
      read(path)

      content = read(path, tool_use_id: "tu_2").fetch(:result).content

      expect(content).to include("the release timed out")
    end

    it "does not say the human declined when the directory is simply related" do
      classifier = Lain::Sensitivity.new(home: dir, cwd: dir,
                                         rules: Lain::Sensitivity::Rules.from({ "related" => ["~/pitchcraft"] }))
      path = File.join(dir, "pitchcraft", "notes.md").tap do |made|
        FileUtils.mkdir_p(File.dirname(made))
        File.write(made, one_secret)
      end
      related = described_class.new(ledger:, queue:, journal:, related: classifier)

      content = dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([related])).fetch(:result).content

      expect(content).to include("masked as <redacted:1>")
      expect(content).not_to include("declined")
    end

    it "adds a text block to a result that arrived as blocks" do
      blocks = [{ "type" => "text", "text" => one_secret }]
      path = write("notes.txt", one_secret)

      content = Sync do
        stack.call({ effect: effect(path), context: session }) do |inner|
          inner.merge(result: Lain::Tool::Result.ok(blocks))
        end
      end.fetch(:result).content

      expect(content.last).to include("type" => "text", "text" => include("masked as <redacted:1>"))
    end
  end

  # A real classifier over a real `sensitivity related:` table, with the
  # tmpdir as home, so the entry is written the way a config writes it.
  describe "a read under a related directory" do
    subject(:middleware) { described_class.new(ledger:, queue:, journal:, related: classifier) }

    let(:classifier) do
      Lain::Sensitivity.new(home: dir, cwd: dir,
                            rules: Lain::Sensitivity::Rules.from({ "related" => ["~/pitchcraft"] }))
    end

    def write_under(name, content)
      File.join(dir, name).tap do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
    end

    it "masks every flagged region without parking an approval" do
      path = write_under("pitchcraft/notes.md", one_secret)

      content = read(path).fetch(:result).content

      expect(parks).to be_empty
      expect(content).not_to include(api_key)
      expect(content).to include("<redacted:1>")
    end

    it "calls the file readable and never claims it is inside the project" do
      path = write_under("pitchcraft/notes.md", one_secret)

      content = read(path).fetch(:result).content

      expect(content).to include("The file is readable;")
      expect(content).not_to include("inside the project")
    end

    it "journals the read as redacted with nothing released" do
      path = write_under("pitchcraft/notes.md", one_secret)

      read(path)

      expect(redactions).to contain_exactly(an_object_having_attributes(path:, regions: 1, released: 0))
      expect(releases).to be_empty
    end

    it "masks a later read of the same file again without asking, and journals it once" do
      path = write_under("pitchcraft/notes.md", one_secret)
      read(path)

      content = read(path, tool_use_id: "tu_2").fetch(:result).content

      expect(content).to include("<redacted:1>")
      expect(parks).to be_empty
      expect(redactions.length).to eq(1)
    end

    it "records the masked read, so an edit over it is refused" do
      path = write_under("pitchcraft/notes.md", one_secret)

      read(path)

      expect(session.masked_read?(path)).to be(true)
    end

    it "still parks an approval for a read outside every related directory" do
      path = write_under("other/notes.md", one_secret)

      read(path) { |q| approve(q) }

      expect(parks.length).to eq(1)
      expect(read(path, tool_use_id: "tu_2").fetch(:result).content).to include(api_key)
    end
  end

  describe "its collaborators" do
    it "refuses to be built without a ledger, because a second ledger releases in silence" do
      expect { described_class.new(queue:, journal:) }.to raise_error(ArgumentError, /ledger/)
    end

    it "refuses to be built without a queue, so a forgotten one cannot become silent approval" do
      expect { described_class.new(ledger:, journal:) }.to raise_error(ArgumentError, /queue/)
    end

    # `nil` is not a missing keyword, and nil is exactly what
    # `Switchboard#approvals` carries in an unattended run -- so without these the
    # "no default means no silent approval" argument rests on nobody ever
    # passing the value the wiring actually holds.
    it "refuses a nil ledger, which a missing-keyword check never sees" do
      expect { described_class.new(ledger: nil, queue:, journal:) }.to raise_error(ArgumentError, /ledger/)
    end

    it "refuses a nil queue for the same reason" do
      expect { described_class.new(ledger:, queue: nil, journal:) }.to raise_error(ArgumentError, /queue/)
    end

    # An unattended run wires no queue at all (Switchboard#approvals is nil).
    # Masking with nowhere to park would leave the model `<redacted:1>` forever
    # with no move, so the stand-in approves. That is a FAIL-OPEN in a run whose
    # gate otherwise denies everything -- see the Unqueued docstring; this
    # example pins the behaviour as it stands, not as it should be.
    it "sends the whole file under the unqueued stand-in an unattended run wires" do
      path = write("notes.txt", one_secret)
      unqueued = described_class.new(ledger:, queue: described_class::Unqueued.instance, journal:)

      content = Sync { dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([unqueued])) }
                .fetch(:result).content

      expect(content).to eq(one_secret)
      expect(session.read?(path)).to be(true)
    end

    # The fail-open leaves the same evidence a human's release does, signed by
    # the stand-in, so a run that sent a secret with nobody asked says so.
    it "records the unqueued stand-in's release under its own name" do
      path = write("notes.txt", one_secret)
      unqueued = described_class.new(ledger:, queue: described_class::Unqueued.instance, journal:)

      Sync { dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([unqueued])) }

      expect(releases).to contain_exactly(
        an_object_having_attributes(path:, regions: 1, requester: "agent",
                                    surface: described_class::Unqueued::SURFACE)
      )
    end
  end

  describe "a grep or ast_search result" do
    let(:token) { "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5" }
    let(:settings) { File.join(dir, "config", "settings.yml") }

    before do
      FileUtils.mkdir_p(File.dirname(settings))
      File.write(settings, "name: app\n  token: #{token}\n")
    end

    def search(input, name: "grep", tool: Lain::Tools::Grep.new, tool_use_id: "tu_grep")
      Sync do
        dispatch(Lain::Effect::ToolCall.new(tool_use_id:, name:, input:), tool:).fetch(:result).content
      end
    end

    def grep(path, **) = search({ "pattern" => "ghp_", "path" => path }, **)

    def rows(content) = content.lines(chomp: true)

    def searches = journal.grep(Lain::Telemetry::SearchRedacted)

    it "masks a token in an ordinary file in its row" do
      content = grep("config")

      expect(rows(content).first).to eq("settings.yml:2:  token: <redacted:1>")
      expect(content).not_to include(token)
    end

    it "ends the result with a line saying how many rows were masked and how to ask for release" do
      trailer = rows(grep("config")).last

      expect(trailer).to include("1 row was masked", "read_file on a file may ask")
      expect(trailer).to include("multi-line secret")
    end

    it "parks nothing" do
      grep("config")

      expect(parks).to be_empty
    end

    it "leaves read_file able to ask for the region it masked" do
      grep("config")

      read(settings, tool_use_id: "tu_2") { |q| approve(q) }

      expect(parks.length).to eq(1)
    end

    it "carries a region released through read_file as written, and keeps the release" do
      read(settings) { |q| approve(q) }

      content = grep("config")
      later = read(settings, tool_use_id: "tu_3").fetch(:result).content

      expect(rows(content)).to eq(["settings.yml:2:  token: #{token}"])
      expect(later).to include(token)
      expect(parks.length).to eq(1)
    end

    it "keeps a denied region masked, and asks nobody again" do
      read(settings) { |q| q.dequeue.deny(surface: "spec") }

      content = grep("config")

      expect(rows(content).first).to eq("settings.yml:2:  token: <redacted:1>")
      expect(parks.length).to eq(1)
    end

    it "keys a single-file grep on the model's spelling, the entry read_file uses" do
      digest = Lain::Sensitivity::Regions.detect(token).first.digest
      ledger.release(settings, [Lain::Sensitivity::Regions.detect(token).first])

      content = grep("config/settings.yml")

      expect(ledger.released?(settings, digest)).to be(true)
      expect(rows(content)).to eq(["config/settings.yml:2:  token: #{token}"])
    end

    it "masks a single-file grep nobody released" do
      expect(rows(grep("config/settings.yml")).first).to eq("config/settings.yml:2:  token: <redacted:1>")
    end

    # The row carries the token twice, in the matched line and in the
    # capture, and ordinals count per result in row order.
    it "masks an ast_search capture carrying a secret" do
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "conf.rb"), "TOKEN = \"#{token}\"\n")

      content = search({ "pattern" => "TOKEN = $VALUE", "language" => "ruby", "path" => "lib/conf.rb" },
                       name: "ast_search", tool: Lain::Tools::AstSearch.new)

      expect(rows(content).first).to eq('lib/conf.rb:1:TOKEN = "<redacted:1>" {VALUE="\"<redacted:2>\""}')
      expect(content).not_to include(token)
    end

    it "journals a masked file as search_redacted once, however often it is searched" do
      2.times { |n| grep("config", tool_use_id: "tu_#{n}") }

      expect(searches).to contain_exactly(an_object_having_attributes(path: settings, regions: 1, released: 0))
      expect(redactions).to be_empty
    end

    # A key-only shape is found by its key, which the capture does not repeat,
    # so the capture is masked by the bytes the line's region holds.
    it "masks an ast_search capture holding a secret found only by its key" do
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "conf.rb"), "PASSWORD = \"Zx9!qLm2Vb7#rT4w\"\n")

      content = search({ "pattern" => "PASSWORD = $V", "language" => "ruby", "path" => "lib/conf.rb" },
                       name: "ast_search", tool: Lain::Tools::AstSearch.new)

      expect(content).not_to include("Zx9!qLm2Vb7#rT4w")
      expect(rows(content).first).to eq('lib/conf.rb:1:PASSWORD = "<redacted:1>" {V="\\"<redacted:2>\\""}')
    end

    it "masks the escaped spelling of a secret the capture quotes" do
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "conf.rb"), "PASSWORD = 'Zx9\"qLm2Vb7\\rT4w'\n")

      content = search({ "pattern" => "PASSWORD = $V", "language" => "ruby", "path" => "lib/conf.rb" },
                       name: "ast_search", tool: Lain::Tools::AstSearch.new)

      expect(content).not_to include("Zx9", "rT4w")
    end

    it "keeps every release of a file when the rows show only some of its regions" do
      File.write(settings, "  token: #{token}\n  password: Zx9qLm2Vb7rT4wKp\n")
      read(settings) { |q| approve(q) }

      search({ "pattern" => "ghp_", "path" => "config" })
      read(settings, tool_use_id: "tu_3")

      expect(parks.length).to eq(1)
    end

    it "keys a row on the file it names when the matched text holds a label separator" do
      File.write(settings, "url http://h:8443:x token: #{token}\n")

      content = grep("config")

      expect(rows(content).first).to eq("settings.yml:1:url http://h:8443:x token: <redacted:1>")
      expect(searches.map(&:path)).to eq([settings])
    end

    it "keys a row on a file whose name holds a line-number field" do
      odd = File.join(dir, "config", "a:1:b.yml")
      File.write(odd, "  token: #{token}\n")
      File.write(settings, "name: app\n")

      content = grep("config")

      expect(rows(content).first).to eq("a:1:b.yml:1:  token: <redacted:1>")
      expect(searches.map(&:path)).to eq([odd])
    end

    it "numbers the placeholders across rows" do
      second = "ghp_QQQQaB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1"
      third = "ghp_RRRRaB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1"
      File.write(settings, "  token: #{token}\n  a: #{second} b: #{third}\n")

      content = grep("config")

      expect(rows(content).take(2))
        .to eq(["settings.yml:1:  token: <redacted:1>", "settings.yml:2:  a: <redacted:2> b: <redacted:3>"])
    end

    it "counts only the rows it masked" do
      File.write(settings, "  token: #{token}\nghp_ is a prefix\n")

      expect(rows(grep("config")).last).to start_with("1 row was masked")
    end

    it "journals no second record for a file a denied read already masked" do
      read(settings) { |q| q.dequeue.deny(surface: "spec") }

      grep("config")

      expect(redactions.length).to eq(1)
      expect(searches).to be_empty
    end

    it "journals how many of the file's regions in the rows were released" do
      File.write(settings, "  token: #{token}\n  password: Zx9qLm2Vb7rT4wKp\n")
      ledger.release(settings, [Lain::Sensitivity::Regions.detect(token).first])

      search({ "pattern" => "token|password", "path" => "config" })

      expect(searches).to contain_exactly(an_object_having_attributes(path: settings, regions: 2, released: 1))
    end

    # A short value recurs in ordinary words, so masking its every occurrence
    # would spell it back out by where the placeholders fall.
    it "masks a 1-character netrc password where it was found, and nowhere else" do
      File.write(settings, "machine example.com login joel password a\n")

      content = search({ "pattern" => "machine", "path" => "config" })

      expect(rows(content).first).to eq("settings.yml:1:machine example.com login joel password <redacted:1>")
    end

    it "masks a secret that contains another region as 1 placeholder" do
      File.write(settings, "token: #{token}\nsecret: Qz7w#{token}TAILzQ8w\n")

      content = grep("config")

      expect(rows(content).take(2)).to eq(["settings.yml:1:token: <redacted:1>", "settings.yml:2:secret: <redacted:2>"])
    end

    it "masks a line-anchored shape in a row" do
      File.write(settings, "account default\npassword Zx9qLm2Vb7rT4wKp\n")

      content = search({ "pattern" => "password", "path" => "config" })

      expect(rows(content).first).to eq("settings.yml:2:password <redacted:1>")
    end

    it "masks a non-ASCII secret in a row" do
      File.write(settings, "password: \"Zx9ü!qLm2Vb7#rT4w\"\n")

      Sync do
        result = dispatch(Lain::Effect::ToolCall.new(tool_use_id: "tu_g", name: "grep",
                                                     input: { "pattern" => "password", "path" => "config" }),
                          tool: Lain::Tools::Grep.new).fetch(:result)

        expect(result).not_to be_error
        expect(rows(result.content).first).to eq('settings.yml:1:password: "<redacted:1>"')
      end
    end

    it "leaves a result with no regions byte-identical" do
      File.write(settings, "name: app\n")

      expect(search({ "pattern" => "name", "path" => "config" })).to eq("settings.yml:1:name: app")
    end

    describe "under a related directory" do
      subject(:middleware) { described_class.new(ledger:, queue:, journal:, related: classifier) }

      let(:classifier) do
        Lain::Sensitivity.new(home: dir, cwd: dir,
                              rules: Lain::Sensitivity::Rules.from({ "related" => ["~/pitchcraft"] }))
      end

      it "masks a netrc password field" do
        FileUtils.mkdir_p(File.join(dir, "pitchcraft"))
        File.write(File.join(dir, "pitchcraft", "hosts"), "machine example.com login joel password Zx9!qLm2Vb7#rT4w\n")

        content = search({ "pattern" => "machine", "path" => "pitchcraft" })

        expect(rows(content).first).to eq("hosts:1:machine example.com login joel password <redacted:1>")
        expect(parks).to be_empty
      end
    end
  end

  # A command's output has no file to key a release on, so its regions are
  # masked on every call, whoever approved it, and nothing parks.
  describe "a bash result" do
    subject(:middleware) { described_class.new(ledger:, queue:, journal:, child_env:) }

    let(:token) { "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5" }
    let(:environment) { {} }
    let(:child_env) { Lain::Exec::ChildEnv.new(env: environment) }

    def bash(command = nil, tool: Lain::Tools::Bash.new)
      call = Lain::Effect::ToolCall.new(tool_use_id: "tu_bash", name: "bash", input: { "command" => command })
      Sync { dispatch(call, tool:) }.fetch(:result)
    end

    it "masks a token in the output, says so in a trailer, and parks nothing" do
      result = bash("echo #{token}")

      expect(result).to have_attributes(is_error: false)
      expect(result.content).to include("--- stdout ---\n<redacted:1>\n")
      expect(result.content.lines.last).to include("1 region was masked")
      expect(result.content).not_to include(token)
      expect(queue.to_a).to be_empty
    end

    it "masks a token a failed command's report quotes, and keeps it failed" do
      result = bash(tool: ->(_input, _invocation) { Lain::Tool::Result.error("command timed out after 1s: #{token}") })

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to start_with("command timed out after 1s: <redacted:1>")
    end

    describe "a session secret no pattern matches" do
      let(:value) { "abc123lowentropyvalue" }
      let(:environment) { { "OLLAMA_API_KEY" => value } }

      it "masks the value of a secret-named variable" do
        expect(Lain::Sensitivity::Regions.detect("#{value}\n")).to be_empty

        result = bash("echo #{value}")

        expect(result.content).to include("--- stdout ---\n<redacted:1>\n")
        expect(result.content).not_to include(value)
      end
    end

    it "counts every region in the trailer" do
      result = bash("echo #{token}; echo #{token.reverse}")

      expect(result.content).to include("<redacted:1>\n<redacted:2>\n")
      expect(result.content.lines.last).to include("2 regions were masked")
    end

    describe "a secret-named value the call's worker lends" do
      let(:value) { "lowentropy-lent-1" }
      let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: { "DEPLOY_TOKEN" => value })) }

      it "masks it, though the process environment does not hold it" do
        result = bash("printenv DEPLOY_TOKEN")

        expect(result.content).to include("--- stdout ---\n<redacted:1>\n")
        expect(result.content).not_to include(value)
      end
    end

    describe "a call with no session" do
      let(:session) { nil }

      it "masks what the process environment names" do
        expect(bash("echo #{token}").content).to include("--- stdout ---\n<redacted:1>\n")
      end
    end

    describe "a short secret-named value" do
      let(:environment) { { "DEBUG_TOKEN" => "1", "USE_SECRET" => "true", "SHORT_TOKEN" => "seven77" } }

      it "is not a mask" do
        expect(bash("echo 1 true seven77").content)
          .to eq("exit status: 0\n--- stdout ---\n1 true seven77\n--- stderr ---\n")
      end
    end

    describe "a long value under a name that is not secret-shaped" do
      let(:environment) { { "DEPLOY_REGION" => "eu-west-1-zone" } }

      it "is not a mask" do
        expect(bash("echo eu-west-1-zone").content)
          .to eq("exit status: 0\n--- stdout ---\neu-west-1-zone\n--- stderr ---\n")
      end
    end

    describe "an environment that cannot be read" do
      let(:environment) { Object.new.tap { |env| def env.to_h = raise(IOError, "environ unreadable") } }

      it "withholds the result with a reason, never the raw bytes" do
        result = bash("echo #{token}")

        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("bash could not be checked", "nothing was returned")
        expect(result.content).not_to include(token)
        expect(journal.grep(Lain::Telemetry::CommandRedacted)).to be_empty
      end
    end

    it "leaves clean output byte-identical, with no trailer" do
      expect(bash("echo hello").content).to eq("exit status: 0\n--- stdout ---\nhello\n--- stderr ---\n")
    end

    describe "what it journals" do
      let(:aws_key) { "AKIAIOSFODNN7EXAMPLE" }
      let(:password) { "hunter2xyz" }
      let(:child_env) do
        Lain::Exec::ChildEnv.new(pass: %w[DATABASE_URL],
                                 env: { "DATABASE_URL" => "postgres://app:#{password}@db.local/app" })
      end

      def commands = journal.grep(Lain::Telemetry::CommandRedacted)

      it "writes 1 command_redacted record counting the masked regions" do
        bash("echo #{aws_key}; echo #{password}")

        expect(commands).to contain_exactly(have_attributes(tool_use_id: "tu_bash", regions: 2))
      end

      it "writes nothing for a result with nothing to mask" do
        bash("echo hello")

        expect(commands).to be_empty
      end

      it "never serializes the masked bytes" do
        bash("echo #{aws_key}; echo #{password}")

        expect(commands.map(&:to_journal).to_json).not_to include(aws_key, password)
      end
    end
  end

  describe "a memory_read result" do
    let(:credential) { "deploy notes\nDB_PASSWORD=hunter2pass\n" }

    def stored(body) = Lain::Memory::Index.empty.write(Lain::Memory::Item.new(id: "note", description: "d", body:))

    def recall(body)
      call = Lain::Effect::ToolCall.new(tool_use_id: "tu_mem", name: "memory_read", input: { "id" => "note" })
      Sync { dispatch(call, tool: Lain::Tools::MemoryRead.new(index: stored(body))) }.fetch(:result)
    end

    it "masks a stored credential, keeps the author line, says it cannot be released, and parks nothing" do
      result = recall(credential)

      expect(result).to have_attributes(is_error: false)
      expect(result.content).to start_with("author: chat\ndeploy notes\nDB_PASSWORD=<redacted:1>\n")
      expect(result.content.lines.last)
        .to eq("1 region was masked in this memory item; a memory item cannot be released.")
      expect(result.content).not_to include("hunter2pass")
      expect(queue.to_a).to be_empty
    end

    it "returns a clean body byte for byte" do
      clean = "the build uses rake pspec"

      expect(recall(clean)).to eq(Lain::Tool::Result.ok("author: chat\n#{clean}"))
    end

    # A known false positive, accepted: bash output masks it the same way. A
    # detector that narrows it turns this red on purpose.
    it "masks a substantial value under a name holding a credential word, as bash output does" do
      expect(recall("token_count = 123456").content).to start_with("author: chat\ntoken_count = <redacted:1>")
    end

    it "leaves a whole lineage digest unmasked, as lain's own content address" do
      digest = "blake3:#{OpenSSL::Digest::SHA256.hexdigest("a spawn")}"

      expect(recall("Lineage spawn: #{digest}")).to eq(Lain::Tool::Result.ok("author: chat\nLineage spawn: #{digest}"))
    end

    it "masks credentials on both sides of a lineage digest with 1 numbering across the pieces" do
      digest = "blake3:#{OpenSSL::Digest::SHA256.hexdigest("a spawn")}"

      expect(recall("API_KEY=#{api_key}\nspawn #{digest}\nDB_PASSWORD=hunter2pass\n").content)
        .to start_with("author: chat\nAPI_KEY=<redacted:1>\nspawn #{digest}\nDB_PASSWORD=<redacted:2>\n")
    end

    it "masks a 65-character hex token that only borrows the digest prefix" do
      forged = "blake3:#{OpenSSL::Digest::SHA256.hexdigest("x")}a"

      expect(recall("cite #{forged}").content).to start_with("author: chat\ncite blake3:<redacted:1>")
    end

    it "remembers on the session which item was read masked, and only that one" do
      recall(credential)

      expect(session.masked_memory?("note")).to be(true)
      expect(session.masked_memory?("other")).to be(false)
    end

    it "does not record a clean read as masked" do
      recall("the build uses rake pspec")

      expect(session.masked_memory?("note")).to be(false)
      expect(journal.grep(Lain::Telemetry::MemoryMasked)).to be_empty
    end

    it "journals the masked read by memory id and count, never the bytes" do
      recall(credential)

      expect(journal.grep(Lain::Telemetry::MemoryMasked))
        .to contain_exactly(have_attributes(tool_use_id: "tu_mem", id: "note", regions: 1))
    end

    describe "through a chat's guard stack" do
      let(:chronicle) do
        instance_double(Lain::CLI::Chronicle, record_journal: queue_journal,
                                              instrumentation: Lain::Agent::Instrumentation.new(journal: queue_journal))
      end
      let(:recorder) { Lain::Memory::Recorder.new(index: stored(credential)) }
      let(:toolset) do
        Lain::Toolset.new([Lain::Tools::MemoryRead.new(index: recorder),
                           Lain::Tools::MemoryWrite.new(recorder:, author: Lain::Memory::Author.chat)])
      end

      def board
        paths = Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => File.join(dir, "state") })
        project = Lain::Project.new(root: dir, cwd: dir, kind: :project, detected_by: :git)
        Lain::CLI::Wiring::BoardBuild.for(
          chronicle:, options: {}, judge: Lain::CLI::Switchboard::DEFERRING, model: "m", toolset:, project:, paths:,
          verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:)
        ).bind_session(session)
      end

      def recall_in_chat
        layers = Lain::CLI::ToolGuard.stack(chronicle, board).to_a
        dispatch_call("memory_read", { "id" => "note" }, toolset:, layers:, context: session)
      end

      it "masks the stored credential for a fresh chat's model" do
        result = Sync { |task| task.with_timeout(10) { recall_in_chat } }

        expect(result.content).to start_with("author: chat\ndeploy notes\nDB_PASSWORD=<redacted:1>\n")
        expect(result.content).not_to include("hunter2pass")
      end

      it "refuses to rewrite the item from that read, with no placeholder in the new body" do
        layers = Lain::CLI::ToolGuard.stack(chronicle, board).to_a
        input = { "id" => "note", "description" => "d", "body" => "deploy notes\nDB_PASSWORD=\n" }
        result = Sync do |task|
          task.with_timeout(10) { recall_in_chat }
          dispatch_call("memory_write", input, toolset:, layers:, context: session)
        end

        expect(result).to have_attributes(is_error: true, content: /read masked this session/)
        expect(recorder.fetch("note").body).to eq(credential)
      end
    end
  end

  describe "the absolute-path contract the ledger enforces" do
    it "resolves a relative path against the reading worker's cwd, never the process's" do
      write("notes.txt", one_secret)
      absolute = File.join(dir, "notes.txt")
      digest = Lain::Sensitivity::Regions.detect(one_secret).first.digest

      Sync do |task|
        run = task.async { dispatch(effect("notes.txt")) }
        approve(queue)
        run.wait
      end

      expect(ledger.released?(absolute, digest)).to be(true)
    end
  end
end
