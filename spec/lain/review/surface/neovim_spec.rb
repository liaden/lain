# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# The inlet as this surface uses it: {Lain::Frontend::Neovim::RenderInlet}'s
# four review methods, recorded rather than sent. EXPLICIT methods, never
# `def_delegators` or a `method_missing` catch-all -- `Surface.check!` refuses
# the `(*args, &block)` shape those generate, and a double that cannot be
# handed to the same check as the subject is a double that has already drifted.
#
# The transcript is what CROSSED the rail, joined into one String: the lines a
# render posted, the anchor id and lines a thread post carried, the sentence a
# notice carried. That is deliberately NOT a log of which port method ran --
# recording "#mark was called" would make the shared group's transcript law
# vacuous in exactly the way its own doc warns about, because it would prove
# the call happened rather than that anything left the surface.
class RecordingReviewInlet
  def initialize(refusal: nil)
    @refusal = refusal
    @posted = []
  end

  # @return [Array<Array>] one entry per post: `[verb, *arguments]`
  attr_reader :posted

  def set_review(lines, generation)
    @posted << [:set_review, lines, generation]
    @refusal
  end

  def open_changeset(path, old_lines, line, revisions)
    @posted << [:open_changeset, path, old_lines, line, revisions]
    @refusal
  end

  def set_thread(anchor_id, lines)
    @posted << [:set_thread, anchor_id, lines]
    @refusal
  end

  def review_refused(message)
    @posted << [:review_refused, message]
    @refusal
  end

  # Everything that reached the editor, as text. Arrays are flattened because a
  # render posts lines and a notice posts a sentence, and the shared group's
  # laws ask one question of both: did this argument get out of the surface.
  def transcript = @posted.map { |entry| entry.drop(1).flatten.join("\n") }.join("\n")
end

# One changed file on disk, for the seam that drives a real editor. Four small
# text files rather than a git repository, `diff_mode_spec.rb`'s fixture choice
# and its reason: Ruby runs git and the editor is only ever sent lines.
module NeovimSurfaceFixture
  PROJECT = Dir.mktmpdir("lain-review-surface-spec")

  FileUtils.mkdir_p(File.join(PROJECT, "lib"))
  File.write(File.join(PROJECT, "lib/a.rb"), "class A\nend\n")

  at_exit { FileUtils.remove_entry(PROJECT) if File.directory?(PROJECT) }
end

# The session as this surface's gesture leg uses it. A recorder rather than a
# double so "and no other" is a claim about what actually arrived, not about how
# many times a message was received.
#
# `refuse_from:` is what makes the partial case reachable: a session that takes
# the first key of a row and refuses the second leaves the row half marked, and
# a leg that reported that as a landed mark is the defect a review panel found.
class RecordingReviewSession
  def initialize(refusal: nil, refuse_from: 0)
    @refusal = refusal
    @refuse_from = refuse_from
    @marked = []
    @seen = 0
  end

  attr_reader :marked

  def mark(hunk_key, state)
    @seen += 1
    return @refusal if @refusal && @seen > @refuse_from

    @marked << [hunk_key, state]
  end
end

# The thread rail's ONE owner, recorded rather than posted: what this surface
# owes {Frontend::Neovim::ThreadView} is an anchor and the ENTRIES a note
# becomes, and a recorder is how "it went through the view" is told apart from
# "it happened to reach the same rail".
class RecordingThreadView
  attr_reader :shown

  def initialize = (@shown = [])

  def show(anchor, entries = [])
    @shown << [anchor, entries]
    nil
  end
end

RSpec.describe Lain::Review::Surface::Neovim do
  # A FRESH surface, a FRESH inlet and a FRESH view per example -- RSpec's
  # per-example memoization, which is the freshness the shared example group's
  # ordering law depends on and cannot enforce itself (see that group's doc).
  subject(:surface) { described_class.new(rpc: inlet, view:, session:) }

  let(:inlet) { RecordingReviewInlet.new }
  let(:view) { Lain::Frontend::Neovim::ReviewView.new }
  let(:session) { RecordingReviewSession.new }

  # A REAL Review::Hunk, not a Struct answering `#new_start`: T14 keys a row's
  # hunks so a mark gesture can resolve to one, and `Hunk.keys` reaches for
  # `#content_key`. A double that stopped at the member this view happens to
  # render would pass every rendering example and crash the gesture.
  def hunk(path:, new_start: 4)
    Lain::Review::Hunk.new(path:, old_start: new_start + 500, old_count: 1, new_start:, new_count: 1,
                           lines: [" #{path}:#{new_start}"])
  end

  # `#hunk_keys` and `#chunked?` are {Lain::Review::Session::MarkedChangeset::FileRow}'s,
  # and the view reads them rather than deriving keys of its own -- so a double
  # stopping at `#hunks` would resolve every gesture to nothing.
  def file_entry(path:, state:, hunks: nil)
    hunks ||= [hunk(path:)]
    Struct.new(:path, :state, :hunks, :hunk_keys, :rendered_lines) do
      def chunked? = true
    end.new(path, state, hunks, Lain::Review::Hunk.keys(hunks), hunks.size)
  end

  # `#counted?`: a diff's files are read as they are parsed, so every group of
  # one is counted and its heading shows the figures it always did.
  def commit_entry(subject:, files:, added: 3, deleted: 1)
    Struct.new(:label, :files, :added, :deleted, :rendered_lines) do
      def counted? = true
    end.new(subject, files, added, deleted, 0)
  end

  def changeset(files:, commits: [])
    Struct.new(:files, :partitions).new(files, commits)
  end

  def reviewed = file_entry(path: "lib/a.rb", state: :reviewed)

  # TWO hunks, because a one-hunk file cannot tell "marks every hunk this row
  # names" from "marks the first" -- a mutant that took `.first(1)` survived
  # against a single-hunk fixture.
  def partial
    file_entry(path: "lib/b.rb", state: :partial,
               hunks: [hunk(path: "lib/b.rb", new_start: 4), hunk(path: "lib/b.rb", new_start: 88)])
  end

  def unreviewed = file_entry(path: "lib/c.rb", state: :unreviewed)

  def two_commit_changeset
    changeset(files: [reviewed, partial, unreviewed],
              commits: [commit_entry(subject: "add a.rb", files: [reviewed]),
                        commit_entry(subject: "touch b.rb and c.rb", files: [partial, unreviewed])])
  end

  def real_anchor(path: "lib/lain/agent.rb", line: 14)
    Lain::Review::Anchor.new(path:, side: :new, line:, anchor_text: "  @store.write(input)", revision: "abc123")
  end

  it_behaves_like "a review surface",
                  changeset: -> { two_commit_changeset },
                  anchor: -> { real_anchor },
                  transcript: -> { inlet.transcript }

  it "passes Surface.check! -- the whole port, publicly, with the right shapes" do
    expect { Lain::Review::Surface.check!(surface) }.not_to raise_error
  end

  # `Surface.check!` compares KINDS plus KEYWORD names and leaves positional
  # names free -- relaxed by this card after a review panel hit
  # `def thread(_anchor)` being refused as "the wrong shape", which is a rename
  # and not a defect. Pinned HERE rather than left to whichever surface happens
  # to satisfy it, because the relaxation is this card's and both of its edges
  # have to stay where they were put: a mutant that dropped keyword names too
  # survived the entire suite without these.
  describe "the shape Surface.check! compares" do
    it "accepts a surface whose positional arguments are underscore-named" do
      renamed = Class.new do
        def present(_changeset, scope:) = scope && nil
        def annotate(_anchor, _text, kind:) = kind && nil
        def mark(_hunk_key, _state) = nil
        def thread(_anchor) = nil
        def verdict = nil
        def refuse(_message) = nil
      end.new

      expect { Lain::Review::Surface.check!(renamed) }.not_to raise_error
    end

    # A keyword IS its name at every call site, so renaming one is a port
    # change rather than the method's private business -- the half that must
    # NOT relax.
    it "still refuses a surface whose keyword was renamed" do
      wrong = Class.new do
        def present(changeset, at:) = [changeset, at].compact && nil
        def annotate(anchor, text, kind:) = [anchor, text, kind].compact && nil
        def mark(hunk_key, state) = [hunk_key, state].compact && nil
        def thread(anchor) = anchor && nil
        def verdict = nil
        def refuse(message) = message && nil
      end.new

      expect { Lain::Review::Surface.check!(wrong) }
        .to raise_error(Lain::Review::Surface::Incomplete, /answers present with the wrong shape/)
    end

    # The T4 panel's ruling, unchanged by the relaxation: `Forwardable` and
    # `SimpleDelegator` generate `(*args, &block)`, whose KINDS are not the
    # port's, so a delegation-based adapter is still refused before
    # construction rather than at first use.
    it "still refuses a delegation-based adapter, whose (*args, &block) is not the port" do
      delegating = Class.new do
        def method_missing(*) = nil
        def respond_to_missing?(*) = true
      end.new

      expect { Lain::Review::Surface.check!(delegating) }.to raise_error(Lain::Review::Surface::Incomplete)
    end
  end

  # The double is only evidence while it answers what the real inlet answers.
  # Pinned against {RenderInlet}'s own `Method#parameters`, the same mechanism
  # `Surface::MESSAGES` uses one layer up, so a rail that grows an argument
  # fails here rather than leaving every example below testing a shape nothing
  # sends.
  it "records against the real inlet's own signatures" do
    real = Lain::Frontend::Neovim::RenderInlet.instance_method(:set_review)
    recorder = RecordingReviewInlet.instance_method(:set_review)

    expect(recorder.parameters).to eq(real.parameters)
  end

  it "records every review rail the real inlet offers" do
    rails = %i[set_review open_changeset set_thread review_refused]

    expect(rails.map { |rail| RecordingReviewInlet.instance_method(rail).parameters })
      .to eq(rails.map { |rail| Lain::Frontend::Neovim::RenderInlet.instance_method(rail).parameters })
  end

  describe "#present" do
    it "posts the view's lines beneath the stamp they were rendered under" do
      surface.present(two_commit_changeset, scope: :cumulative)

      expect(inlet.posted).to eq([[:set_review, ["[x] lib/a.rb", "[~] lib/b.rb", "[ ] lib/c.rb"], 1]])
    end

    it "posts a second render beneath a second stamp, so no gesture aliases across them" do
      surface.present(two_commit_changeset, scope: :cumulative)
      surface.present(two_commit_changeset, scope: :commits)

      expect(inlet.posted.map(&:last)).to eq([1, 2])
    end

    it "renders the commit walk at :commits scope" do
      surface.present(two_commit_changeset, scope: :commits)

      expect(inlet.posted.dig(0, 1)).to include("+3 -1  add a.rb")
    end

    it "refuses a scope the vocabulary does not declare, rather than picking a default" do
      expect { surface.present(two_commit_changeset, scope: :cumulatve) }.to raise_error(KeyError)
    end
  end

  describe "#annotate" do
    # THE ANCHOR RIDES AS A TABLE, and this is the example whose absence let the
    # capability ship broken: the editor half refuses anything but
    # `{id, path, side, line}` -- the pane is cursor-driven and an id names no
    # position -- and the refusal travels over a notify, so a bare id posted
    # here reached nobody and answered nil. Compared as a whole payload rather
    # than by `include`, so a fifth key or a dropped one both fail.
    it "posts the note as a message in the anchor's conversation, keyed by the whole anchor" do
      anchor = real_anchor

      surface.annotate(anchor, "this reads twice", kind: :blocker)

      expect(inlet.posted).to eq([[:set_thread,
                                   { "id" => anchor.id, "path" => "lib/lain/agent.rb", "side" => "new",
                                     "line" => 14 },
                                   ["-- thread at lib/lain/agent.rb:14 --", "", "## blocker",
                                    "this reads twice"]]])
    end

    # The one owner of the payload, named: a surface that grew its own
    # `set_thread` call back would pass every example above and this one alone
    # would fail, because the view it was handed would never be reached.
    it "renders through the ThreadView it was handed, never around it" do
      recording = RecordingThreadView.new
      surface = described_class.new(rpc: inlet, view:, session:, thread_view: recording)

      surface.annotate(real_anchor, "this reads twice", kind: :blocker)
      surface.thread(real_anchor(path: "lib/b.rb", line: 3))

      expect(inlet.posted).to be_empty
      expect(recording.shown.map { |at, entries| [at.path, entries.map(&:speaker)] })
        .to eq([["lib/lain/agent.rb", [:blocker]], ["lib/b.rb", []]])
    end
  end

  describe "#mark" do
    it "posts a notice naming the hunk and the state it now carries" do
      surface.mark("hunk-content-v1:deadbeef", :reviewed)

      expect(inlet.posted).to eq([[:review_refused, "hunk-content-v1:deadbeef is now reviewed"]])
    end

    # The `unreviewed`/`reviewed` substring trap the shared group's own law
    # dodges with a word boundary, pinned here on the producing side too.
    it "says unreviewed when that is the state, and does not smuggle reviewed past a substring check" do
      surface.mark("hunk-content-v1:deadbeef", :unreviewed)

      expect(inlet.posted.dig(0, 1)).to match(/\bunreviewed\z/)
    end
  end

  describe "#thread" do
    # No history to replay, so the view renders its own invitation to ask --
    # which is what "open" honestly means for a surface that holds no review
    # state. The position still rides, as the header and as the anchor table.
    it "posts the position and an invitation, keyed by the whole anchor" do
      anchor = real_anchor(path: "lib/b.rb", line: 3)

      surface.thread(anchor)

      expect(inlet.posted).to eq([[:set_thread,
                                   { "id" => anchor.id, "path" => "lib/b.rb", "side" => "new", "line" => 3 },
                                   ["-- thread at lib/b.rb:3 --",
                                    Lain::Frontend::Neovim::ThreadView::EMPTY]]])
    end
  end

  describe "#verdict" do
    it "asks, by posting the vocabulary the human may answer with" do
      surface.verdict

      expect(inlet.posted.dig(0, 1)).to include("approve")
    end

    # The one message whose refusal has nowhere to go: VERDICTS are Strings, so
    # a refusal returned here would be indistinguishable from a verdict.
    it "answers nothing, even when the editor refused the ask" do
      detached = described_class.new(rpc: RecordingReviewInlet.new(refusal: "no editor"), view:, session:)

      expect(detached.verdict).to be_nil
    end
  end

  describe "#refuse" do
    it "sends the caller's own sentence down the review's notice rail" do
      surface.refuse("this changeset is too large to review here")

      expect(inlet.posted).to eq([[:review_refused, "this changeset is too large to review here"]])
    end
  end

  describe "a detached editor" do
    # A REAL RenderInlet with its queue closed, which is what RPC-thread death
    # leaves behind -- not a double answering a constant. The refusal that comes
    # back is therefore the sentence the real rail would produce.
    subject(:surface) { described_class.new(rpc: detached_inlet, view:, session:) }

    let(:detached_inlet) do
      Lain::Frontend::Neovim::RenderInlet.new(waker: -> {}).tap(&:close)
    end

    def inlet_refusal(name) = Lain::Frontend::Neovim::RenderInlet.const_get(name)

    it "refuses #present rather than raising, naming the detached editor" do
      expect(surface.present(two_commit_changeset, scope: :cumulative))
        .to eq(inlet_refusal(:SIDEBAR_DETACHED))
    end

    it "refuses #annotate, naming the thread pane specifically" do
      expect(surface.annotate(real_anchor, "note", kind: :note)).to eq(inlet_refusal(:THREAD_DETACHED))
    end

    it "refuses #thread, naming the thread pane specifically" do
      expect(surface.thread(real_anchor)).to eq(inlet_refusal(:THREAD_DETACHED))
    end

    it "refuses #mark and #refuse on the notice rail's own sentence" do
      expect([surface.mark("hunk-content-v1:deadbeef", :reviewed), surface.refuse("not today")])
        .to eq([inlet_refusal(:UNREPORTED), inlet_refusal(:UNREPORTED)])
    end

    it "raises nothing at all, for the whole port" do
      expect do
        surface.present(two_commit_changeset, scope: :cumulative)
        surface.annotate(real_anchor, "note", kind: :note)
        surface.mark("hunk-content-v1:deadbeef", :reviewed)
        surface.thread(real_anchor)
        surface.verdict
        surface.refuse("not today")
      end.not_to raise_error
    end
  end

  describe "the review state it does not hold" do
    # A DETACHED inlet, so nothing downstream keeps a copy of what was sent and
    # the scan below is about this object rather than about a recorder doing
    # its job. The view is still real and still holds its bounded rendering
    # history -- that is a line -> file index a gesture resolves through, not
    # review state: no annotation, no mark and no verdict is reachable from it.
    subject(:surface) { described_class.new(rpc: detached_inlet, view:, session:, thread_view:) }

    let(:detached_inlet) { Lain::Frontend::Neovim::RenderInlet.new(waker: -> {}).tap(&:close) }
    let(:thread_view) { Lain::Frontend::Neovim::ThreadView.new(rpc: detached_inlet) }

    it "holds no annotation and no mark after presenting and recording both" do
      surface.present(two_commit_changeset, scope: :cumulative)
      surface.annotate(real_anchor, "first", kind: :note)
      surface.annotate(real_anchor(line: 9), "second", kind: :blocker)
      surface.mark("hunk-content-v1:deadbeef", :reviewed)

      held = surface.instance_variables.map { |name| surface.instance_variable_get(name) }
      expect(held.map(&:inspect).join(" ")).not_to match(/first|second|deadbeef|reviewed/)
    end

    # The stronger statement, and the one that would still fail if this object
    # started remembering something whose `inspect` happened not to spell any of
    # the words above: every variable it has is IDENTICALLY an object handed to
    # its constructor, so nothing it did produced state of its own.
    it "holds only the four collaborators it was handed, never a scope or a changeset" do
      surface.present(two_commit_changeset, scope: :commits)
      surface.mark("hunk-content-v1:deadbeef", :reviewed)

      held = surface.instance_variables.to_h { |name| [name, surface.instance_variable_get(name)] }
      expect(held).to eq({ "@rpc": detached_inlet, "@view": view, "@session": session,
                           "@thread_view": thread_view })
    end
  end

  describe "the mark gesture coming back from the editor" do
    it "reaches the session carrying that key and no other" do
      surface.marked("hunk-content-v1:deadbeef", :reviewed)

      expect(session.marked).to eq([["hunk-content-v1:deadbeef", :reviewed]])
    end

    it "records nothing when a second, different key is marked -- both arrive, unchanged" do
      surface.marked("hunk-content-v1:deadbeef", :reviewed)
      surface.marked("hunk-content-v1:cafebabe", :unreviewed)

      expect(session.marked).to eq([["hunk-content-v1:deadbeef", :reviewed],
                                    ["hunk-content-v1:cafebabe", :unreviewed]])
    end

    it "refuses honestly when no session is bound, rather than dropping the gesture" do
      unbound = described_class.new(rpc: inlet, view:)

      expect(unbound.marked("hunk-content-v1:deadbeef", :reviewed))
        .to eq(described_class::Unbound::NO_SESSION)
    end
  end

  # The gesture WHOLE, as the wire sends it: a LINE and the stamp of the
  # rendering it came from, because a sidebar row renders no key. The line ->
  # key resolution is the view's; this pins that every key it answers reaches
  # the session, and that a gesture resolving nothing records nothing.
  describe "#marked_at" do
    it "marks EVERY hunk the row on that line names, with the keys the view resolved" do
      rendered = view.render(two_commit_changeset, scope: :cumulative)

      surface.marked_at(2, :reviewed, generation: rendered.generation)

      expect(session.marked).to eq(Lain::Review::Hunk.keys(partial.hunks).map { |key| [key, :reviewed] })
      expect(session.marked.size).to eq(2)
    end

    # The STATE the human pressed, not a state this leg decided: both members of
    # MARK_STATES are legal, so a hard-coded one is silently wrong rather than
    # loudly. A mutant forwarding a fixed :reviewed survived without this.
    it "forwards the state the gesture carried, unreviewed as readily as reviewed" do
      rendered = view.render(two_commit_changeset, scope: :cumulative)

      surface.marked_at(2, :unreviewed, generation: rendered.generation)

      expect(session.marked.map(&:last)).to eq(%i[unreviewed unreviewed])
    end

    it "records nothing for a row that names no hunk, and says so" do
      rendered = view.render(two_commit_changeset, scope: :commits)

      outcome = surface.marked_at(1, :reviewed, generation: rendered.generation)

      expect(outcome.marked?).to be(false)
      expect(session.marked).to be_empty
    end

    it "records nothing for a stamp the view cannot resolve, and hands back its refusal" do
      view.render(two_commit_changeset, scope: :cumulative)

      outcome = surface.marked_at(1, :reviewed, generation: 99)

      expect(outcome.report).to include("never issued")
      expect(session.marked).to be_empty
    end

    # THE BLOCKER a review panel found: the session's refusal was computed and
    # thrown away, so an unbound surface answered `marked? true` for a row
    # nothing recorded -- and `Gestures#gestured` reads `#marked?` and nothing
    # else, so the human was told a mark landed.
    it "refuses the gesture when no session is bound, rather than reporting the view's success" do
      unbound = described_class.new(rpc: inlet, view:)
      rendered = view.render(two_commit_changeset, scope: :cumulative)

      outcome = unbound.marked_at(2, :reviewed, generation: rendered.generation)

      expect(outcome.marked?).to be(false)
      expect(outcome.report).to eq(described_class::Unbound::NO_SESSION)
    end

    it "refuses the gesture when a BOUND session refuses it, and says what the session said" do
      refusing = RecordingReviewSession.new(refusal: "this review is closed")
      surface = described_class.new(rpc: inlet, view:, session: refusing)
      rendered = view.render(two_commit_changeset, scope: :cumulative)

      outcome = surface.marked_at(2, :reviewed, generation: rendered.generation)

      expect(outcome).to have_attributes(marked?: false, report: "this review is closed")
    end

    # Honest about the half that DID land rather than silent about it -- a row
    # left partly marked is a fact the human has to be able to act on.
    it "names how many hunks were recorded before a refusal stopped the rest" do
      partial_session = RecordingReviewSession.new(refusal: "no such hunk", refuse_from: 1)
      surface = described_class.new(rpc: inlet, view:, session: partial_session)
      rendered = view.render(two_commit_changeset, scope: :cumulative)

      outcome = surface.marked_at(2, :reviewed, generation: rendered.generation)

      expect(outcome.marked?).to be(false)
      expect(outcome.report).to eq("no such hunk -- 1 of 2 hunks on that row were recorded before it, " \
                                   "so the row is now partly marked")
    end

    it "hands the view's own answer back, so a consumer reads #marked? and #report off one value" do
      rendered = view.render(two_commit_changeset, scope: :cumulative)

      outcome = surface.marked_at(1, :unreviewed, generation: rendered.generation)

      expect(outcome).to eq(view.marks(1, generation: rendered.generation))
    end
  end

  # The rails whose lua half has LANDED, driven end to end: a real RenderInlet,
  # a real queue, a real `nvim_exec_lua` into a real editor. A fresh editor per
  # example, `diff_mode_spec.rb`'s discipline.
  #
  # `set_thread` WAS excluded here, on the grounds that T18 had not written its
  # far side yet -- and by the time it had, the exclusion was the only reason
  # nothing noticed that this surface was posting a shape the editor refuses.
  # Delivery is a NOTIFY: nvim discards the refusal, the queue answers nil, and
  # a broken rail is indistinguishable from a working one everywhere except
  # here. That is what makes this seam the one that matters on this rail.
  describe "against a real editor", :nvim, :seam do
    subject(:surface) { described_class.new(rpc: real_inlet, view:, session:) }

    let(:real_inlet) { Lain::Frontend::Neovim::RenderInlet.new(waker: -> {}) }

    around do |example|
      socket = File.join(Dir.tmpdir, "lain-review-surface-#{Process.pid}-#{rand(1_000_000)}.sock")
      # `-n` (no swap file), the repository's rule for a headless nvim in a
      # spec: a suite that leaves swap files behind eventually fails with E326.
      pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket,
                  chdir: NeovimSurfaceFixture::PROJECT, out: File::NULL, err: File::NULL)
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

    def deliver = real_inlet.drain(@editor)

    def sidebar_lines
      @editor.exec_lua(<<~LUA, [])
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(buf) == "lain://review" then
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          end
        end
        return nil
      LUA
    end

    def sidebar_stamp
      @editor.exec_lua(<<~LUA, [])
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(buf) == "lain://review" then
            return vim.b[buf].lain_view_generation
          end
        end
        return nil
      LUA
    end

    it "draws the changeset into lain://review" do
      surface.present(two_commit_changeset, scope: :cumulative)
      deliver

      expect(sidebar_lines).to eq(["[x] lib/a.rb", "[~] lib/b.rb", "[ ] lib/c.rb"])
    end

    it "stamps the buffer with the generation those very lines were rendered under" do
      surface.present(two_commit_changeset, scope: :cumulative)
      surface.present(two_commit_changeset, scope: :commits)
      deliver

      expect(sidebar_stamp).to eq(2)
    end

    it "puts a refusal in the editor's own message history" do
      surface.refuse("this changeset is too large to review here")
      deliver

      expect(@editor.exec_lua('return vim.api.nvim_exec2("messages", { output = true }).output', []))
        .to include("this changeset is too large to review here")
    end

    # Every thread buffer the editor holds, as `[name, anchor id]`.
    def thread_buffers
      @editor.exec_lua(<<~LUA, [])
        local found = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[buf].lain_thread_anchor ~= nil then
            table.insert(found, { vim.api.nvim_buf_get_name(buf), vim.b[buf].lain_thread_anchor,
                                  vim.api.nvim_buf_get_lines(buf, 0, -1, false) })
          end
        end
        return found
      LUA
    end

    def messages = @editor.exec_lua('return vim.api.nvim_exec2("messages", { output = true }).output', [])

    # THE PRODUCTION ROUTE, end to end. `Review::Session#annotate` sends exactly
    # this, and as merged it produced no pane at all: the payload was a bare id,
    # the editor refused it by name, and the refusal went into a notify nobody
    # reads. Asserting the BUFFER rather than the absence of an error is the
    # point -- the broken version raised nothing either.
    it "lands an annotation in a thread buffer the editor actually holds" do
      anchor = real_anchor
      surface.annotate(anchor, "this reads twice", kind: :blocker)
      deliver

      expect(thread_buffers)
        .to eq([["lain://thread/#{anchor.id}", anchor.id,
                 ["-- thread at lib/lain/agent.rb:14 --", "", "## blocker", "this reads twice"]]])
      expect(messages).not_to include("set_thread needs")
    end

    it "lands an opened thread in the same buffer, keyed by the same anchor" do
      anchor = real_anchor(path: "lib/b.rb", line: 3)
      surface.thread(anchor)
      deliver

      expect(thread_buffers.map(&:last))
        .to eq([["-- thread at lib/b.rb:3 --", Lain::Frontend::Neovim::ThreadView::EMPTY]])
    end
  end
end
