# frozen_string_literal: true

require "fileutils"
require "neovim"
require "timeout"
require "tmpdir"

# The editor rail {Lain::CLI::HumanReplies} asks for, reduced to the four
# messages it sends one. Its own class rather than the one
# `cli/command/survey_spec.rb` declares -- that file is one `parallel_tests` may
# hand to another worker entirely.
class SurveySubdirectoryRail
  def initialize = (@refusals = [])

  attr_reader :refusals

  def push(*) = nil
  def pop(*) = nil
  def review_refused(message) = @refusals << message
  def attached? = true
end

# The frontend, at the three messages {Lain::CLI::HumanReplies} asks of one --
# and every one of them REAL: the surface, the sidebar view and the diff pair
# are the shipped objects wired to a real editor, because what this file is
# about is the path a row takes from the walk to the buffer nvim ends up
# holding, and a double anywhere on it would answer for the seam under test.
class SurveySubdirectoryEditor
  def initialize(rpc:)
    @view = Lain::Frontend::Neovim::ReviewView.new(changesets: Lain::Frontend::Neovim::ChangesetDiff.new(rpc:))
    @surface = Lain::Review::Surface::Neovim.new(rpc:, view: @view)
  end

  attr_reader :bound

  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(review) = @bound = review
end

# The one file the survey is about. Above the chunker's granularity floor, so it
# chunks to a unit a row can name and a verdict can find unreviewed. A top-level
# constant because a constant assigned inside an example group is one RuboCop
# refuses (`Lint/ConstantDefinitionInBlock`) and one the `around` hook that
# writes it could not see anyway.
module SurveySubdirectoryFixture
  GREETER = <<~'RUBY'
    # A greeting, and nothing else.
    class Greeter
      def initialize(name)
        @name = name
      end

      def greet
        "hello, #{@name}"
      end
    end
  RUBY
end

# `/survey ./lib`, from the directory to the buffer the human's `<CR>` opens.
#
# A survey names its files from the tree it walked, and the editor resolves them
# from the directory it was started in -- so a survey of a SUBDIRECTORY was the
# one case where those two roots disagreed: the sidebar drew `greeter.rb`,
# `47_diff.lua` resolved it against its own frozen ROOT, and the new side was an
# empty buffer for a file that does not exist. Every object on that path had a
# spec and every one of them passed, because each was tested against a double
# standing where the next one's root would have been.
#
# So nothing here is doubled between the walk and nvim: a real
# {Lain::CLI::Command::Survey} over a real tree, a real {Lain::Survey::Walk}, a
# real {Lain::Review::Source::Corpus}, a real {Lain::Review::Session}, the real
# sidebar view and diff pair, and a real headless nvim started where `lain up`
# starts one. The assertion is what the EDITOR holds, because a queued command
# is not a drawn one.
#
# == The chat stands BELOW the repository top, and that is the whole fixture
#
# `lain up` pins both panes to one `-c <cwd>`, and {Lain::Project::Resolver}
# walks UP from that cwd to find the root -- so root and the editor's cwd
# coincide only when the human happened to start at the repository top.
# CLAUDE.md: "A monorepo session runs with cwd deep in a subtree and root at the
# repo top."
#
# A fixture where they coincide cannot tell a correct fix from an incorrect one:
# naming from the project ROOT passes every such example and then breaks
# `/survey .` for every real monorepo chat, which is a REGRESSION from what
# worked before this card. So the repository top and the directory the chat
# stands in are deliberately different directories here, and every example below
# discriminates between them.
RSpec.describe "a survey of a subdirectory, from the walk to the editor's buffer", :nvim, :seam do
  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:outbox) { Lain::Review::Submit::Outbox.new }
  let(:record) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: record) }
  let(:rail) { SurveySubdirectoryRail.new }
  let(:inlet) { Lain::Frontend::Neovim::RenderInlet.new(waker: -> {}) }
  let(:editor) { SurveySubdirectoryEditor.new(rpc: inlet) }
  let(:questions) { Async::Queue.new }
  # `root:` and `cwd:` are what {Command::Surface} threads from {Lain::Project},
  # and they are two different directories in every monorepo chat.
  let(:command) { Lain::CLI::Command::Survey.new(root: @repo, cwd: @here, outbox:, paths:, ledger:) }

  # The run's real reply router, so nothing between the command and the rails is
  # a double.
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty: instance_double(Lain::Frontend::TTY),
                                conductor: instance_double(Lain::CLI::Conductor),
                                ask_human: instance_double(Lain::Tools::AskHuman::Directory),
                                questions:)
  end

  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
  let(:env) { build_command_env(replies:, chronicle:) }

  # A monorepo: the repository top at `@repo`, the human standing two
  # directories down in `@here`, and the greeter one further down still. The
  # name the survey mints and the name the editor has to open differ by exactly
  # the surveyed tree's position under `@here` -- and by nothing at all under
  # `@repo`, which is what makes the two candidate roots tell each other apart.
  around do |example|
    Dir.mktmpdir("lain-survey-subdirectory") do |made|
      @tmp = File.realpath(made)
      @repo = File.join(@tmp, "repo")
      @here = File.join(@repo, "services", "api")
      @home = File.join(@tmp, "home")
      FileUtils.mkdir_p([File.join(@repo, ".git"), File.join(@here, "lib"), @home])
      File.binwrite(greeter, source)
      example.run
    end
  end

  # nvim as the cockpit starts it: in the pane's cwd, which is where the human
  # typed `lain up` -- NOT the repository top the resolver discovers from it.
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-survey-subdir-#{Process.pid}-#{rand(1_000_000)}.sock")
    # `-n` (no swap file), the repository's rule for a headless nvim in a spec:
    # a suite that leaves swap files behind eventually fails with E326.
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket,
                chdir: @here, out: File::NULL, err: File::NULL)
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

  def greeter = File.join(@here, "lib", "greeter.rb")

  def source = SurveySubdirectoryFixture::GREETER

  # HOME injected at a path nothing here creates, so no example can reach the
  # developer's own dotfiles.
  def paths = Lain::Paths.new(env: { "HOME" => @home })

  # An editor attached, exactly as {Lain::CLI::Repl#run} attaches one.
  def attached
    replies.bind_editor(rail)
    replies.bind_review_editor(editor)
  end

  # The survey the human typed, drawn into the real editor. `#drain` is what
  # turns the queued commands into `nvim_exec_lua` calls; the read after it is
  # an RPC REQUEST, which flushes them.
  def surveyed(path)
    attached
    command.call(File.join(@here, path), env).tap { inlet.drain(@editor) }
  end

  # The sidebar as nvim holds it: the rows the human is looking at and the stamp
  # the buffer carries, which is the pair a gesture is resolved through.
  def sidebar
    @editor.exec_lua(<<~LUA, [])
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == "lain://review" then
          return { lines = vim.api.nvim_buf_get_lines(b, 0, -1, false),
                   generation = vim.b[b].lain_view_generation }
        end
      end
      return nil
    LUA
  end

  # The `<CR>` gesture, at the row naming this file: the LINE and the buffer's
  # own stamp, exactly as `46_sidebar.lua` sends them.
  def opened(name)
    drawn = sidebar
    line = drawn.fetch("lines").index { |row| row.end_with?(name) }
    raise "no sidebar row names #{name} in #{drawn.fetch("lines").inspect}" if line.nil?

    editor.review_view.open(line + 1, generation: drawn.fetch("generation"))
          .tap { inlet.drain(@editor) }
  end

  # The file buffer the diff pair opened, as nvim holds it: its NAME is the whole
  # question this card is about, and `modifiable`/`buftype` are what say whether
  # a `:w` in it would create the file it names.
  def new_side
    @editor.exec_lua(<<~LUA, [])
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[b].lain_review_side == "new" then
          return { name = vim.api.nvim_buf_get_name(b), path = vim.b[b].lain_review_path,
                   lines = vim.api.nvim_buf_get_lines(b, 0, -1, false),
                   buftype = vim.bo[b].buftype, modifiable = vim.bo[b].modifiable }
        end
      end
      return nil
    LUA
  end

  # The row's own text, which is the naming decision made visible. It is
  # asserted WHOLE rather than by suffix: `lib/greeter.rb` and
  # `services/api/lib/greeter.rb` both end in `greeter.rb`, and the difference
  # between them is the entire question.
  def rows = sidebar.fetch("lines").map { |row| row.sub(/\A\[.\] /, "") }

  describe "a row from a subdirectory survey" do
    # THE discriminating example. Named from the repository top the row would
    # read `services/api/lib/greeter.rb`, the editor would resolve it under its
    # own cwd, and the buffer would be an empty one at
    # `<here>/services/api/lib/greeter.rb`.
    it "names the file from where the chat stands, not from the repository top" do
      surveyed("lib")

      expect(rows).to eq(["lib/greeter.rb"])
    end

    it "opens the file that exists, rather than one named from the surveyed tree alone" do
      surveyed("lib")
      opened("greeter.rb")

      expect(new_side.fetch("name")).to eq(greeter)
      expect(File.file?(new_side.fetch("name"))).to be(true)
    end

    it "holds the file's own contents, which is what makes it a review of the file" do
      surveyed("lib")
      opened("greeter.rb")

      expect(new_side.fetch("lines")).to eq(source.lines.map(&:chomp))
    end

    # The gesture's own answer, which is what the human is told happened. A row
    # that opened a file nobody can find still reported success.
    it "reports the open against a path the project resolves" do
      surveyed("lib")

      answer = opened("greeter.rb")

      expect(answer).to have_attributes(opened?: true)
      expect(File.file?(File.join(@here, answer.path))).to be(true)
    end
  end

  # The stamp on the sidebar buffer is what the human's NEXT gesture carries, so
  # a gesture that changed a row and drew nothing leaves every later gesture
  # resolved against a rendering taken BEFORE the change -- which is how `<CR>`
  # then a mark refused the row the `<CR>` had just made readable.
  #
  # Driven through {Lain::Review::Handover}, because that is the object the
  # gesture rail actually reaches (`CLI::HumanReplies::Gestures` sends it
  # `open`), and asserted against the EDITOR's own variable, because what this
  # file is about is what nvim ends up holding rather than what was queued for
  # it. It is therefore also the guard on the WIRING: a handover built without a
  # redraw draws nothing here and this stays flat.
  # THE CHUNK'S STATED GOAL, driven end to end: open a survey of a subdirectory
  # and mark it reviewed. Every object between the keystroke and the buffer is
  # the shipped one -- a real `/survey`, a real corpus, a real session, the real
  # sidebar view and diff pair, and a real headless nvim -- and the gestures are
  # sent to {Lain::Review::Handover}, which is what `CLI::HumanReplies::Gestures`
  # reaches.
  #
  # NOTHING REDRAWS BETWEEN TWO GESTURES HERE. `#drain` is not a redraw: it
  # delivers what the subject already queued, which is the reactor's own job, and
  # every rendering after `surveyed` is one the subject asked for. Each gesture
  # rides in with the stamp read back off nvim's own `b:lain_view_generation`,
  # which is exactly what `46_sidebar.lua` sends.
  describe "a row opened and then marked, as a human works one" do
    # The row as the human is looking at it NOW, and the stamp their next
    # gesture carries. Re-read before every gesture, because that is what a
    # keystroke against a redrawn buffer actually does.
    def marked_row(name)
      drawn = sidebar
      line = drawn.fetch("lines").index { |row| row.end_with?(name) }
      raise "no sidebar row names #{name} in #{drawn.fetch("lines").inspect}" if line.nil?

      [line + 1, drawn.fetch("generation")]
    end

    def gesture(name)
      row, generation = marked_row(name)
      yield(row, generation).tap { inlet.drain(@editor) }
    end

    # The card's own measurement: the stamp was UNCHANGED across an open, so
    # every later gesture resolved against a rendering taken before the read.
    it "draws the sidebar again after the open, so the next gesture sees what it changed" do
      surveyed("lib")
      before = sidebar.fetch("generation")

      gesture("greeter.rb") { |row, generation| editor.bound.open(row, generation:) }

      expect(sidebar.fetch("generation")).to be > before
    end

    it "accepts the mark that follows the open, with nothing redrawing in between" do
      surveyed("lib")
      gesture("greeter.rb") { |row, generation| editor.bound.open(row, generation:) }

      marked = gesture("greeter.rb") { |row, generation| editor.bound.mark(row, "reviewed", generation:) }

      expect(marked).to have_attributes(marked?: true, report: include("lib/greeter.rb"))
    end

    # The other half, in the editor rather than in a spec's own recorder: a mark
    # that landed used to leave the row drawn `[ ]`, because nothing re-presented
    # after one either.
    it "shows the row reviewed in nvim's own buffer once the mark has landed" do
      surveyed("lib")
      gesture("greeter.rb") { |row, generation| editor.bound.open(row, generation:) }
      gesture("greeter.rb") { |row, generation| editor.bound.mark(row, "reviewed", generation:) }

      expect(sidebar.fetch("lines")).to eq(["[x] lib/greeter.rb"])
    end

    # And the round closes: the strictest verdict policy over a survey worked
    # entirely with the two gestures a human has.
    it "admits an approve verdict over the survey worked through the gestures alone" do
      surveyed("lib")
      gesture("greeter.rb") { |row, generation| editor.bound.open(row, generation:) }
      gesture("greeter.rb") { |row, generation| editor.bound.mark(row, "reviewed", generation:) }

      expect(editor.bound.wrote_verdict("approve")).to be_nil
    end
  end

  # The guard, and it is a REGRESSION guard rather than a formality: a survey of
  # the directory the chat is standing in worked before this card, and the
  # obvious wrong fix -- naming from the project root -- breaks it for every
  # monorepo chat while passing every subdirectory example. The fix cannot be
  # "prepend something"; it has to be "name it from the root the editor
  # resolves against".
  describe "a survey of the directory the chat stands in" do
    it "names each file by its position under that directory, and nothing above it" do
      surveyed(".")

      expect(rows).to eq(["lib/greeter.rb"])
    end

    it "opens the same file, from the row that names it with its whole path" do
      surveyed(".")
      opened("lib/greeter.rb")

      expect(new_side.fetch("name")).to eq(greeter)
      expect(new_side.fetch("lines")).to eq(source.lines.map(&:chomp))
    end
  end

  describe "a verdict over a survey nobody has marked" do
    # The refusal is the one place a survey's paths are read by a human away
    # from the sidebar that drew them, so a name only the walk could resolve
    # sends them looking for a file that is not there. Asserted by RESOLVING it
    # rather than by matching a literal, which is the property the sentence has
    # to have.
    it "names a path that resolves from where the human is standing" do
      surveyed("lib")

      refusal = editor.bound.wrote_verdict("approve")
      named = refusal[/\S+(?= is unreviewed)/]

      expect(named).to eq("lib/greeter.rb")
      expect(File.file?(File.join(@here, named.to_s))).to be(true)
    end
  end
end
