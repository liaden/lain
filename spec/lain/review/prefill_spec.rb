# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"

RSpec.describe Lain::Review::Prefill do
  # One sidecar line, as the critique skill writes it. Built through JSON rather
  # than as a literal so a test for a MALFORMED line is unmistakably the odd one
  # out -- every other line here is well-formed by construction.
  def line(path: "lib/lain/review/session.rb", line: 248, rank: "BLOCKER",
           text: "the journal is written before the mark set is updated", side: nil)
    fields = { "path" => path, "line" => line, "rank" => rank, "text" => text }
    fields["side"] = side if side
    JSON.generate(fields)
  end

  def sidecar(*lines) = lines.map { |source| "#{source}\n" }.join

  # Three findings on one file, one at each rank -- the shape the acceptance
  # criteria describe.
  def three
    sidecar(line(line: 10, rank: "BLOCKER", text: "unvalidated write reaches the store"),
            line(line: 20, rank: "SHOULD-FIX", text: "two responsibilities in one object"),
            line(line: 30, rank: "NIT", text: "this comment restates the code"))
  end

  def loaded = described_class.load(three)

  describe "the rank map, derived rather than restated" do
    it "gives each critique rank the annotation kind that shares its severity tier" do
      expect(described_class::KINDS).to eq("BLOCKER" => "blocker", "SHOULD-FIX" => "question", "NIT" => "note")
    end

    # The DERIVATION itself, as a law rather than as a second copy of the table
    # above: whatever tier T17 puts a rank on, this map's kind must land on the
    # same tier. Change either of T17's maps and this fails, which is the whole
    # reason the correspondence is computed and not written down twice.
    it "puts every rank's kind on the tier the projection already ranks that rank at" do
      severities = Lain::Review::Projection::Diagnostics::SEVERITIES
      Lain::Review::Projection::Diagnostics::RANKS.each do |rank, severity|
        expect(severities.fetch(described_class::KINDS.fetch(rank))).to eq(severity)
      end
    end

    it "covers exactly the ranks the projection knows, so a fourth rank cannot arrive unranked" do
      expect(described_class::KINDS.keys).to eq(Lain::Review::Projection::Diagnostics::RANKS.keys)
    end

    # The one way the derivation could go quietly wrong: `to_h` inverting a map
    # where two kinds share a tier drops one of them and hands a rank the
    # SURVIVING kind, silently. Refused instead, naming the tier.
    it "refuses to invert a severity map two kinds share a tier in" do
      expect { described_class.invert("note" => "HINT", "aside" => "HINT") }
        .to raise_error(described_class::AmbiguousTier, /HINT.*"note".*"aside"/m)
    end

    it "inverts an injective map to severity => kind" do
      expect(described_class.invert("note" => "HINT", "blocker" => "ERROR"))
        .to eq("HINT" => "note", "ERROR" => "blocker")
    end
  end

  describe "loading a sidecar" do
    it "reads one finding per line, in the order the critique wrote them" do
      expect(loaded.map(&:line)).to eq([10, 20, 30])
      expect(loaded.map(&:rank)).to eq(%w[BLOCKER SHOULD-FIX NIT])
      expect(loaded.count).to eq(3)
    end

    it "carries each finding's path and words through unchanged" do
      finding = loaded.first

      expect(finding.path).to eq("lib/lain/review/session.rb")
      expect(finding.text).to eq("unvalidated write reaches the store")
    end

    it "ranks each finding as the annotation kind its tier maps to" do
      expect(loaded.map(&:kind)).to eq(%w[blocker question note])
    end

    it "takes the new side when a finding does not say, because a critique reviews the change as it stands" do
      expect(loaded.map(&:side).uniq).to eq(["new"])
    end

    it "takes the old side when a finding says so, for a line the change deleted" do
      expect(described_class.load(sidecar(line(side: "old"))).first.side).to eq("old")
    end

    it "reads a last line with no trailing newline, which is a whole finding and not half of one" do
      expect(described_class.load(line(line: 7)).map(&:line)).to eq([7])
    end

    it "loads a critique that found nothing to no findings at all" do
      expect(described_class.load("")).to be_none
      expect(described_class.load("").submittable).to eq([])
    end

    it "is frozen, so a loaded sidecar cannot be grown behind a caller's back" do
      expect(loaded).to be_frozen
      expect(loaded.findings).to be_frozen
      expect(loaded.first).to be_frozen
    end
  end

  # The defect octo shipped (`gh/init.lua:170-182` turned a crash into a quietly
  # truncated list): a finding dropped in silence is a finding the human never
  # gets to disagree with, and every count still looks right afterwards. So each
  # example asserts BOTH that it refuses and that it names WHICH line -- a
  # refusal that cannot say where is barely better than a skip.
  describe "a malformed line refuses the whole sidecar and names the line" do
    it "refuses a line that is not JSON, naming its number" do
      broken = sidecar(line(line: 1), "{not json", line(line: 3))

      expect { described_class.load(broken) }.to raise_error(described_class::Malformed, /line 2/)
    end

    # The other half of the same defect, and the one a refusal cannot prove: a
    # loader that quietly dropped a line it did not like would still look right
    # here unless the count is asserted against the sidecar's own length.
    it "answers one finding for every line of a sidecar it accepts" do
      lines = (1..5).map { |n| line(line: n * 10, text: "finding #{n}") }

      expect(described_class.load(sidecar(*lines)).count).to eq(5)
      expect(described_class.load(sidecar(*lines)).map(&:text)).to eq((1..5).map { |n| "finding #{n}" })
    end

    it "refuses a blank line rather than skipping it" do
      expect { described_class.load(sidecar(line(line: 1), "", line(line: 3))) }
        .to raise_error(described_class::Malformed, /line 2/)
    end

    it "refuses a JSON value that is not a finding object, naming the line and what it found" do
      expect { described_class.load(sidecar(line, "[1, 2]")) }
        .to raise_error(described_class::Malformed, /line 2.*Array/m)
    end

    it "refuses a rank outside the three the critique skill ranks by, naming the line and the ranks" do
      expect { described_class.load(sidecar(line, line(rank: "MAJOR"))) }
        .to raise_error(described_class::Malformed, %r{line 2.*BLOCKER/SHOULD-FIX/NIT.*"MAJOR"}m)
    end

    it "refuses a line number no position can have, naming the line it was on" do
      expect { described_class.load(sidecar(line, line, line(line: 0))) }
        .to raise_error(described_class::Malformed, /line 3/)
    end

    it "refuses a quoted line number rather than coercing one" do
      expect { described_class.load(sidecar(line(line: "248"))) }
        .to raise_error(described_class::Malformed, /line 1/)
    end

    it "refuses a finding with no path" do
      expect { described_class.load(sidecar(line(path: ""))) }
        .to raise_error(described_class::Malformed, /line 1.*path/m)
    end

    it "refuses a finding whose words are blank, which is evidence of nothing" do
      expect { described_class.load(sidecar(line, line(text: "   "))) }
        .to raise_error(described_class::Malformed, /line 2/)
    end

    it "refuses a side that names neither half of a diff" do
      expect { described_class.load(sidecar(line(side: "both"))) }
        .to raise_error(described_class::Malformed, /line 1.*both/m)
    end

    # BOTH line numbers and the finding itself: in a 200-line sidecar the two
    # copies are identical sentences, so a refusal that says only "repeated"
    # leaves the human grepping for the difference between them.
    it "refuses a sidecar that repeats one finding, naming both lines it was written on" do
      expect { described_class.load(sidecar(line, line(line: 9), line)) }
        .to raise_error(described_class::Malformed, /lines 1 and 3/)
    end

    it "names the repeated finding, not merely the fact of a repeat" do
      expect { described_class.load(sidecar(line, line)) }
        .to raise_error(described_class::Malformed, /session\.rb:248 \(BLOCKER\)/)
    end

    # The same condition on the OTHER path. A caller building findings in memory
    # reaches the constructor without a sidecar, so there are no line numbers to
    # give -- but the refusal still has to happen, or two findings share one
    # address and an edit silently promotes whichever the index happened to keep.
    it "refuses a repeat among findings built in memory, where there are no lines to name" do
      finding = loaded.first

      expect { described_class.new(findings: [finding, finding]) }
        .to raise_error(described_class::Malformed, /repeats the finding.*twice/m)
    end
  end

  describe "a finding's identity" do
    it "addresses a finding by its content, so two loads of one sidecar agree" do
      expect(described_class.load(three).map(&:id)).to eq(loaded.map(&:id))
    end

    it "gives two findings differing only in their words different addresses" do
      one = described_class.load(sidecar(line(text: "a"))).first
      other = described_class.load(sidecar(line(text: "b"))).first

      expect(one.id).not_to eq(other.id)
    end

    it "carries its scheme, so an address is never mistaken for another kind of key" do
      expect(loaded.first.id).to start_with("review-finding-v1:")
    end

    it "keeps its address when it is placed, so a promotion survives the editor moving it" do
      finding = loaded.first

      expect(finding.at(41).id).to eq(finding.id)
      expect(finding.at(41).mark).to eq(41)
    end

    it "refuses to be placed at anything but an extmark id" do
      expect { loaded.first.at(nil) }.to raise_error(described_class::Unplaced)
      expect { loaded.first.at("41") }.to raise_error(described_class::Unplaced)
    end

    it "is unplaced as it comes off the sidecar, because only the editor knows where a line is" do
      expect(loaded.first).not_to be_placed
      expect(loaded.first.mark).to be_nil
    end
  end

  # `Ractor.shareable?` is the MECHANICAL statement of "no reachable mutable
  # state", and every field here arrives from `JSON.parse` -- which answers
  # mutable Strings -- or from `Symbol#to_s`, which does too. Dropping any one of
  # the three interning `-` operators leaves a frozen Data holding a mutable
  # String, which no other example in this file can see.
  describe "a finding is deeply frozen" do
    it "is shareable, path, side, rank and words together" do
      expect(Ractor.shareable?(loaded.first)).to be(true)
    end

    it "is still shareable once the editor has placed it" do
      expect(Ractor.shareable?(loaded.first.at(41))).to be(true)
    end

    it "carries a promotion's words into a shareable value too" do
      promoted = loaded.edit(loaded.first.id, "guard the write").submittable.first

      expect(Ractor.shareable?(promoted)).to be(true)
    end

    it "holds a whole loaded sidecar, promotions and all, with nothing mutable reachable" do
      expect(Ractor.shareable?(loaded.edit(loaded.first.id, "guard the write"))).to be(true)
    end
  end

  # {#edit}'s refusals have to be the OBJECT's, not one method's: the constructor
  # is reachable, and a promotion built around it would otherwise carry an id
  # this sidecar never held or words it exists to refuse.
  describe "the constructor enforces what an edit does" do
    it "refuses a promotion under an id this sidecar does not hold" do
      expect { described_class.new(findings: loaded.to_a, promotions: { "review-finding-v1:nope" => "mine" }) }
        .to raise_error(described_class::UnknownFinding, /nope/)
    end

    it "refuses a promotion with nothing in it" do
      expect { described_class.new(findings: loaded.to_a, promotions: { loaded.first.id => "  " }) }
        .to raise_error(described_class::Blank)
    end

    it "keeps a legitimate promotion, so the refusals are not simply a closed door" do
      built = described_class.new(findings: loaded.to_a, promotions: { loaded.first.id => "mine now" })

      expect(built.submittable.map(&:text)).to eq(["mine now"])
    end
  end

  # The id index lives here, so the id-to-mark map does too: a caller keeping its
  # own beside the prefill keeps a second record of one position.
  describe "placing a finding" do
    it "gives one finding its extmark and leaves the rest unplaced" do
      placed = loaded.place(loaded.first.id, 41)

      expect(placed.map(&:mark)).to eq([41, nil, nil])
      expect(loaded.map(&:mark)).to eq([nil, nil, nil])
    end

    it "keeps the promotions it already had, so placing is not a reset" do
      placed = loaded.edit(loaded.first.id, "mine now").place(loaded.first.id, 41)

      expect(placed.submittable.map(&:text)).to eq(["mine now"])
      expect(placed.first.mark).to eq(41)
    end

    it "refuses to place a finding this sidecar does not hold" do
      expect { loaded.place("review-finding-v1:nope", 41) }.to raise_error(described_class::UnknownFinding)
    end

    it "refuses anything that is not an extmark id" do
      expect { loaded.place(loaded.first.id, "41") }.to raise_error(described_class::Unplaced)
    end
  end

  # Joel's ruling: a posted comment is his responsibility and triaging it is his
  # obligation, so there is no bulk accept. Promotion is per-finding, and the
  # gesture that promotes is an EDIT.
  describe "promotion is per-finding" do
    it "holds a fresh finding out of the submittable set" do
      expect(loaded.submittable).to eq([])
      expect(loaded.unpromoted.count).to eq(3)
      expect(loaded.any? { |finding| loaded.promoted?(finding.id) }).to be(false)
    end

    it "promotes the one finding that was edited and no other" do
      prefill = loaded
      promoted = prefill.edit(prefill.first.id, "the write reaches the store unvalidated -- guard it")

      expect(promoted.submittable.map(&:text)).to eq(["the write reaches the store unvalidated -- guard it"])
      expect(promoted.unpromoted.map(&:line)).to eq([20, 30])
    end

    # The dual of the bulk-accept mutant, and what that one does not cover: an
    # `edit` that REPLACED the promotion map rather than merging into it would
    # silently un-promote the first finding, and every count in the examples
    # around this one would still read right. Per-finding means each promotion
    # arrives AND stays.
    it "promotes a second finding without un-promoting the first" do
      prefill = loaded
      two = prefill.edit(prefill.first.id, "guard the write").edit(prefill.to_a[1].id, "split the object")

      expect(two.submittable.map(&:text)).to eq(["guard the write", "split the object"])
      expect(two.submittable.map { |promotion| promotion.origin.line }).to eq([10, 20])
      expect(two.unpromoted.map(&:line)).to eq([30])
    end

    it "keeps every promotion when a third arrives, in the sidecar's own order" do
      prefill = loaded
      all = prefill.inject(prefill) { |carried, finding| carried.edit(finding.id, "mine: #{finding.line}") }

      expect(all.submittable.map(&:text)).to eq(["mine: 10", "mine: 20", "mine: 30"])
      expect(all.submittable.map { |promotion| promotion.origin.rank }).to eq(%w[BLOCKER SHOULD-FIX NIT])
      expect(all.unpromoted).to eq([])
    end

    it "carries the finding it came from, so the critique's own words survive the edit" do
      prefill = loaded
      promoted = prefill.edit(prefill.first.id, "guard the write").submittable.first

      expect(promoted.origin).to eq(prefill.first)
      expect(promoted.origin.text).to eq("unvalidated write reaches the store")
      expect(promoted.rank).to eq("BLOCKER")
    end

    it "promotes a finding the human agreed with verbatim, because the gesture is the human's" do
      prefill = loaded
      same = prefill.edit(prefill.first.id, prefill.first.text)

      expect(same.submittable.map(&:text)).to eq(["unvalidated write reaches the store"])
    end

    it "leaves the prefill it was asked from untouched, so nothing is promoted by reference" do
      prefill = loaded
      prefill.edit(prefill.first.id, "mine now")

      expect(prefill.submittable).to eq([])
    end

    it "drops a finding nobody edited: it is simply never submittable" do
      prefill = loaded.edit(loaded.first.id, "mine now")

      expect(prefill.submittable.map(&:line)).to eq([10])
      expect(prefill.count).to eq(3)
    end

    it "refuses an edit naming a finding this sidecar does not hold" do
      expect { loaded.edit("review-finding-v1:deadbeef", "mine now") }
        .to raise_error(described_class::UnknownFinding, /deadbeef/)
    end

    it "refuses a promotion with nothing in it, because ignoring is how a finding is dropped" do
      prefill = loaded

      expect { prefill.edit(prefill.first.id, "  ") }.to raise_error(described_class::Blank)
    end

    it "answers promoted? only about findings it holds" do
      prefill = loaded.edit(loaded.first.id, "mine now")

      expect(prefill.promoted?(prefill.first.id)).to be(true)
      expect(prefill.promoted?(prefill.to_a[1].id)).to be(false)
      expect { prefill.promoted?("review-finding-v1:nope") }.to raise_error(described_class::UnknownFinding)
    end
  end

  # What a promoted finding is FOR: it has to satisfy the record the review
  # journals, or promotion is a gesture that leads nowhere. Pinned against the
  # real record rather than against a restatement of its fields.
  describe "a promoted finding becomes the human's own annotation" do
    let(:promoted) { loaded.edit(loaded.first.id, "guard the write before it reaches the store").submittable.first }

    it "anchors at the position the critique named" do
      anchor = Lain::Review::Anchor.new(path: promoted.path, side: promoted.side, line: promoted.line,
                                        anchor_text: "  store.write(payload)", revision: "abc1234")

      expect(anchor.path).to eq("lib/lain/review/session.rb")
      expect(anchor.line).to eq(10)
      expect(anchor.side).to eq(:new)
    end

    it "journals the human's words under the kind the rank maps to" do
      anchor = Lain::Review::Anchor.new(path: promoted.path, side: promoted.side, line: promoted.line,
                                        anchor_text: "  store.write(payload)", revision: "abc1234")
      placed = Lain::Review::AnnotationPlaced.new(id: anchor.id, path: anchor.path, side: anchor.side,
                                                  line: anchor.line, anchor_text: anchor.anchor_text,
                                                  text: promoted.text, kind: promoted.kind, drifted: false,
                                                  revision: anchor.revision)

      expect(placed.text).to eq("guard the write before it reaches the store")
      expect(placed.kind).to eq("blocker")
    end
  end

  describe "the findings' own diagnostic namespace" do
    it "is not the namespace the human's own notes render in" do
      expect(described_class::PROJECTION.namespace).to eq("lain_review_findings")
      expect(described_class::PROJECTION.namespace)
        .not_to eq(Lain::Review::Projection::Diagnostics::DEFAULT_NAMESPACE)
    end

    it "attributes every entry to the critique, so a suggestion is visibly a suggestion" do
      expect(described_class::PROJECTION.source).to eq("critique")
      expect(described_class::PROJECTION.source)
        .not_to eq(Lain::Review::Projection::Diagnostics::DEFAULT_SOURCE)
    end

    it "sends the editor the buffer, the findings' namespace and one entry per finding" do
      placed = loaded.map.with_index { |finding, i| finding.at(i + 1) }
      buffer, namespace, entries = described_class.arguments(12, placed)

      expect([buffer, namespace]).to eq([12, "lain_review_findings"])
      expect(entries.map { |entry| entry["severity"] }).to eq(%w[ERROR WARN HINT])
      expect(entries.map { |entry| entry["mark"] }).to eq([1, 2, 3])
    end

    it "refuses to render a finding the editor has not placed, rather than sending a null mark" do
      expect { described_class.arguments(12, loaded.to_a) }
        .to raise_error(described_class::Unplaced, /session\.rb/)
    end
  end

  describe "the sidecar sits beside the prose" do
    it "takes the prose's name with the sidecar suffix in place of its extension" do
      expect(described_class::Sidecar.beside(".critique-core.md")).to eq(".critique-core.findings.jsonl")
      expect(described_class::Sidecar.beside("reviews/2026-08-04.md")).to eq("reviews/2026-08-04.findings.jsonl")
    end

    it "appends to a name with no extension rather than eating part of it" do
      expect(described_class::Sidecar.beside("critique")).to eq("critique.findings.jsonl")
    end

    # The extension is a SUFFIX. A pattern would take the first `.md` it found
    # and move the sidecar into another directory, where nobody would look for
    # it and nothing would say why.
    it "strips only the trailing extension, never one inside a directory name" do
      expect(described_class::Sidecar.beside("docs.md/critique.md")).to eq("docs.md/critique.findings.jsonl")
    end

    it "refuses a prose path that names nothing, rather than answering a bare suffix" do
      expect { described_class::Sidecar.beside(nil) }.to raise_error(Lain::Review::Anchor::InvalidField)
      expect { described_class::Sidecar.beside("") }.to raise_error(Lain::Review::Anchor::InvalidField)
    end
  end

  # The prose and the parser cannot be allowed to drift: the template is the ONLY
  # thing that tells a critique what to write, and a schema it teaches that this
  # parser refuses would produce a sidecar nothing can load -- which is exactly
  # the two-independent-declarations trap the vocabulary file exists to prevent.
  # So the shipped template's own example is loaded through the real parser.
  describe "the shipped critique skill teaches the schema this parser reads" do
    def shipped_scaffold
      Dir.mktmpdir do |root|
        Lain::Skill::Renderer.new(catalog: Lain::Skill::Catalog.load(root:),
                                  slots: Lain::Prompt::Slots.load(root:)).render("critique")
      end
    end

    def examples(scaffold) = scaffold.scan(/^```jsonl\r?\n(.*?)^```[ \t]*$/m).flatten

    it "shows at least one sidecar example" do
      expect(examples(shipped_scaffold)).not_to be_empty
    end

    it "loads every example it shows through this parser" do
      examples(shipped_scaffold).each do |source|
        expect { described_class.load(source) }.not_to raise_error
        expect(described_class.load(source).count).to be_positive
      end
    end

    it "shows every rank, so no rank is taught only by the prose" do
      ranks = examples(shipped_scaffold).flat_map { |source| described_class.load(source).map(&:rank) }

      expect(ranks.uniq).to match_array(described_class::KINDS.keys)
    end

    it "shows the old side, which is the one field a finding may leave out" do
      sides = examples(shipped_scaffold).flat_map { |source| described_class.load(source).map(&:side) }

      expect(sides.uniq).to match_array(Lain::Review::SIDES)
    end

    it "names the sidecar's own suffix rather than a second spelling of it" do
      expect(shipped_scaffold).to include(described_class::Sidecar::SUFFIX)
    end

    it "says a line that cannot be read refuses the sidecar, so a critique does not expect a skip" do
      expect(shipped_scaffold).to match(/refus/i)
    end
  end
end

# The namespace half, driven against a REAL nvim, because "a finding renders in
# its own namespace" is a claim about what `vim.diagnostic` does with two
# namespaces on one buffer -- and the whole point of the separation is that a
# human can see which of two records a comment came from.
#
# The extmark namespace is NOT split, and that is deliberate: `49_diagnostics.lua`
# resolves every entry's mark through ONE anchors namespace, so a finding's
# position is an extmark beside the human's while its DIAGNOSTIC renders apart
# from it. Splitting the position store would be a change to T17's lua, which is
# not this card's to make.
RSpec.describe "review findings in their own diagnostic namespace", :nvim, :seam do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-prefill-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    # `-n` -- no swap file. Every example here makes a real buffer, and nvim's
    # global swap directory is shared with every sibling worktree's specs; a
    # mutation run that fills it dies with `E326: Too many swap files found`,
    # which looks exactly like a mutant being killed.
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @editor = Neovim.attach_unix(socket)
    @editor.exec_lua(Lain::Frontend::Neovim::RuntimeLoader.new.source,
                     [Lain::VERSION, Lain::Frontend::Neovim::PROTOCOL, @editor.channel_id])
    example.run
  ensure
    @editor = nil
    if pid
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.rm_f(socket)
  end

  def lua(source, args = []) = @editor.exec_lua(source, args)

  def review_buffer
    lua(<<~LUA, [(1..12).map { |i| "line #{i}" }])
      local content = ...
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
      vim.b[buf].lain_review_side = "new"
      return buf
    LUA
  end

  # An anchor extmark in the namespace the positions live in -- the one store
  # `49_diagnostics.lua` reads, for a human's note and a finding alike.
  def anchor(buf, row)
    lua(<<~LUA, [buf, row])
      local b, row = ...
      return vim.api.nvim_buf_set_extmark(b, vim.api.nvim_create_namespace("lain_review_annotations"), row, 0, {})
    LUA
  end

  def set(buf, namespace, entries)
    lua("_G.__lain.set_review_diagnostics(...)", [buf, namespace, entries])
  end

  def messages(buf, namespace)
    lua(<<~LUA, [buf, namespace])
      local b, name = ...
      local found = {}
      for _, d in ipairs(vim.diagnostic.get(b, { namespace = vim.api.nvim_create_namespace(name) })) do
        table.insert(found, { d.lnum, d.message, d.source })
      end
      table.sort(found, function(x, y) return x[1] < y[1] end)
      return found
    LUA
  end

  def findings_in(buf) = messages(buf, Lain::Review::Prefill::PROJECTION.namespace)

  def annotations_in(buf)
    messages(buf, Lain::Review::Projection::Diagnostics::DEFAULT_NAMESPACE)
  end

  def sidecar
    [{ "path" => "lib/widget.rb", "line" => 2, "rank" => "BLOCKER", "text" => "unvalidated write" },
     { "path" => "lib/widget.rb", "line" => 5, "rank" => "SHOULD-FIX", "text" => "two responsibilities" },
     { "path" => "lib/widget.rb", "line" => 8, "rank" => "NIT", "text" => "the comment restates" }]
      .map { |fields| "#{JSON.generate(fields)}\n" }.join
  end

  # The human's own note, as T17's duck: mark, words, kind. Not an
  # AnnotationPlaced -- that record carries a line, which must never cross.
  def human(mark) = Data.define(:mark, :text, :kind).new(mark:, text: "my own note", kind: "question")

  # Every finding placed at its line's extmark, as the caller holding the buffer
  # would: the sidecar names a line, the editor answers with a mark, and the
  # prefill keeps the pairing -- no second map beside it.
  def placed(buf, prefill)
    prefill.inject(prefill) { |carried, finding| carried.place(finding.id, anchor(buf, finding.line - 1)) }
  end

  it "holds three findings in the finding namespace and one note in the annotations'" do
    buf = review_buffer
    prefill = Lain::Review::Prefill.load(sidecar)
    set(buf, *Lain::Review::Prefill.arguments(buf, placed(buf, prefill).to_a).drop(1))
    set(buf, *Lain::Review::Projection::Diagnostics.new.arguments(buf, [human(anchor(buf, 10))]).drop(1))

    expect(findings_in(buf).map { |d| d[1] })
      .to eq(["unvalidated write", "two responsibilities", "the comment restates"])
    expect(annotations_in(buf).map { |d| d[1] }).to eq(["my own note"])
  end

  it "attributes a finding to the critique and a note to the review, on the same buffer" do
    buf = review_buffer
    prefill = Lain::Review::Prefill.load(sidecar)
    set(buf, *Lain::Review::Prefill.arguments(buf, placed(buf, prefill).to_a).drop(1))
    set(buf, *Lain::Review::Projection::Diagnostics.new.arguments(buf, [human(anchor(buf, 10))]).drop(1))

    expect(findings_in(buf).map(&:last).uniq).to eq(["critique"])
    expect(annotations_in(buf).map(&:last).uniq).to eq(["review"])
  end

  it "clears the findings without touching the human's note" do
    buf = review_buffer
    prefill = Lain::Review::Prefill.load(sidecar)
    set(buf, *Lain::Review::Prefill.arguments(buf, placed(buf, prefill).to_a).drop(1))
    set(buf, *Lain::Review::Projection::Diagnostics.new.arguments(buf, [human(anchor(buf, 10))]).drop(1))
    set(buf, Lain::Review::Prefill::PROJECTION.namespace, [])

    expect(findings_in(buf)).to eq([])
    expect(annotations_in(buf).map { |d| d[1] }).to eq(["my own note"])
  end

  # Promotion, on screen: the edited finding stops being a suggestion, and the
  # two that were ignored are still there waiting to be triaged.
  it "leaves the unpromoted findings rendering once one has been promoted" do
    buf = review_buffer
    prefill = placed(buf, Lain::Review::Prefill.load(sidecar))
    promoted = prefill.edit(prefill.first.id, "guard the write")
    set(buf, *Lain::Review::Prefill.arguments(buf, promoted.unpromoted).drop(1))

    expect(findings_in(buf).map { |d| d[1] }).to eq(["two responsibilities", "the comment restates"])
  end

  # Drift is detected by comparing CONTENT, never by asking whether a mark
  # survived: marks inside a rewritten span MOVE rather than invalidate. So the
  # finding's rendered row follows the edit, and the LINE the sidecar named does
  # not -- which is why nothing here re-reads `finding.line` after an edit.
  it "re-renders a finding at the row its mark moved to, not the line the sidecar named" do
    buf = review_buffer
    prefill = Lain::Review::Prefill.load(sidecar)
    set(buf, *Lain::Review::Prefill.arguments(buf, placed(buf, prefill).to_a).drop(1))
    lua("local b = ... vim.api.nvim_buf_set_lines(b, 0, 0, false, { 'inserted', 'inserted' })", [buf])
    lua("_G.__lain.refresh_review_diagnostics(...)", [buf])

    expect(findings_in(buf).map(&:first)).to eq([3, 6, 9])
    expect(prefill.map(&:line)).to eq([2, 5, 8])
  end
end
