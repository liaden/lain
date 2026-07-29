# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# `lain epic status` is the read-only projection of the epic tier: the document
# an author wrote, with the Journal's runtime truth folded over it.
#
# Two things here are easy to get wrong and are specified rather than assumed.
# First, an epic spans DAYS and SESSIONS, so the journal is plural -- the
# newest-session shortcut every other report command takes would silently drop
# last week's transitions. Second, `Graph#waves` is status-blind by design, so
# the remaining-work view is computed from the folded statuses; a finished first
# wave is not "start here".
RSpec.describe Lain::CLI::Epic do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      FileUtils.mkdir_p(root)
      example.run
    end
  end

  def root = File.join(@tmp, "project")
  def state_home = File.join(@tmp, "state")
  def paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  def config(home = :xdg) = Lain::Config.new(epics: Lain::Config::Epics.new(home:))

  # Nothing in this file may consult the real repository's .gitignore, so the
  # git question arrives as an injected answer everywhere except the examples
  # that pin how it is asked. "" is the whole vocabulary for "nothing ignores
  # this"; anything else is the rule that does.
  def ignores(answer: "") = instance_double(Lain::CLI::Epic::GitIgnores, reason: answer)

  def command(home: :xdg, ignored: "")
    described_class.new(root:, paths:, config: config(home), ignores: ignores(answer: ignored))
  end

  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def container(home = :xdg)
    Lain::Epic::Home.container(config: config(home), paths:, root:)
  end

  def write_epic(slug, graph, home: :xdg)
    Lain::Epic::Home.resolve(config: config(home), paths:, root:, slug:).write_epic(graph)
  end

  def sessions_dir = paths.sessions_dir(project: paths.project_hash(root))

  # One session file, stamped with a clock the example controls: ordering across
  # files is by the `ts` on the record, never by the filename.
  def session(name, *records, at: "2026-01-01T00:00:00Z")
    path = File.join(sessions_dir, name)
    File.open(path, "w") do |io|
      journal = Lain::Journal.new(io:, clock: -> { at })
      records.each { |record| journal.record(record) }
    end
    path
  end

  def transition(issue_id, to_status: "done", from_status: "pending", epic_slug: "alpha")
    Lain::Epic::IssueTransition.new(epic_slug:, issue_id:, from_status:, to_status:)
  end

  def stage_event(stage, event: "started", epic_slug: "alpha")
    Lain::Epic::StageTransition.new(epic_slug:, stage:, event:)
  end

  # a blocks b blocks c: three waves, one issue each, so a residual view is
  # visible as soon as anything finishes.
  def chain = graph_of(issue("a", blocks: ["b"]), issue("b", blocks: ["c"]), issue("c"))

  describe "the projection" do
    # AC1
    it "renders the ready set before the waves, and renders it identically twice" do
      write_epic("alpha", chain)
      session("one.ndjson", transition("a"), transition("b"))

      first = command.status
      second = command.status

      expect(first).to eq(second)
      expect(first.index("ready:")).to be < first.index("remaining")
    end

    it "opens with the epic, its summary, and the resolved home" do
      write_epic("alpha", chain)
      session("one.ndjson", transition("a"))

      expect(command.status.lines.first(2).map(&:chomp)).to eq(
        ["epic `alpha` — stage research — 1/3 done, 0 in flight, 0 gates parked",
         "home: #{File.join(container, "alpha")}"]
      )
    end

    it "lists every ready issue with its status glyph" do
      write_epic("alpha", chain)
      session("one.ndjson", transition("a"), transition("b"))

      expect(command.status).to include("ready:\n  [ ] `c` the c issue")
    end

    it "says so plainly when nothing is ready" do
      write_epic("alpha", graph_of(issue("a", status: "in_flight")))

      expect(command.status).to match(/ready: nothing/)
    end
  end

  # The parenthetical after "ready: nothing" is the first thing a reader hits,
  # and the first draft asserted a cause it never computed ("every remaining
  # issue is blocked or already moving") -- false for an abandoned issue, and
  # false on a finished or empty epic, where it claimed a reason for issues that
  # do not exist one line above "remaining: nothing".
  describe "why nothing is ready" do
    it "counts the residual set instead of asserting a cause" do
      write_epic("alpha", graph_of(issue("a", status: "in_flight", blocks: %w[b c]),
                                   issue("b"), issue("c"), issue("d", status: "abandoned")))

      expect(command.status).to include("ready: nothing (2 blocked, 1 in flight, 1 abandoned)")
    end

    # Ready is pending-with-every-blocker-done, so while the ready set is empty
    # every pending issue necessarily has an unfinished blocker. "Blocked" is a
    # derivation here, not a guess.
    it "names a pending issue blocked, since an unblocked one would be ready" do
      write_epic("alpha", graph_of(issue("a", status: "abandoned", blocks: ["b"]), issue("b")))

      expect(command.status).to include("ready: nothing (1 blocked, 1 abandoned)")
    end

    it "claims no cause at all when every issue is done" do
      write_epic("alpha", graph_of(issue("a", status: "done")))

      expect(command.status).to include("ready: nothing\n")
    end

    it "claims no cause at all for an epic with no issues" do
      write_epic("alpha", graph_of)

      expect(command.status).to include("ready: nothing\n")
    end
  end

  # The whole residual view turns on one status. It used to be a bare literal in
  # four places; it is now named on the value that owns the closed set, and this
  # pins that the name still points into that set.
  describe "the remaining-work rule" do
    it "is spelled by Epic::DONE, which is a stored status" do
      expect(Lain::Epic::STORED_STATUSES).to include(Lain::Epic::DONE)
    end

    it "does not name abandoned as finished" do
      expect(Lain::Epic::DONE).not_to eq("abandoned")
    end
  end

  describe "the remaining-work view" do
    # Graph#waves is status-blind on purpose; the display list is not.
    it "drops a wave whose issues are all finished, keeping the surviving waves' numbers" do
      write_epic("alpha", chain)
      session("one.ndjson", transition("a"), transition("b"))

      remaining = command.status.split("remaining, by wave:").last

      expect(remaining).to include("wave 3")
      expect(remaining).not_to include("wave 1")
      expect(remaining).not_to include("`a`")
    end

    it "indents each issue under its wave with the document's own glyphs" do
      write_epic("alpha", graph_of(issue("a", status: "in_flight", blocks: ["b"]), issue("b")))

      expect(command.status).to include("  wave 1\n    [~] `a` the a issue\n")
    end

    it "annotates an issue with the blockers still holding it" do
      write_epic("alpha", graph_of(issue("a", status: "abandoned", blocks: ["b"]), issue("b")))

      expect(command.status).to include("[ ] `b` the b issue (blocked by `a`)")
    end

    # An abandoned issue is not finished: it still blocks, and only an edge edit
    # gets past it. Dropping it from the listing once named an id in a
    # `blocked by` annotation that appeared nowhere else in the report.
    it "keeps an abandoned issue in the listing, wearing its own glyph" do
      write_epic("alpha", graph_of(issue("a", status: "abandoned", blocks: ["b"]), issue("b")))

      expect(command.status).to include("[!] `a` the a issue")
    end

    it "names no blocker it does not also list" do
      write_epic("alpha", graph_of(issue("a", status: "abandoned", blocks: ["b"]),
                                   issue("b", blocks: ["c"]), issue("c")))
      output = command.status

      named = output.scan(/blocked by ([^)]+)\)/).flatten.flat_map { |list| list.scan(/`([^`]+)`/) }.flatten
      listed = output.split("remaining, by wave:").last.scan(/\[.\] `([^`]+)`/).flatten

      expect(named).not_to be_empty
      expect(named - listed).to be_empty
    end

    it "drops a done blocker from the annotation -- it holds nothing" do
      write_epic("alpha", graph_of(issue("a", status: "done", blocks: ["b"]), issue("b")))

      expect(command.status).to include("[ ] `b` the b issue\n")
      expect(command.status).not_to include("blocked by")
    end

    it "says so plainly when every issue is done" do
      write_epic("alpha", graph_of(issue("a", status: "done"), issue("b", status: "done")))

      expect(command.status).to match(/remaining: nothing/)
    end
  end

  describe "journal discovery" do
    it "folds transitions from EVERY session, not just the newest" do
      write_epic("alpha", chain)
      session("older.ndjson", transition("a"), at: "2026-01-01T00:00:00Z")
      session("newer.ndjson", transition("b"), at: "2026-02-01T00:00:00Z")

      expect(command.status).to include("2/3 done")
    end

    it "orders records by ts across files, not by filename" do
      write_epic("alpha", chain)
      session("zzz-first.ndjson", transition("a", to_status: "in_flight"), at: "2026-01-01T00:00:00Z")
      session("aaa-last.ndjson", transition("a", from_status: "in_flight"), at: "2026-02-01T00:00:00Z")

      expect(command.status).to include("1/3 done, 0 in flight")
    end

    it "reads ephemeral .btw.ndjson sessions too -- what happened is what happened" do
      write_epic("alpha", chain)
      session("scratch.btw.ndjson", transition("a"))

      expect(command.status).to include("1/3 done")
    end

    it "ignores another epic's transitions instead of refusing the whole walk" do
      write_epic("alpha", chain)
      session("one.ndjson", transition("a"), transition("q", epic_slug: "beta"))

      expect(command.status).to include("1/3 done")
    end

    # Epic::Progress.fold refuses a journal that names epics and none of them
    # yours -- the right rule for a caller handing ONE journal for ONE epic.
    # This caller deliberately spans every session the project ever ran, so most
    # epic records in the input belong to other epics and that guard would fire
    # on the normal case. Partitioning before the fold is what keeps it
    # unreachable, and until this example existed only a comment said so: a
    # mutation making `attributable?` answer true for everything survived the
    # whole suite.
    it "renders normally when every epic record in every session belongs to another epic" do
      write_epic("alpha", chain)
      session("one.ndjson", transition("q", epic_slug: "beta"), stage_event("implementation", epic_slug: "beta"))

      expect { command.status }.not_to raise_error
      expect(command.status).to include("0/3 done")
    end

    # Pins the BEHAVIOUR, and deliberately does not claim to pin the closed
    # `epic_types` filter: a probe opening that filter to everything left this
    # example green, because the fold dispatches by type itself and ignores what
    # it does not recognize. The filter bounds what gets materialized, not what
    # gets believed. This example is what would catch the fold's dispatch
    # changing under us.
    it "ignores a record of an unrelated type even when it names this epic" do
      write_epic("alpha", chain)
      session("one.ndjson", { "type" => "turn", "epic_slug" => "alpha", "issue_id" => "ghost",
                              "from_status" => "pending", "to_status" => "done" })

      expect(command.status).to include("0/3 done")
    end

    # An epic record naming NO epic could be ours, so it is handed to the fold
    # rather than filtered away: dropping it would report "nothing happened" for
    # a line that says something did. The fold's own guard is what refuses it,
    # so there is one rule and not two.
    it "hands an unattributable epic record to the fold rather than dropping it" do
      write_epic("alpha", chain)
      session("one.ndjson", { "type" => "issue_transition", "epic_slug" => " ", "issue_id" => "a",
                              "from_status" => "pending", "to_status" => "done" })

      expect { command.status }.to raise_error(ArgumentError, /epic_slug/)
    end

    it "carries the stage another session started" do
      write_epic("alpha", chain)
      session("one.ndjson", stage_event("epic_plan"))

      expect(command.status).to include("stage epic_plan")
    end

    it "reads the document alone when no session ever named this epic" do
      write_epic("alpha", chain)

      expect(command.status).to include("0/3 done")
    end
  end

  describe "choosing an epic" do
    it "takes the only epic in the home when no slug is given" do
      write_epic("alpha", chain)

      expect(command.status).to include("epic `alpha`")
    end

    it "takes the named epic when several exist" do
      write_epic("alpha", chain)
      write_epic("beta", graph_of(issue("z")))

      expect(command.status("beta")).to include("epic `beta`")
    end

    it "refuses an unnamed choice between several epics, listing them" do
      write_epic("alpha", chain)
      write_epic("beta", graph_of(issue("z")))

      expect { command.status }
        .to raise_error(Lain::CLI::Epic::Ambiguous, /`alpha`, `beta`.*lain epic status SLUG/m)
    end

    it "names an unknown slug and the epics that do exist" do
      write_epic("alpha", chain)

      expect { command.status("gamma") }
        .to raise_error(Lain::CLI::Epic::UnknownEpic, /"gamma".*`alpha`/m)
    end

    it "skips entries that no epic could be named" do
      write_epic("alpha", chain)
      FileUtils.touch(File.join(container, "notes.txt"))
      FileUtils.mkdir_p(File.join(container, "Not A Slug"))

      expect(command.status).to include("epic `alpha`")
    end
  end

  describe "an empty home" do
    # AC2
    it "names the resolved home and how to start, without raising" do
      message = command.status

      expect(message).to include(container)
      expect(message).to match(/no epics yet/)
      expect(message).to match(/research-epic/)
    end

    it "answers the same way when the home directory does not exist at all" do
      expect(File).not_to exist(container)
      expect(command.status).to include("no epics yet")
    end
  end

  describe "the repo-mode tracking warning" do
    # Repo mode's only reason to exist is review in a pull request, and this
    # repo's own .gitignore holds `/.lain/` -- so a repo home can be invisible
    # to the very tool it was chosen for.
    it "warns when a repo home is git-ignored" do
      write_epic("alpha", chain, home: :repo)

      expect(command(home: :repo, ignored: ".gitignore:5:/.lain/").status).to match(/makes git ignore this home/)
    end

    # The actionable half of the warning is WHICH pattern to drop; without it
    # the reader is told to go and hunt for it.
    it "names the rule that does the ignoring, and says it never edits .gitignore" do
      write_epic("alpha", chain, home: :repo)

      message = command(home: :repo, ignored: ".gitignore:5:/.lain/").status

      expect(message).to include(".gitignore:5:/.lain/")
      expect(message).to include("never edits .gitignore")
    end

    it "stays quiet when a repo home is tracked" do
      write_epic("alpha", chain, home: :repo)

      expect(command(home: :repo).status).not_to include("git ignore")
    end

    it "never asks about an xdg home -- being outside the repo is the arrangement" do
      write_epic("alpha", chain)
      asked = ignores(answer: ".gitignore:5:/.lain/")

      described_class.new(root:, paths:, config: config(:xdg), ignores: asked).status

      expect(asked).not_to have_received(:reason)
    end

    it "warns on an empty repo home too, where the advice matters most" do
      expect(command(home: :repo, ignored: ".gitignore:5:/.lain/").status).to match(/makes git ignore this home/)
    end
  end

  describe Lain::CLI::Epic::GitIgnores do
    # `git check-ignore -v`: exit 0 ignored, 1 not ignored, 128 unanswerable
    # (no repository here). All three are pinned -- 128 is the one a comment
    # used to claim and no example checked.
    def shell(exitstatus:, stdout: "")
      instance_double(Mixlib::ShellOut, run_command: nil, exitstatus:, stdout:)
    end

    def reason_from(runner, path: "/x")
      described_class.new(root, shell_out_factory: ->(*) { runner }).reason(path)
    end

    it "asks git with -v, scoped to the root, and reads back the rule" do
      runner = shell(exitstatus: 0, stdout: ".gitignore:5:/.lain/\t.lain/epics\n")
      seen = []
      factory = lambda do |*argv|
        seen = argv
        runner
      end

      rule = described_class.new(root, shell_out_factory: factory).reason("/x")

      expect(rule).to eq(".gitignore:5:/.lain/")
      expect(seen).to eq(["git", "-C", root, "check-ignore", "-v", "--", "/x"])
    end

    it "hands the source field on verbatim, so a pattern holding a colon survives" do
      runner = shell(exitstatus: 0, stdout: ".gitignore:5:/a:b/\t/a:b/c\n")

      expect(reason_from(runner)).to eq(".gitignore:5:/a:b/")
    end

    it "answers empty when git says the path is tracked" do
      expect(reason_from(shell(exitstatus: 1))).to eq("")
    end

    # A warning must never be able to fail a status report about a setup that
    # may not even be in use.
    it "answers empty when the root is no repository at all (exit 128)" do
      expect(reason_from(shell(exitstatus: 128, stdout: "fatal: not a git repository\n"))).to eq("")
    end

    it "answers empty when there is no git to ask" do
      factory = ->(*) { raise Errno::ENOENT, "git" }

      expect(described_class.new(root, shell_out_factory: factory).reason("/x")).to eq("")
    end

    # Unreachable through git itself, and kept because the alternative to a
    # fallback is "" -- which reads as "not ignored" and would silently drop a
    # warning that is true.
    it "still reports an ignore it cannot name, rather than falling silent" do
      expect(reason_from(shell(exitstatus: 0, stdout: ""))).to eq(described_class::UNNAMED)
    end
  end

  describe "loud failures" do
    it "surfaces a missing epic.md as a Lain::Error the exe can render" do
      FileUtils.mkdir_p(File.join(container, "alpha"))

      expect { command.status }.to raise_error(Lain::Error, /epic\.md/)
    end

    # The session directory belongs to the user, so a stray subdirectory wearing
    # a journal's name is reachable without anything being wrong here -- and a
    # raw Errno::EISDIR escapes exe/lain's `rescue Lain::Error` as a backtrace.
    # Named and not skipped: an unreadable journal may hold this epic's
    # transitions, so walking past it would report stale progress as current.
    it "names a session file it cannot read, as a Lain::Error rather than a raw errno" do
      write_epic("alpha", chain)
      FileUtils.mkdir_p(File.join(sessions_dir, "weird.ndjson"))

      expect { command.status }
        .to raise_error(Lain::CLI::Epic::UnreadableJournal, /weird\.ndjson/)
    end

    it "names an unreadable session file the same way" do
      write_epic("alpha", chain)
      denied = session("denied.ndjson", transition("a"))
      File.chmod(0o000, denied)

      expect { command.status }.to raise_error(Lain::CLI::Epic::UnreadableJournal, /denied\.ndjson/)
    end

    it "surfaces a drifted journal as a Lain::Error, never a silent status" do
      write_epic("alpha", chain)
      session("one.ndjson", transition("ghost"))

      expect { command.status }.to raise_error(Lain::Epic::UnknownIssue, /ghost/)
    end
  end
end
