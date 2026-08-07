# frozen_string_literal: true

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

  def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

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

    # One line per state transition, not per call -- `Session::Journaled`'s own
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

    # An approved read withheld nothing, so there is no redaction to record --
    # the approval's own decision record is what says a secret was sent.
    it "records nothing when the human approved the whole file" do
      read(write("notes.txt", one_secret)) { |q| approve(q) }

      expect(redactions).to be_empty
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
      expect(content.last).to eq(blocks.last)
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

  describe "its collaborators" do
    it "refuses to be built without a ledger, because a second ledger releases in silence" do
      expect { described_class.new(queue:, journal:) }.to raise_error(ArgumentError, /ledger/)
    end

    it "refuses to be built without a queue, so a forgotten one cannot become silent approval" do
      expect { described_class.new(ledger:, journal:) }.to raise_error(ArgumentError, /queue/)
    end

    # `nil` is not a missing keyword, and nil is exactly what
    # `Switchboard#approvals` carries under --yolo -- so without these the
    # "no default means no silent approval" argument rests on nobody ever
    # passing the value the wiring actually holds.
    it "refuses a nil ledger, which a missing-keyword check never sees" do
      expect { described_class.new(ledger: nil, queue:, journal:) }.to raise_error(ArgumentError, /ledger/)
    end

    it "refuses a nil queue for the same reason" do
      expect { described_class.new(ledger:, queue: nil, journal:) }.to raise_error(ArgumentError, /queue/)
    end

    # --yolo wires no queue at all (Switchboard#approvals is nil). Masking with
    # nowhere to park would leave the model `<redacted:1>` forever with no move,
    # so the flag's own meaning -- approve everything, ask nobody -- is what the
    # stand-in answers.
    it "sends the whole file under the unqueued stand-in --yolo wires" do
      path = write("notes.txt", one_secret)
      yolo = described_class.new(ledger:, queue: described_class::Unqueued.instance, journal:)

      content = Sync { dispatch(effect(path), subject_stack: Lain::Middleware::Stack.new([yolo])) }
                .fetch(:result).content

      expect(content).to eq(one_secret)
      expect(session.read?(path)).to be(true)
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
