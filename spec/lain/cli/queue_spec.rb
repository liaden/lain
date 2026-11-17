# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "shellwords"
require "socket"

RSpec.describe Lain::CLI::Queue, :seam do
  let(:old) { { "GIT_AUTHOR_DATE" => "2020-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2020-01-01T00:00:00Z" } }

  # Serves session.list as the daemon does, from the records `live` adds.
  let(:live_records) { [] }
  let(:listing) { SessionListing.new(live_records) }
  let(:daemon_source) { -> { listing } }

  # Thor builds the command object from argv, so no constructor keyword reaches
  # the LiveSessions it lists chats through; the stand-in goes in at `new`.
  before do
    allow(Lain::LiveSessions).to receive(:new).and_wrap_original do |original, **keywords|
      original.call(**keywords, daemon: daemon_source)
    end
  end

  around do |example|
    Dir.mktmpdir("lain-cli-queue") do |dir|
      @repo = File.realpath(dir)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo)
      Dir.mktmpdir("lain-cli-queue-state") do |state|
        with_env("XDG_STATE_HOME" => state) { example.run }
      end
    end
  end

  def git(*, env: {}) = SeedRepo.git(@repo, *, env:).stdout.strip

  def commit(name, body = "#{name}\n")
    File.write(File.join(@repo, name), body)
    git("add", name)
    git("commit", "-q", "-m", name, env: old)
    git("rev-parse", "HEAD")
  end

  def capture(*argv, dir: @repo)
    out = err = nil
    Dir.chdir(dir) do
      out = StringIO.new
      err = StringIO.new
      saved = [$stdout, $stderr]
      $stdout = out
      $stderr = err
      begin
        described_class.start(argv, debug: true)
      ensure
        $stdout, $stderr = saved
      end
    end
    [out.string, err.string]
  end

  # A real run, with Thor's own exit, so a refusal's status is what a shell sees.
  def run(*argv, dir: @repo)
    out = StringIO.new
    err = StringIO.new
    saved = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    Dir.chdir(dir) { described_class.start(argv) }
    [0, out.string, err.string]
  rescue SystemExit => e
    [e.status, out.string, err.string]
  ensure
    $stdout, $stderr = saved
  end

  # A live chat at `root`: a real input socket in front of a real Intake.
  def chat(root, id: "chat", started_at: "2026-11-16T10:00:00Z")
    rail = Lain::Frontend::Intake.new
    path = Lain::CLI::InputSocket.path(cwd: root, name: id, paths: Lain::Paths.new)
    log = Lain::Review::Queue::Log.new(paths: Lain::Paths.new)
    sockets << Lain::CLI::InputSocket.new(rail:, path:, log:).bind.start(nil)
    live(id, root, path, started_at)
    rail
  end

  def live(id, root, path, started_at = "2026-11-16T10:00:00Z")
    writer = Lain::Liveness::Writer.current
    live_records << Lain::LiveSessions::Record.new(session_id: id, pid: writer.pid, start: writer.start,
                                                   host: writer.host, root:, cwd: root, input_socket: path,
                                                   journal: nil, attended: true, started_at:)
  end

  def offered(rail) = wait_until(reason: "the offer drawn") { rail.published.kind == :human && rail.published.text }

  def finished_plan(title: "Ship it", name: "run")
    base = git("rev-parse", "HEAD")
    head = commit("work.txt")
    plan = ["# #{title}", "", "status: done", "base: #{base}", "head: #{head}", ""].join("\n")
    FileUtils.mkdir_p(File.join(@repo, "planning"))
    commit("planning/#{name}.md", plan)
    [base, head]
  end

  def unmerged_branch(name)
    git("checkout", "-q", "-b", name)
    commit("#{name}.txt")
    git("checkout", "-q", "-")
  end

  describe "here" do
    it "prints the plan run, then the unmerged branch, one tab-separated line each" do
      base, head = finished_plan
      unmerged_branch("feature")

      out, = capture("here")

      trunk = git("symbolic-ref", "--short", "HEAD")
      expect(out.lines(chomp: true).map { |line| line.split("\t") }).to eq(
        [["plan:planning/run.md", "plan done: Ship it", "#{base[0, 8]}..#{head[0, 8]}"],
         ["branch:#{@repo}:feature", "unmerged branch feature", "feature against #{trunk}"]]
      )
    end

    it "strips tabs and escape sequences from a plan's title" do
      finished_plan(title: "Red\e[31m\tTitle\e]0;owned\a done")

      out, = capture("here")

      expect(out.lines.size).to eq(1)
      expect(out).to include("plan done: Red Title done")
      expect(out).not_to match(/[\e\a]/)
      expect(out.lines.first.count("\t")).to eq(2)
    end

    it "prints one JSON object per row with --json" do
      finished_plan
      unmerged_branch("feature")

      out, = capture("here", "--json")
      rows = out.lines.map { |line| JSON.parse(line) }

      expect(rows.map { |row| row["id"] }).to eq(["plan:planning/run.md", "branch:#{@repo}:feature"])
      expect(rows.first).to include("rank" => "plan_run", "reason" => "plan done: Ship it")
    end

    it "refuses an unknown switch" do
      expect { capture("here", "--nope") }.to raise_error(Thor::UnknownArgumentError, /--nope/)
    end
  end

  describe "here, beyond the rows" do
    it "puts a refused row's note on stderr and keeps it off stdout" do
      base = git("rev-parse", "HEAD")
      FileUtils.mkdir_p(File.join(@repo, "planning"))
      commit("planning/bad.md", "# Bad\n\nstatus: done\nbase: nope\nhead: #{base}\n")

      out, err = capture("here")

      expect(err).to match(%r{skipped plan:planning/bad.md})
      expect(out).not_to include("skipped")
    end

    it "hides a row whose head was opened, while show still finds it" do
      _, head = finished_plan
      log = Lain::Review::Queue::Log.new(paths: Lain::Paths.new)
      log.append(Lain::Review::Queue::Log::Event.new(kind: :opened, at: nil, row_id: "plan:planning/run.md",
                                                     head_sha: head))

      expect(capture("here").first).to eq("")
      expect(capture("show", "plan:planning/run.md").first).to include("reason: plan done: Ship it")
    end

    it "shows a row by the id `here` printed, even when the path holds 2 spaces" do
      finished_plan(name: "a  b")

      printed = capture("here").first.split("\t").first

      expect(capture("show", printed).first).to include("reason: plan done: Ship it")
    end
  end

  describe "open" do
    let(:sockets) { [] }
    let(:servers) { [] }
    let(:feature) { "branch:#{@repo}:feature" }

    around do |example|
      Dir.mktmpdir("lain-cli-queue-run") { |run| with_env("XDG_RUNTIME_DIR" => run) { example.run } }
    ensure
      sockets.each(&:stop)
      servers.each { |server, thread| thread.kill.join && server.close }
    end

    before do
      unmerged_branch("feature")
      unmerged_branch("other")
    end

    # A listener that greets as a chat does, then answers an offer only with `reply`.
    def stand_in(reply: nil)
      path = File.join(ENV.fetch("XDG_RUNTIME_DIR"), "stand-in.sock")
      server = UNIXServer.new(path)
      kept = []
      thread = Thread.new do
        Enumerator.produce { server.accept }.each do |io|
          kept << io.tap { _1.puts(JSON.generate({ "v" => "context", "commands" => [] })) }
          io.gets && reply && io.puts(JSON.generate(reply))
        end
      end
      servers << [server, thread]
      live("stand-in", @repo, path, "2026-11-16T11:00:00Z")
    end

    it "offers the row to the chat in its checkout, exits 0 and says so" do
      rail = chat(@repo)

      expect(run("open", feature)).to eq([0, "offered #{feature} to chat\n", ""])
      expect(offered(rail)).to start_with("lain queue: /review refs/heads/feature")
    end

    def answered(rail, text)
      prompt = wait_until(reason: "the offer drawn") { rail.published.kind == :human && rail.published }
      rail << Lain::Frontend::Intake::Line.new(text:, generation: prompt.generation)
    end

    def opened_events
      File.readlines(Lain::Paths.new.review_queue_log).reject { _1.strip.empty? }.map { JSON.parse(_1) }
          .select { _1["kind"] == "opened" }.map { _1.values_at("row_id", "head_sha") }
    end

    it "marks the row seen when the human presses Enter at the offer, so the queue lists it no more" do
      rail = chat(@repo)
      run("open", feature)
      answered(rail, "")
      wait_until(reason: "the row marked seen") { !capture("local").first.include?(feature) }

      expect(opened_events).to eq([[feature, git("rev-parse", "feature")]])
    end

    it "leaves the row listed when the human drops the offer with x" do
      rail = chat(@repo)
      run("open", feature)
      answered(rail, "x")
      wait_until(reason: "the offer withdrawn") { rail.published.kind.nil? }

      expect([File.exist?(Lain::Paths.new.review_queue_log) ? opened_events : [], capture("local").first])
        .to match([[], a_string_including(feature)])
      expect(run("open", feature)).to eq([0, "offered #{feature} to chat\n", ""])
    end

    it "names the other chats running in the checkout" do
      chat(@repo, id: "nine", started_at: "2026-11-16T09:00:00Z")
      chat(@repo, id: "ten", started_at: "2026-11-16T10:00:00Z")

      expect(run("open", feature)).to eq([0, "offered #{feature} to ten\nalso running there: nine\n", ""])
    end

    it "exits 1 when the chat is showing another offer" do
      chat(@repo)
      run("open", "branch:#{@repo}:other")

      expect(run("open", feature)).to eq([1, "", "the chat is showing another offer; try again when it is answered\n"])
    end

    it "exits 1 when the row is offered already" do
      chat(@repo)
      run("open", feature)

      expect(run("open", feature)).to eq([1, "", "already offered\n"])
    end

    it "exits 1 naming the field the chat refused" do
      stand_in(reply: { "v" => "offered", "outcome" => "refused", "field" => "repo_root" })

      expect(run("open", feature)).to eq([1, "", "the chat refused the request's repo_root\n"])
    end

    it "exits 1 naming the chat that took the connection and never answered, which may still show it" do
      stub_const("Lain::Review::Queue::Delivery::REPLY", 0.3)
      chat(@repo)
      stand_in

      expect(run("open", feature)).to eq(
        [1, "", "the chat stand-in has not answered the offer, and may still show it\nalso running there: chat\n"]
      )
    end

    it "holds the review for the next cockpit when no chat runs in the checkout, and says so" do
      expect(run("open", feature))
        .to eq([0, "no lain chat is running in #{@repo}; the review opens with the next lain up --nvim there\n", ""])
    end

    context "when the daemon cannot be reached" do
      let(:daemon_source) { -> { raise Lain::Daemon::Unstarted, "lain-daemon did not answer" } }

      it "holds the review as if no chat ran, and says why on stderr" do
        expect(run("open", feature)).to eq(
          [0, "no lain chat is running in #{@repo}; the review opens with the next lain up --nvim there\n",
           "cannot list the running chats: lain-daemon did not answer\n"]
        )
      end
    end

    it "says it replaced a review already held for the checkout" do
      run("open", "branch:#{@repo}:other")

      expect(run("open", feature))
        .to eq([0, "replaced the review held for #{@repo}; it opens with the next lain up --nvim there\n", ""])
    end

    # A herdr stand-in: `answer` is what `workspace create` prints.
    def herdr(answer)
      bin = File.join(ENV.fetch("XDG_STATE_HOME"), "herdr")
      File.write(bin, "#!/bin/sh\ncase \"$1 $2\" in \"workspace create\") echo '#{answer}';; esac\n")
      File.chmod(0o755, bin)
      { "HERDR_ENV" => "1", "HERDR_BIN_PATH" => bin }
    end

    it "starts a cockpit in a herdr workspace when no chat runs there, inside herdr" do
      started = with_env(herdr('{"result":{"root_pane":{"pane_id":"w9:p1"}}}')) { run("open", feature) }

      expect(started)
        .to eq([0, "no lain chat is running in #{@repo}; started lain up --nvim there in a herdr workspace\n", ""])
    end

    it "says it replaced a held review and started a cockpit for it, inside herdr" do
      run("open", "branch:#{@repo}:other")
      started = with_env(herdr('{"result":{"root_pane":{"pane_id":"w9:p1"}}}')) { run("open", feature) }

      expect(started).to eq([0, "replaced the review held for #{@repo}; started lain up --nvim there in a herdr " \
                                "workspace\n", ""])
    end

    it "exits 1 in 1 line when a file stands where held reviews go" do
      FileUtils.mkdir_p(File.join(ENV.fetch("XDG_STATE_HOME"), "lain", "queue"))
      File.write(File.join(ENV.fetch("XDG_STATE_HOME"), "lain", "queue", "pending"), "")

      status, out, err = run("open", feature)

      expect([status, out, err.lines.size, err]).to match([1, "", 1, /\Alain cannot hold the review in /])
    end

    it "keeps the review held, and says herdr started nothing, when herdr fails" do
      failed = with_env(herdr("")) { run("open", feature) }

      expect(failed).to eq([0, "no lain chat is running in #{@repo}; herdr did not start a workspace, so the review " \
                               "opens with the next lain up --nvim there\n", ""])
    end

    it "refuses a critique for a row that is not a pull request" do
      chat(@repo)

      expect(run("open", feature, "--critique", "x"))
        .to eq([1, "", "a critique focus goes only with a pull request row\n"])
    end

    it "is what pick opens, with no stand-in for open" do
      rail = chat(@repo)
      bin = File.join(ENV.fetch("XDG_RUNTIME_DIR"), "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "chosen"), "\n#{capture("local").first.lines.find { _1.start_with?(feature) }}")
      File.write(File.join(bin, "fzf"), "#!/bin/sh\ncat #{File.join(bin, "chosen")}\n")
      File.chmod(0o755, File.join(bin, "fzf"))

      status, out, = with_env("PATH" => "#{bin}:#{ENV.fetch("PATH")}") { run("pick", "local") }

      expect([status, out]).to eq([0, "offered #{feature} to chat\n"])
      expect(offered(rail)).to start_with("lain queue: /review refs/heads/feature")
    end

    describe "the rows pick lists" do
      def seen_by_pick(source)
        bin = File.join(ENV.fetch("XDG_RUNTIME_DIR"), "bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "fzf"), "#!/bin/sh\ncat > #{File.join(bin, "seen")}\n")
        File.chmod(0o755, File.join(bin, "fzf"))
        with_env("PATH" => "#{bin}:#{ENV.fetch("PATH")}") { run("pick", source) }
        File.read(File.join(bin, "seen"))
      end

      before { finished_plan }

      it "are the plan runs and the branches for here" do
        seen = seen_by_pick("here")

        expect(seen).to include(feature)
        expect(capture("here").first.lines).to all(satisfy { |line| seen.include?(line) })
        expect(capture("here").first.lines.size).to be > capture("local").first.lines.size
      end

      it "are the branches alone for local" do
        seen = seen_by_pick("local")

        expect(seen.lines.sort).to eq(capture("local").first.lines.sort)
        expect(seen).to include(feature)
      end
    end

    it "is what pick opens from the here source too" do
      rail = chat(@repo)
      bin = File.join(ENV.fetch("XDG_RUNTIME_DIR"), "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "chosen"), "\n#{capture("here").first.lines.find { _1.start_with?(feature) }}")
      File.write(File.join(bin, "fzf"), "#!/bin/sh\ncat #{File.join(bin, "chosen")}\n")
      File.chmod(0o755, File.join(bin, "fzf"))

      status, out, = with_env("PATH" => "#{bin}:#{ENV.fetch("PATH")}") { run("pick", "here") }

      expect([status, out]).to eq([0, "offered #{feature} to chat\n"])
      expect(offered(rail)).to start_with("lain queue: /review refs/heads/feature")
    end
  end

  describe "local" do
    it "lists the local changes without the plan runs" do
      finished_plan
      unmerged_branch("feature")

      out, = capture("local")

      expect(out.lines.map { |line| line.split("\t").first }).to eq(["branch:#{@repo}:feature"])
    end
  end

  describe "prs and show on a PR" do
    let(:bin) { File.join(@repo, "..", "queue-bin-#{Process.pid}") }
    let(:title) { "Fix\tthe\nthing\e[31m red\e]0;owned\a" }
    let(:answer) do
      node = {
        "number" => 12, "title" => title, "url" => "https://github.com/acme/api/pull/12", "isDraft" => false,
        "headRefOid" => "a" * 40, "author" => { "login" => "ali\e[31mce\e]0;x\a" },
        "repository" => { "nameWithOwner" => "acme/api" },
        "files" => { "nodes" => [{ "path" => "lib/a.rb" }], "totalCount" => 1 },
        "timelineItems" => { "nodes" => [{ "createdAt" => "2026-11-11T10:30:00Z",
                                           "requestedReviewer" => { "login" => "me" } }] },
        "reviewRequests" => { "nodes" => [{ "asCodeOwner" => false,
                                            "requestedReviewer" => { "__typename" => "User", "login" => "me" } }] },
        "latestReviews" => { "nodes" => [] }
      }
      { "data" => { "viewer" => { "login" => "me", "organizations" => { "nodes" => [] } },
                    "search" => { "issueCount" => 1, "nodes" => [node] } } }
    end

    let(:gh_script) { "#!/bin/sh\nexec cat #{File.join(bin, "answer.json")}\n" }

    around do |example|
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "answer.json"), JSON.generate(answer))
      File.write(File.join(bin, "gh"), gh_script)
      File.chmod(0o755, File.join(bin, "gh"))
      saved = ENV.fetch("PATH")
      ENV["PATH"] = "#{bin}:#{saved}"
      example.run
    ensure
      ENV["PATH"] = saved
      FileUtils.remove_entry(bin)
    end

    it "prints a PR as one line whose title holds no control character" do
      out, = capture("prs")

      expect(out.lines.size).to eq(1)
      fields = out.chomp.split("\t")
      expect(fields.first).to eq("pr:acme/api#12")
      expect(fields.last).to eq("Fix the thing red")
      expect(out).not_to match(/[\e\a]/)
    end

    it "takes --all and --matches on prs alone" do
      expect { capture("here", "--all") }.to raise_error(Thor::UnknownArgumentError, /--all/)
      expect { capture("local", "--matches") }.to raise_error(Thor::UnknownArgumentError, /--matches/)
      expect { capture("show", "pr:acme/api#12", "--json") }.to raise_error(Thor::UnknownArgumentError, /--json/)
    end

    it "prints one JSON object per PR with --json" do
      out, = capture("prs", "--json")

      expect(out.lines.map { |line| JSON.parse(line) })
        .to match([include("id" => "pr:acme/api#12", "reason" => "direct, no local checkout")])
    end

    describe "listing for a human" do
      def listed_at = Lain::Review::Queue::Log.new(paths: Lain::Paths.new).last_listed_at

      it "appends a listed event when prs prints rows" do
        capture("prs")

        expect(listed_at).to be_within(60).of(Time.now)
      end

      it "appends a listed event when pick shows the prs" do
        runtime = File.join(ENV.fetch("XDG_RUNTIME_DIR"), "bin")
        FileUtils.mkdir_p(runtime)
        File.write(File.join(runtime, "fzf"), "#!/bin/sh\ncat >/dev/null\n")
        File.chmod(0o755, File.join(runtime, "fzf"))
        with_env("PATH" => "#{runtime}:#{ENV.fetch("PATH")}") { run("pick", "prs") }

        expect(listed_at).to be_within(60).of(Time.now)
      end

      it "lists pull request rows to pick from" do
        runtime = File.join(ENV.fetch("XDG_RUNTIME_DIR"), "bin")
        FileUtils.mkdir_p(runtime)
        File.write(File.join(runtime, "fzf"), "#!/bin/sh\ncat > #{File.join(runtime, "seen")}\n")
        File.chmod(0o755, File.join(runtime, "fzf"))
        with_env("PATH" => "#{runtime}:#{ENV.fetch("PATH")}") { run("pick", "prs") }

        expect(File.read(File.join(runtime, "seen"))).to include("pr:acme/api#12")
      end

      it "appends none under --json" do
        capture("prs", "--json")

        expect(listed_at).to be_nil
      end

      it "counts only the requests made after the listing as new" do
        log = Lain::Review::Queue::Log.new(paths: Lain::Paths.new)
        log.append(Lain::Review::Queue::Log::Event.new(kind: :listed, at: Time.utc(2026, 11, 12), row_id: nil,
                                                       head_sha: nil))
        with_env("HERDR_BIN_PATH" => "/bin/true") { capture("poll") }
        counts = JSON.parse(File.read(File.join(ENV.fetch("XDG_STATE_HOME"), "lain", "reviews.json")))

        expect(counts).to include("total" => 1, "new_direct" => 0)
      end
    end

    describe "poll" do
      let(:sent) { File.join(bin, "sent.txt") }

      before do
        File.write(File.join(bin, "notify-feed"), "#!/bin/sh\nprintf '%s|' \"$@\" >> #{sent}\ncat >> #{sent}\n")
        File.chmod(0o755, File.join(bin, "notify-feed"))
      end

      it "reads the account from the user's config and the environment, never the directory's project config" do
        FileUtils.mkdir_p(File.join(@repo, ".lain"))
        File.write(File.join(@repo, ".lain", "config.rb"), "github account: \"projacct\"\n")
        File.write(File.join(bin, "gh"), "#!/bin/sh\necho \"$@\" >> #{File.join(bin, "gh.log")}\n" \
                                         "exec cat #{File.join(bin, "answer.json")}\n")
        with_env("HERDR_BIN_PATH" => "/bin/true") { capture("poll") }

        expect(File.read(File.join(bin, "gh.log"))).not_to include("projacct")
        expect(File.exist?(File.join(ENV.fetch("XDG_STATE_HOME"), "lain", "reviews.json"))).to be(true)
      end

      it "writes the count file and notifies once, from the environment and config alone" do
        with_env("HERDR_BIN_PATH" => "/bin/true") do
          capture("poll")
          capture("poll")
        end
        counts = JSON.parse(File.read(File.join(ENV.fetch("XDG_STATE_HOME"), "lain", "reviews.json")))

        expect(counts).to include("total" => 1, "direct" => 1, "new_direct" => 1, "hud" => "rv 1+1")
        expect(File.read(sent).scan("lain-queue|review requested").size).to eq(1)
      end
    end

    context "with a request that reached me through a team" do
      let(:answer) do
        super().tap do |body|
          body["data"]["viewer"]["organizations"]["nodes"] =
            [{ "login" => "acme", "member" => { "nodes" => [{ "slug" => "core" }] }, "admin" => { "nodes" => [] } }]
          body["data"]["search"]["nodes"].first["reviewRequests"]["nodes"] =
            [{ "asCodeOwner" => false, "requestedReviewer" => { "__typename" => "Team", "slug" => "core",
                                                                "organization" => { "login" => "acme" } } }]
        end
      end

      it "hides it by default and lists it with --all" do
        expect(capture("prs").first).to eq("")
        expect(capture("prs", "--all").first).to include("pr:acme/api#12\tteam: acme/core")
      end
    end

    it "runs the keyword and path searches only with --matches" do
      expect(capture("prs").last).not_to include("matches are on")
      expect(capture("prs", "--matches").last).to include("matches are on")
    end

    context "with a clone of it under the configured roots" do
      let(:sockets) { [] }
      let(:clone) { File.join(@roots, "api") }

      around do |example|
        Dir.mktmpdir("lain-cli-queue-roots") do |roots|
          @roots = File.realpath(roots)
          Dir.mktmpdir("lain-cli-queue-home") do |home|
            with_env("XDG_RUNTIME_DIR" => home, "XDG_CONFIG_HOME" => home) { example.run }
          end
        end
      ensure
        sockets.each(&:stop)
      end

      before do
        FileUtils.mkdir_p(clone)
        FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", clone)
        SeedRepo.git(clone, "remote", "add", "origin", "https://github.com/acme/api.git")
        paths = Lain::Paths.new
        FileUtils.mkdir_p(File.dirname(paths.user_config))
        File.write(paths.user_config, "github roots: [#{@roots.inspect}]\n")
        Lain::Project::Trust.for_user(paths:).grant!
      end

      it "sends --critique cut to the focus rule: printable ASCII, at most 80 characters" do
        rail = chat(clone)
        focus = "café\tmigration safety #{"x" * 100}"

        status, = run("open", "pr:acme/api#12", "--critique", focus)

        clamped = "cafe migration safety #{"x" * 58}"
        expect([status, offered(rail)]).to eq(
          [0, "lain queue: /review https://github.com/acme/api/pull/12 --critique=#{Shellwords.escape(clamped)}  " \
              "(Enter opens, x drops)"]
        )
      end

      it "drops an escape sequence in the focus whole" do
        rail = chat(clone)
        run("open", "pr:acme/api#12", "--critique", "cafe \e[31mred\e[0m")

        drawn = offered(rail)

        expect(drawn).to include("--critique=cafe\\ red  (Enter")
        expect(drawn).not_to include("[31m")
      end
    end

    it "opens it in the browser with no local clone, saying the critique was not used" do
      Dir.mktmpdir("lain-cli-queue-config") do |config|
        expect(with_env("XDG_CONFIG_HOME" => config) { run("open", "pr:acme/api#12", "--critique", "x") }).to eq(
          [0, "no local checkout of pr:acme/api#12; opened it in the browser, so --critique was not used\n", ""]
        )
      end
    end

    it "shows the reason, the pull request, its title, author and requested time" do
      out, = capture("show", "pr:acme/api#12")

      expect(out).to include("reason: direct, no local checkout", "range: https://github.com/acme/api/pull/12",
                             "title: Fix the thing red", "author: ali", "requested: 2026-11-11T10:30:00Z")
      expect(out).not_to match(/[\e\a]/)
    end

    describe "finding a row whatever scope listed it" do
      let(:calls) { File.join(bin, "calls.txt") }
      let(:empty) do
        { "data" => { "viewer" => { "login" => "me", "organizations" => { "nodes" => [] } },
                      "search" => { "issueCount" => 0, "nodes" => [] } } }
      end
      let(:requested_file) { "answer.json" }
      let(:gh_script) do
        <<~SH
          #!/bin/sh
          echo "$*" >> #{calls}
          case "$*" in
            *review-requested*) exec cat #{File.join(bin, requested_file)} ;;
            *) exec cat #{File.join(bin, "answer.json")} ;;
          esac
        SH
      end

      around do |example|
        File.write(File.join(bin, "empty.json"), JSON.generate(empty))
        Dir.mktmpdir("lain-cli-queue-find") do |home|
          with_env("XDG_RUNTIME_DIR" => home, "XDG_CONFIG_HOME" => home) do
            paths = Lain::Paths.new
            FileUtils.mkdir_p(File.dirname(paths.user_config))
            File.write(paths.user_config, "github orgs: [\"acme\"], keywords: [\"thing\"]\n")
            Lain::Project::Trust.for_user(paths:).grant!
            example.run
          end
        end
      end

      def gh_calls = File.exist?(calls) ? File.read(calls).scan(/^api graphql/).size : 0

      context "with a request asked only of my team" do
        let(:answer) do
          super().tap do |body|
            body["data"]["viewer"]["organizations"]["nodes"] =
              [{ "login" => "acme", "member" => { "nodes" => [{ "slug" => "core" }] }, "admin" => { "nodes" => [] } }]
            body["data"]["search"]["nodes"].first["reviewRequests"]["nodes"] =
              [{ "asCodeOwner" => false, "requestedReviewer" => { "__typename" => "Team", "slug" => "core",
                                                                  "organization" => { "login" => "acme" } } }]
          end
        end

        it "opens it like a direct one" do
          expect(run("open", "pr:acme/api#12")).to eq(
            [0, "no local checkout of pr:acme/api#12; opened it in the browser\n", ""]
          )
        end
      end

      context "with a pull request only a keyword picks out" do
        let(:requested_file) { "empty.json" }

        it "shows its detail" do
          expect(capture("show", "pr:acme/api#12").first)
            .to include("reason: keyword: thing", "title: Fix the thing red")
        end
      end

      it "makes 1 read for a direct row" do
        capture("show", "pr:acme/api#12")

        expect(gh_calls).to eq(1)
      end

      it "reads the requests once and searches once per configured org on a miss" do
        expect { capture("show", "pr:acme/api#99") }.to raise_error(Thor::Error)

        expect(gh_calls).to eq(2)
      end

      it "still says no queue row for an id nothing lists" do
        expect { capture("show", "pr:acme/api#99") }.to raise_error(Thor::Error, %r{no queue row pr:acme/api#99})
      end
    end
  end

  describe "show on a local row" do
    it "prints the reason and the range" do
      base, head = finished_plan

      out, = capture("show", "plan:planning/run.md")

      expect(out.lines(chomp: true)).to eq(["id: plan:planning/run.md", "reason: plan done: Ship it",
                                            "range: #{base}..#{head}"])
    end

    it "names a row no source lists" do
      expect { capture("show", "plan:nope.md") }.to raise_error(Thor::Error, /no queue row plan:nope.md/)
    end
  end
end
