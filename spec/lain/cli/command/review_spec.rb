# frozen_string_literal: true

require "async"
require "fileutils"
require "mixlib/shellout"
require "neovim"
require "stringio"
require "timeout"
require "tmpdir"

# `/review <target>` (T31b): the repl command that puts a human in front of a
# pull request inside the cockpit they already have open.
#
# EVERY GESTURE HERE ARRIVES ON THE COMMAND INBOX, and that is the whole point
# of the file rather than a stylistic preference. `spec/lain/cli/review_spec.rb`
# had 28 examples proving {Lain::CLI::Review} correct while nothing in `exe/lain`
# mounted it, and waves 3-5 of this chunk shipped a surface with zero
# construction sites under green specs. Calling {Lain::Review::Handover}
# directly would reproduce exactly that: the object works, and nothing reaches
# it. So the seam group below binds a real {Lain::CLI::HumanReplies}, pushes the
# wire's own `["review_mark", [line, state, generation]]` onto the editor rail,
# runs the real consumer fiber, and asserts what the session recorded.
#
# THE STALE-GENERATION EXAMPLE IS THE COUNTER-EXAMPLE, and without it a stamp
# ignoring implementation passes every other example in this file: a gesture
# that resolves whatever row the line names, whatever rendering it came from,
# marks the same hunks as the good one. The refusal reaching `review_refused` is
# what tells the two apart.

# The editor rail, both directions. {Lain::Frontend::Neovim::CommandInbox}'s
# duck: a non-blocking pop the consumer fiber drains, and the way a refused
# gesture gets back to the human who made it. Its own class rather than the one
# `human_replies_spec.rb` declares -- that file is one `parallel_tests` may hand
# to another worker entirely.
class ReviewCommandRail
  def initialize
    @commands = []
    @refusals = []
  end

  attr_reader :refusals

  def push(command) = @commands.push(command)
  def pop(*) = @commands.shift
  def review_refused(message) = @refusals << message
  def attached? = true
end

# The one message the diff pair sends the editor, recorded rather than sent.
# Its own class for {ReviewCommandRail}'s reason: a class declared in another
# spec file is one `parallel_tests` may hand to another worker entirely.
class ReviewCommandInlet
  attr_reader :posted

  def initialize = (@posted = [])

  def open_changeset(path, old_lines, line, revisions)
    @posted << { path:, old_lines:, line:, revisions: }
    nil
  end
end

# The frontend, reduced to the three messages {Lain::CLI::HumanReplies} asks of
# one. The surface is the REAL text surface, the view the REAL sidebar view and
# its diff surface the REAL {Lain::Frontend::Neovim::ChangesetDiff} (T32a), for
# `wiring_spec.rb`'s reason: what is under test is whether the command reaches
# THESE, and a double answering the port would be indistinguishable from
# {Lain::Review::Surface::Null}. Only the INLET is recorded, because its far
# side is an editor and this group has none.
class ReviewCommandEditor
  def initialize(sink)
    @inlet = ReviewCommandInlet.new
    @view = Lain::Frontend::Neovim::ReviewView.new(
      changesets: Lain::Frontend::Neovim::ChangesetDiff.new(rpc: @inlet)
    )
    @surface = Lain::Review::Surface::Text.new(sink:)
  end

  attr_reader :bound, :inlet

  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(review) = @bound = review
end

RSpec.describe Lain::CLI::Command::Review do
  let(:command) { described_class.new(root: @repo, shell_out_factory: Mixlib::ShellOut.public_method(:new)) }
  let(:sink) { StringIO.new }
  let(:record) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: record) }
  let(:rail) { ReviewCommandRail.new }
  let(:editor) { ReviewCommandEditor.new(sink) }
  let(:questions) { Async::Queue.new }

  # The run's real reply router: the object that owns both the acked-gesture
  # table and `bind_changeset_review`, so nothing between the wire and the
  # session is a double.
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty: instance_double(Lain::Frontend::TTY),
                                conductor: instance_double(Lain::CLI::Conductor),
                                ask_human: instance_double(Lain::Tools::AskHuman::Directory),
                                questions:)
  end

  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
  let(:env) { build_command_env(replies:, chronicle:) }

  # A `main` and a `feature` carrying TWO commits, because `--base`'s default is
  # {Lain::Forge::Landing::BASE} and an example that overrides it has to be able
  # to tell the two apart: against `main` the changeset is README plus
  # `later.rb`, against `HEAD~1` it is `later.rb` alone. Reviewed against one
  # commit, a `--base` this command dropped on the floor would render exactly
  # what the default renders and the example would be green either way.
  around do |example|
    Dir.mktmpdir("lain-command-review") do |dir|
      FileUtils.cp_r(File.join(SeedRepo.at("README" => "seed\n"), "."), dir)
      git(dir, "branch", "-M", "main")
      git(dir, "checkout", "-q", "-b", "feature")
      File.write(File.join(dir, "README"), "seed\nthe line under review\n")
      commit(dir, "the work under review")
      File.write(File.join(dir, "later.rb"), "the second commit\n")
      commit(dir, "and the commit after it")
      @repo = dir
      example.run
    end
  end

  def commit(dir, subject)
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", subject)
  end

  def git(dir, *)
    Mixlib::ShellOut.new("git", "-C", dir, *,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.error!
  end

  # An editor attached, exactly as {Lain::CLI::Repl#run} attaches one.
  def attached
    replies.bind_editor(rail)
    replies.bind_review_editor(editor)
  end

  # The whole round trip, on the rail a real editor uses: push the wire's own
  # message, run the reply surfaces for real, and stop them. Bounded, so a
  # gesture nothing consumes is a failing example naming the condition rather
  # than a hang.
  def gestured(*commands, &settled)
    commands.each { |wire| rail.push(wire) }
    Sync do |task|
      surfaces = replies.surfaces(task)
      begin
        pumped_until(task, reason: "the gesture was served", &settled)
      ensure
        surfaces.each(&:stop)
      end
    end
  end

  # The rendering the human is looking at, and the stamp it carries -- read off
  # the view the command bound, never rebuilt here, because a stamp is only
  # resolvable by the view that issued it.
  def sidebar = editor.review_view.render(editor.bound.session.marked, scope: :cumulative)

  def row_of(rendering, path) = rendering.lines.index { |line| line.include?(path) } + 1

  # THE LAST LINK, and the one this chunk has now missed twice: a command that
  # works and is registered, against a line a human actually types. `/review
  # 4821` and `/review .../pull/12` both have to survive {Skill::Invocation}'s
  # grammar with their target intact -- a bare number and a URL are the two
  # spellings {Lain::CLI::Review::Target} exists to tell apart, and a dispatcher
  # that swallowed either would hand this command an empty line and get its
  # usage back, looking for all the world like the human mistyped.
  describe "the line a human types, through the registry that dispatches it" do
    let(:registry) { Lain::CLI::Command::Registry.new([command]).bind(env) }

    it "reaches the command with its target intact" do
      attached

      answer = registry.dispatch("/review feature --scope commits") { raise "fallthrough must not run" }

      expect(answer).to include("branch feature").and include("commits")
    end

    it "carries a pull-request spelling through rather than eating it" do
      attached

      # Refused by the RESOLVER, naming the number -- which is proof the digits
      # arrived: a swallowed target answers the usage instead.
      expect { registry.dispatch("/review 4821") { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, /4821/)
    end
  end

  describe "what it refuses before it opens anything" do
    it "answers its own usage when no target was named" do
      expect(command.call("", env)).to eq(command.usage)
    end

    # The one refusal that is about the PROCESS rather than the target, and the
    # reason it comes first: a headless chat that drew a review into
    # {Lain::Review::Surface::Null} would report a review nobody can read, which
    # is the exact failure this chunk exists against.
    it "refuses when no editor is attached, rather than drawing into a null surface" do
      expect { command.call("feature", env) }
        .to raise_error(Lain::Error, /no editor/)
    end

    it "refuses a flag it does not carry, rather than reading it as a branch name" do
      attached

      expect { command.call("feature --squash", env) }.to raise_error(Lain::Error, /--squash/)
    end

    it "refuses a flag whose value is missing, rather than treating it as absent" do
      attached

      expect { command.call("feature --base", env) }.to raise_error(Lain::Error, /--base/)
    end

    # {Lain::CLI::Review::Target}'s own refusals, reached rather than restated:
    # this command resolves through that object unchanged, which is what makes
    # the card cheap, and an unresolvable ref must say so in ITS words.
    it "hands back the target resolver's own refusal for a ref that names nothing" do
      attached

      expect { command.call("no-such-branch", env) }
        .to raise_error(Lain::Review::Source::UnknownRef, /no-such-branch/)
    end

    # Nothing may be bound and nothing journaled by a call that refused: a
    # review the human cannot answer is worse than no review, and a rail still
    # holding the last one would route their next verdict to it.
    it "binds no review and journals nothing when the target does not resolve" do
      attached

      expect { command.call("no-such-branch", env) }.to raise_error(Lain::Review::Source::UnknownRef)
      expect(editor.bound).to be_nil
      expect(record.string).to be_empty
    end
  end

  describe "opening a review in the editor the chat already has" do
    it "draws the changeset on the editor's own surface and says what it opened" do
      attached

      answer = command.call("feature", env)

      expect(sink.string).to include("README")
      expect(answer).to include("branch feature").and include("cumulative")
    end

    # The review is part of the chat's RECORD, not a second journal beside it:
    # `/review` inside a cockpit is one session, and a round opened in another
    # file could never be resumed from the session the human was in.
    it "opens the round in the chat's own journal" do
      attached

      command.call("feature", env)

      expect(record.string).to include("changeset_opened").and include("local_branch")
    end

    # ONE object on both rails is asserted by the seam group below, where a
    # gesture arriving on the ACKED rail is read back off the object the ANSWERED
    # rail was handed. This is the half that can be said without the wire: the
    # editor was handed a real review rather than nothing.
    it "hands the editor's write rail the review it just opened" do
      attached

      command.call("feature", env)

      expect(editor.bound).to be_a(Lain::Review::Handover)
      expect(editor.bound.session.changeset.files.map { |file| file.path.to_s }).to include("README")
    end

    # The base is what decides WHICH changeset is drawn, so the assertion is
    # about what fell OUT of it: against `HEAD~1` the first commit's README is
    # not in the range, and a `--base` this command ignored would draw it.
    it "honours --base, so a branch can be reviewed against something other than main" do
      attached

      answer = command.call("feature --base HEAD~1", env)

      expect(answer).to include("branch feature")
      expect(sink.string).to include("later.rb")
      expect(sink.string).not_to include("README")
    end

    it "honours --scope, so the commit walk is reachable without a second command" do
      attached

      answer = command.call("feature --scope commits", env)

      expect(answer).to include("commits")
      expect(sink.string).to include("the work under review")
    end

    it "refuses a scope the vocabulary does not declare" do
      attached

      expect { command.call("feature --scope everything", env) }
        .to raise_error(Lain::Review::Session::UnknownScope, /everything/)
    end
  end

  # THE SEAM THIS CARD EXISTS FOR. Every example drives the wire, never the
  # object: the command opens the review, the editor sends a gesture, the real
  # consumer fiber serves it, and the assertion is about what the session holds.
  describe "the gestures a human makes, arriving on the command inbox", :seam do
    it "records a mark against the session the command opened" do
      attached
      command.call("feature", env)
      rendering = sidebar
      row = row_of(rendering, "README")

      gestured(["review_mark", [row, "reviewed", rendering.generation]]) do
        editor.bound.session.marks.to_h.any?
      end

      expect(editor.bound.session.marks.to_h.values).to all(eq("reviewed"))
      expect(rail.refusals).to be_empty
    end

    # THE COUNTER-EXAMPLE. A stamp the view no longer holds names a row in a
    # buffer whose rows have moved, and the refusal has to reach the editor the
    # gesture came from -- a mark that silently lands on whatever that line
    # names now is a wrong-hunk write, not an error.
    it "refuses a gesture stamped with a rendering the view no longer holds, and says so on the rail" do
      attached
      command.call("feature", env)
      rendering = sidebar
      row = row_of(rendering, "README")
      stale = rendering.generation + Lain::Frontend::Neovim::ReviewView::HELD + 1

      gestured(["review_mark", [row, "reviewed", stale]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("lain://review")
      expect(editor.bound.session.marks.to_h).to be_empty
    end

    # A stamp is not merely PRESENT-or-absent: a buffer nothing ever rendered
    # into carries none at all, and telling that apart from a stale one is what
    # {Lain::Frontend::Neovim::ReviewView}'s three sentences exist for.
    it "refuses an unstamped gesture with the sentence about an unrendered buffer" do
      attached
      command.call("feature", env)

      gestured(["review_mark", [1, "reviewed", nil]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("no rendering stamp")
    end

    # THE FIRST LINK OF THE WHOLE GESTURE CHAIN (T32a), and the one this rail
    # was missing: `<CR>` -> `review_open` -> {Lain::Review::Handover#open} ->
    # the view -> the diff surface -> the editor. It used to end at
    # {Lain::Frontend::Neovim::ReviewView::Unwired}'s refusal, which meant no
    # diff buffer was ever created -- and since `47_diff.lua`'s `pair()` is what
    # stamps those buffers, `:LainNote` had nowhere to place a note either.
    #
    # The OLD SIDE is what the assertion is about, not that a post happened: the
    # changeset here is a real one over a real repository, `README` genuinely
    # read `seed` at the base and reads `seed` plus a line now, so an
    # implementation posting the new side, the working tree, or nothing at all
    # is a different value rather than the same green.
    it "opens the row's file as a diff pair, old side and both revisions, with nothing refused" do
      attached
      command.call("feature", env)
      rendering = sidebar

      gestured(["review_open", [row_of(rendering, "README"), rendering.generation]]) do
        editor.inlet.posted.any?
      end

      session = editor.bound.session
      expect(editor.inlet.posted)
        .to eq([{ path: "README", old_lines: ["seed"], line: 1,
                  revisions: { "old" => session.changeset.base_ref, "new" => session.changeset.head_ref } }])
      expect(rail.refusals).to be_empty
    end

    # The card's other half: a review whose diff surface nobody wired still says
    # so rather than dropping the gesture. Same command, same rail, an editor
    # built the way every one in this tree was before T32a.
    it "refuses an open gesture in words when the editor has no diff surface at all" do
      unwired = Lain::Frontend::Neovim::ReviewView.new
      editor.define_singleton_method(:review_view) { unwired }
      attached
      command.call("feature", env)
      rendering = sidebar

      gestured(["review_open", [row_of(rendering, "README"), rendering.generation]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("no diff surface is wired")
      expect(editor.inlet.posted).to be_empty
    end

    it "refuses an ask gesture in words, because no docent is wired to this review yet" do
      attached
      command.call("feature", env)

      gestured(["review_ask", %w[anchor-1 why?]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("no docent is wired")
    end

    # A second `/review` REBINDS: the rails hold the review the human is
    # actually looking at, or a gesture over the new sidebar records against the
    # old changeset.
    it "rebinds both rails when a second review is opened over the first" do
      attached
      command.call("feature", env)
      first = editor.bound
      command.call("feature", env)
      rendering = sidebar

      gestured(["review_mark", [row_of(rendering, "README"), "reviewed", rendering.generation]]) do
        editor.bound.session.marks.to_h.any?
      end

      expect(editor.bound).not_to equal(first)
      expect(first.session.marks.to_h).to be_empty
    end
  end

  # THE RENDERING, READ BACK OUT OF A REAL EDITOR. A nil answer from
  # {Lain::Review::Session#present} means "the surface took it", which for an
  # editor means "queued" and never "drawn" -- so the only assertion worth
  # making about the nvim leg is one that reads the buffer nvim actually holds.
  describe "the sidebar a real nvim draws", :nvim, :seam do
    around do |example|
      socket = File.join(Dir.tmpdir, "lain-review-cmd-#{Process.pid}-#{rand(1_000_000)}.sock")
      pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
      Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
      @socket = socket
      example.run
    ensure
      @inspector = nil
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

    # A SECOND, independent connection, `neovim_spec.rb`'s inspector: every
    # assertion is about what the editor actually did, never about the
    # frontend's own bookkeeping.
    def inspector = @inspector ||= Neovim.attach_unix(@socket)

    def sidebar_lines
      inspector.exec_lua(<<~LUA, [])
        local buf = vim.fn.bufnr("lain://review")
        if buf == -1 then return {} end
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      LUA
    end

    it "renders the changeset into lain://review, in the editor the chat is already attached to" do
      frontend = Lain::Frontend::Neovim.new(channel: Lain::Channel.new, socket_path: @socket)

      frontend.run do
        replies.bind_editor(frontend.command_inbox)
        replies.bind_review_editor(frontend)

        command.call("feature", env)

        wait_until(reason: "lain://review carried the changeset") { sidebar_lines.grep(/README/).any? }
      end
    end
  end
end
