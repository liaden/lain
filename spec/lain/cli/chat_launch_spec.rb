# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Lain::CLI::ChatLaunch do
  # The lifecycle bracket, driven as a real public object (the point of the
  # extraction): the collaborator factories are injected (the Up
  # shell_out_factory model), so the ORDER the bracket owes -- resume refusal
  # before journal open, close always, conductor preferred over chronicle --
  # is asserted without a TTY, a network edge, or global ENV mutation.
  def launch(options = {}, **factories) = described_class.new(options, **factories)

  # Every launch reads the reap stamp; a stale one starts exactly one detached
  # `lain worktrees gc`. The spawner and the launching binary are injected, so
  # no example here starts a lain process or touches the real state dir.
  describe "the daily worktree reap" do
    around do |example|
      Dir.mktmpdir("lain-chat-gc") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state") }) }
    let(:now) { Time.now }
    let(:spawned) { [] }
    let(:stamp) { Lain::CLI::GcSchedule.new(root: @dir, paths:).stamp_path }

    def schedule_factory
      spawner = ->(argv, **options) { spawned << [argv, options] }
      lambda do |root:|
        Lain::CLI::GcSchedule.new(root:, paths:, clock: -> { now }, spawner:, program: "/opt/lain/exe/lain")
      end
    end

    def stamp_aged(hours)
      FileUtils.mkdir_p(File.dirname(stamp))
      File.write(stamp, "stamped\n")
      File.utime(now - (hours * 3600), now - (hours * 3600), stamp)
    end

    def launch_chat
      wiring = instance_double(Lain::CLI::Wiring, conductor: instance_spy(Lain::CLI::Conductor), exit_status: 0)
      allow(wiring).to receive(:run)
      project = Lain::Project.new(root: @dir, cwd: @dir, kind: :project, detected_by: :flag)
      launch({ journal: false }, wiring_factory: ->(**) { wiring }, project_factory: -> { project },
                                 gc_schedule_factory: schedule_factory).call { |_notice| nil }
    end

    it "spawns exactly one detached gc through the process spawner on a stale stamp, and renews it" do
      stamp_aged(25)

      launch_chat

      expect(spawned.map { |argv, _options| argv.last(2) }).to eq([%w[worktrees gc]])
      expect(spawned.first.last).to include(chdir: @dir, pgroup: true)
      expect(File.mtime(stamp)).to be_within(1).of(now)
    end

    it "spawns nothing on a fresh stamp" do
      stamp_aged(2)

      launch_chat

      expect(spawned).to be_empty
    end

    # Built exactly as `exe/lain chat` builds it, through Thor. Only three
    # things are swapped: the process spawner (so nothing runs), the wiring
    # (so no conversation starts) and the program name (rspec is not lain).
    it "spawns once through the launch exe/lain builds, with only the spawner swapped" do
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      stub_const("Lain::CLI::GcSchedule::SPAWN", ->(argv, **options) { spawned << [argv, options] })
      wiring = instance_double(Lain::CLI::Wiring, conductor: instance_spy(Lain::CLI::Conductor), exit_status: 0)
      allow(wiring).to receive(:run)
      allow(Lain::CLI::Wiring).to receive(:new).and_return(wiring)
      program = $PROGRAM_NAME
      $PROGRAM_NAME = File.expand_path("../../../exe/lain", __dir__)

      with_env("XDG_STATE_HOME" => File.join(@dir, "state")) { LainCLI.start(%w[chat --no-journal], debug: true) }

      expect(spawned.map { |argv, _options| argv }).to eq([[RbConfig.ruby, $PROGRAM_NAME, "worktrees", "gc"]])
    ensure
      $PROGRAM_NAME = program
    end
  end

  describe "#chronicle" do
    it "defaults a bare instance to the Null chronicle" do
      expect(launch.chronicle).to be_a(Lain::CLI::Chronicle::Null)
    end
  end

  describe "resume-before-journal ordering" do
    # The invariant the exe's #chat comment pinned: a resume refusal (nothing
    # to resume, ambiguous selector, mid-tool head) must raise BEFORE any
    # journal file is opened -- a refusal never orphans a fresh journal.
    it "raises the resume refusal before any chronicle (journal) is opened" do
      chronicle_factory = spy("chronicle_factory")
      refusing = ->(**) { raise Lain::Error, "nothing to resume" }

      instance = launch({ resume: "", journal: true, provider: "ollama", model: nil, max_tokens: 16 },
                        resume_factory: -> { refusing_resolver(refusing) },
                        chronicle_factory:)

      expect { instance.call { |_notice| nil } }.to raise_error(Lain::Error, "nothing to resume")
      expect(chronicle_factory).not_to have_received(:call)
    end

    # A refusal leaves no wiring behind, so the ensure falls back to the
    # memoized Null chronicle -- close is a no-op, never a NoMethodError.
    it "still runs the close bracket (Null chronicle) on that refusal" do
      instance = launch({ resume: "", journal: true },
                        resume_factory: -> { refusing_resolver(->(**) { raise Lain::Error, "nothing to resume" }) },
                        chronicle_factory: spy("chronicle_factory"))

      expect { instance.call { |_notice| nil } }.to raise_error(Lain::Error)
      expect(instance.chronicle).to be_a(Lain::CLI::Chronicle::Null)
    end
  end

  # `--non-interactive` is the only chat that OWNS a process exit status, and
  # this object is where the conversation's answer becomes one. Everything else
  # -- a pre-flight, an attended chat -- keeps the exit 0 it has always had.
  describe "#exit_status" do
    it "answers zero when no conversation was ever wired" do
      expect(launch.exit_status).to eq(0)
    end

    it "answers whatever the conversation reached, once one has run" do
      wiring = instance_double(Lain::CLI::Wiring, conductor: instance_spy(Lain::CLI::Conductor), exit_status: 1)
      allow(wiring).to receive(:run)
      instance = launch({ journal: false }, wiring_factory: ->(**) { wiring })

      instance.call { |_notice| nil }

      expect(instance.exit_status).to eq(1)
    end
  end

  describe "--non-interactive" do
    # A headless chat with nothing seeded would sit on a terminal read forever,
    # which is exactly the hang the flag exists to remove -- so the combination
    # is refused before anything opens, on the resume rule's reasoning: a
    # refusal must never orphan a fresh journal.
    it "is refused with no --prompt to run, before any journal is opened" do
      chronicle_factory = spy("chronicle_factory")
      instance = launch({ non_interactive: true, journal: true, provider: "ollama" }, chronicle_factory:)

      expect { instance.call { |_notice| nil } }.to raise_error(Lain::Error, /--non-interactive needs --prompt/)
      expect(chronicle_factory).not_to have_received(:call)
    end

    it "leaves --prompt on its own alone: that chat still seeds and carries on" do
      wiring = instance_double(Lain::CLI::Wiring, conductor: instance_spy(Lain::CLI::Conductor), exit_status: 0)
      allow(wiring).to receive(:run)

      expect { launch({ journal: false, prompt: "why is it red?" }, wiring_factory: ->(**) { wiring }).call { nil } }
        .not_to raise_error
    end
  end

  describe "the ensure-close bracket" do
    let(:conductor) { instance_spy(Lain::CLI::Conductor) }
    let(:wiring) { instance_double(Lain::CLI::Wiring, conductor:).tap { |double| allow(double).to receive(:run) } }
    # `**` (not named kwargs) keeps the factory lambda honest about accepting
    # ChatLaunch's (options:, chronicle:) call without unused-arg noise.
    let(:wiring_factory) { ->(**) { wiring } }

    it "routes close(reason: :exit) through the wiring's conductor when wiring exists" do
      launch({ journal: false }, wiring_factory:).call { |_notice| nil }

      expect(conductor).to have_received(:close).with(reason: :exit)
    end

    it "closes through the conductor even when the conversation raises, then propagates" do
      allow(wiring).to receive(:run).and_raise(Lain::Error, "boom mid-run")

      expect { launch({ journal: false }, wiring_factory:).call { |_notice| nil } }
        .to raise_error(Lain::Error, "boom mid-run")
      expect(conductor).to have_received(:close).with(reason: :exit)
    end

    it "falls back to the chronicle when the raise landed before wiring existed" do
      chronicle = instance_spy(Lain::CLI::Chronicle)
      instance = launch({ journal: true },
                        chronicle_factory: ->(**) { chronicle },
                        wiring_factory: ->(**) { raise Lain::Error, "wiring never built" })

      expect { instance.call { |_notice| nil } }.to raise_error(Lain::Error, "wiring never built")
      expect(chronicle).to have_received(:close).with(reason: :exit)
    end
  end

  # Retargeted from cli_spec.rb (which drove the exe's private helpers via
  # send/instance_variable_get): the same assertions, now on ChatLaunch's real
  # public seams -- open_chronicle, chronicle, live_views. Bodies unchanged
  # beyond the retarget.
  #
  # The two-journal split this block pins: setup_nvim_views used to open its
  # OWN Lain::Journal.open at Journal.default_path, microseconds before
  # open_chronicle opened a SECOND one at the same default path -- almost
  # always the same second-granularity filename by ACCIDENT. When the two
  # calls straddle a second tick, telemetry (request_sent/turn_usage/
  # memory_root) fans through the tee into the NVIM journal while the scribe
  # writes turns into the OTHER file: the durable session record silently
  # loses salvage, bills zero, and skips memory verification. The fix is ONE
  # Journal, opened by the Chronicle; --nvim's tee wraps THAT journal rather
  # than opening its own.
  describe "the --nvim + --journal wiring (one journal, not two)" do
    def context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 16)

    it "opens Journal.default_path exactly once for --journal + --nvim, even across a split-second clock tick" do
      Dir.mktmpdir do |dir|
        with_env("XDG_STATE_HOME" => dir) do
          calls = 0
          allow(Lain::Journal).to receive(:default_path).and_wrap_original do |original, **kwargs|
            calls += 1
            # Simulates the split second: each call would name a DIFFERENT
            # file if more than one were ever made.
            original.call(**kwargs).sub(/\.ndjson\z/, "-take#{calls}.ndjson")
          end

          instance = launch({ journal: true, nvim: "/tmp/lain-cli-spec.sock" })
          instance.open_chronicle

          expect(calls).to eq(1)
          instance.chronicle.close
        end
      end
    end

    it "makes the nvim tee's journal leg the SAME object the scribe writes turns into" do
      Dir.mktmpdir do |dir|
        with_env("XDG_STATE_HOME" => dir) do
          instance = launch({ journal: true, nvim: "/tmp/lain-cli-spec.sock" })
          instance.open_chronicle

          chronicle = instance.chronicle
          nvim_journal = instance.live_views.journal

          expect(nvim_journal).to be(chronicle.instance_variable_get(:@journal))
          chronicle.close
        end
      end
    end

    # Dir.chdir into the tmpdir so the StatusFeed sink (now always on the
    # live-view tee, so `.lain/state.json` publishes for the tmux HUD) writes
    # its state file under the temp tree rather than the repo. The journal path
    # keys off XDG_STATE_HOME, not cwd, so the chdir is invisible to it.
    it "lands telemetry (request_sent/turn_usage/memory_root) in the SAME file the scribe writes turns into" do
      Dir.mktmpdir do |dir|
        with_env("XDG_STATE_HOME" => dir) do
          Dir.chdir(dir) do
            instance = launch({ journal: true, nvim: "/tmp/lain-cli-spec.sock" })
            instance.open_chronicle

            chronicle = instance.chronicle
            chronicle.start(context:, toolset: Lain::Toolset.new)
            chronicle.instrumentation.journal << Lain::Telemetry::TurnUsage.new(
              digest: "blake3:t1", model: nil, stop_reason: :end_turn, usage: {}
            )
            chronicle.close

            session_files = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))
            expect(session_files.size).to eq(1)

            types = File.readlines(session_files.first).map { |line| JSON.parse(line).fetch("type") }
            expect(types).to include("session", "turn_usage")
          end
        end
      end
    end

    # The state feed is a live-view tee sink even without --nvim, so
    # the state file publishes for the tmux HUD (`lain up`'s chat window carries
    # no --nvim). A turn that touched the cache slides the deadline; a
    # journal-only run still fans telemetry through the tee to the state feed.
    #
    # Globbed, not composed: the feed lands under
    # `$XDG_STATE_HOME/lain/status/<project hash>/state.json`, and spelling that
    # hash here would be this fixture rebuilding the recipe
    # `spec/lain/project_dir_spec.rb` forbids `lib/` from rebuilding.
    it "publishes the state feed when telemetry flows, under --journal even with no --nvim" do
      Dir.mktmpdir do |dir|
        with_env("XDG_STATE_HOME" => dir) do
          Dir.chdir(dir) do
            instance = launch({ journal: true })
            instance.open_chronicle

            chronicle = instance.chronicle
            chronicle.start(context:, toolset: Lain::Toolset.new)
            chronicle.instrumentation.journal << Lain::Telemetry::TurnUsage.new(
              digest: "blake3:t1", model: nil, stop_reason: :end_turn,
              usage: { "cache_read_input_tokens" => 10 }
            )
            chronicle.close

            published = Dir.glob(File.join(dir, "lain", "status", "*", "state.json"))
            expect(published.size).to eq(1)
            expect(Dir.exist?(File.join(dir, ".lain"))).to be(false)

            state = JSON.parse(File.read(published.first))
            expect(state).to include("cache_deadline", "fleet", "inbox_count")
            expect(state["cache_deadline"]).not_to be_nil
          end
        end
      end
    end

    # Pure --no-journal --no-nvim opens no tee at all, so a headless-ish run
    # stays byte-identical: no state feed, no state file written. `dir` is BOTH
    # the working directory and `$XDG_STATE_HOME` here, so the absence covers
    # the relocated feed and the retired in-project one at once -- otherwise the
    # example would go vacuous the moment the path moved.
    it "opens no live-view tee (and no state file) under --no-journal --no-nvim" do
      Dir.mktmpdir do |dir|
        with_env("XDG_STATE_HOME" => dir) do
          Dir.chdir(dir) do
            instance = launch({ journal: false })
            instance.open_chronicle

            expect(instance.live_views).to be_nil
            expect(Dir.glob(File.join(dir, "**", "state.json"), File::FNM_DOTMATCH)).to be_empty
          end
        end
      end
    end

    it "still gives nvim its OWN real journal under --no-journal (Null chronicle has no journal to share)" do
      Dir.mktmpdir do |dir|
        with_env("XDG_STATE_HOME" => dir) do
          instance = launch({ journal: false, nvim: "/tmp/lain-cli-spec.sock" })
          instance.open_chronicle

          expect(instance.chronicle).to be_a(Lain::CLI::Chronicle::Null)
          nvim_journal = instance.live_views.journal
          expect(nvim_journal).to be_a(Lain::Journal)

          session_files = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))
          expect(session_files.size).to eq(1) # nvim's own, not the (nonexistent) session record

          nvim_journal.close
        end
      end
    end

    it "opens no journal at all without --nvim" do
      instance = launch({ journal: false })
      instance.open_chronicle

      expect(instance.live_views).to be_nil
    end
  end

  # elapsed/idle/since_compaction are published by the StatusFeed but
  # WRITTEN elsewhere -- Conductor#read_prompt records input on the clock, the
  # tee's Telemetry::Compaction moves it. Two RunClocks would publish an idle
  # that never resets, so the run builds exactly one and both halves get it.
  describe "the run's one RunClock" do
    it "hands the SAME instance to the state feed and to the wiring" do
      given_to_feed = nil
      given_to_wiring = nil
      instance = launch({ journal: false },
                        status_feed_factory: lambda { |run_clock:, context_window:|
                          given_to_feed = run_clock
                          Lain::StatusFeed.new(run_clock:, context_window:)
                        },
                        wiring_factory: lambda { |run_clock:, **|
                          given_to_wiring = run_clock
                          instance_double(Lain::CLI::Wiring,
                                          conductor: instance_spy(Lain::CLI::Conductor)).tap do |double|
                            allow(double).to receive(:run)
                          end
                        })

      instance.call { |_notice| nil }

      expect(given_to_feed).to be_a(Lain::RunClock).and be(given_to_wiring)
    end
  end

  # The run's ONE window book, built from what the provider says it is
  # SERVING rather than from {ContextWindow}'s conservative fallback. The
  # launcher is where the capability becomes live -- a book nothing constructs
  # on the real path is a capability that stayed dormant, which is what the POC
  # measured: 86.4% occupancy published at 2.7% of the true capacity.
  describe "the run's one ContextWindow book" do
    def serving(context_length, model: "qwen3-coder:30b")
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => [{ "name" => model, "model" => model,
                                                      "context_length" => context_length }]))
    end

    def ollama_options(**overrides)
      { journal: false, provider: "ollama", model: "qwen3-coder:30b", max_tokens: 64, **overrides }
    end

    def recording_launch(options, seen)
      launch(options, status_feed_factory: lambda { |run_clock:, context_window:|
        seen << context_window
        Lain::StatusFeed.new(run_clock:, context_window:)
      })
    end

    it "hands the status feed a book measuring against the served window" do
      serving(32_768)
      seen = []

      recording_launch(ollama_options, seen).status_feed

      expect(seen.last.window_tokens("qwen3-coder:30b")).to eq(32_768)
    end

    # One book, not two: the compaction source's denominator and the status
    # line's have to be the same object or a journal reader and a human read
    # two different stories off one turn.
    it "hands the feed the SAME book the compaction source is built from" do
      serving(32_768)
      seen = []
      instance = recording_launch(ollama_options, seen)

      instance.status_feed

      expect(seen.last).to be(instance.backend.context_window)
    end

    # The flag and the `min` constraint, met on the real launch path: the
    # runner resident at 32,768 is reloaded at 16,384 by the very next request.
    it "lets an explicit --num-ctx outrank the window the server currently reports" do
      serving(32_768)
      seen = []

      recording_launch(ollama_options(num_ctx: 16_384), seen).status_feed

      expect(seen.last.window_tokens("qwen3-coder:30b")).to eq(16_384)
    end

    # A silent server is the ORDINARY case (nothing resident yet, or ollama not
    # running), and the conservative fallback is what still has to stand.
    it "keeps the conservative fallback when the server reports no window" do
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => []))
      seen = []

      recording_launch(ollama_options, seen).status_feed

      expect(seen.last.window_tokens("qwen3-coder:30b"))
        .to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
    end
  end

  # The run's ONE {Lain::Project}, resolved here -- the point above both
  # the chronicle and the wiring -- and threaded down, exactly as the RunClock
  # and the StatusFeed above are. Five collaborators read a root off it, and
  # two resolutions could hand them two different projects.
  describe "the run's one Project" do
    def recording_wiring_factory(seen)
      lambda do |project:, **|
        seen << project
        instance_double(Lain::CLI::Wiring, conductor: instance_spy(Lain::CLI::Conductor)).tap do |double|
          allow(double).to receive(:run)
        end
      end
    end

    it "hands the resolved project to the wiring, and keeps it readable" do
      seen = []
      project = Lain::Project.new(root: Dir.pwd, cwd: Dir.pwd, kind: :project, detected_by: :flag)
      instance = launch({ journal: false }, project_factory: -> { project },
                                            wiring_factory: recording_wiring_factory(seen))

      instance.call { |_notice| nil }

      expect(seen).to eq([project])
      expect(instance.project).to be(project)
    end

    # ONE resolution, however many readers ask: the walk touches the disk and,
    # more to the point, two of them could disagree if the tree changed between.
    it "resolves it exactly once" do
      calls = 0
      project = Lain::Project.new(root: Dir.pwd, cwd: Dir.pwd, kind: :project, detected_by: :flag)
      instance = launch({ journal: false },
                        project_factory: lambda {
                          calls += 1
                          project
                        },
                        wiring_factory: recording_wiring_factory([]))

      instance.call { |_notice| nil }
      instance.project

      expect(calls).to eq(1)
    end

    # The resume-before-journal ordering, extended to the project: an
    # unresolvable cwd or an unusable `$HOME` must refuse while the session
    # record is still nothing, so a refusal never orphans a fresh journal.
    it "resolves it before any journal is opened" do
      chronicle_factory = spy("chronicle_factory")
      instance = launch({ journal: true, provider: "ollama", model: nil, max_tokens: 16 },
                        project_factory: -> { raise Lain::Error, "cannot resolve cwd" },
                        chronicle_factory:)

      expect { instance.call { |_notice| nil } }.to raise_error(Lain::Error, "cannot resolve cwd")
      expect(chronicle_factory).not_to have_received(:call)
    end

    it "defaults to the working directory's own project" do
      Dir.mktmpdir("lain-chat-launch-project") do |dir|
        Dir.chdir(File.realpath(dir)) do
          project = launch({ journal: false }).project

          expect([project.root, project.cwd]).to eq([File.realpath(dir), File.realpath(dir)])
        end
      end
    end
  end

  # A resolver double honoring Resume#call's keyword signature.
  def refusing_resolver(refusal)
    resolver = Object.new
    resolver.define_singleton_method(:call) { |selector:, model:| refusal.call(selector:, model:) }
    resolver
  end
end

RSpec.describe Lain::CLI::ChatLaunch, "fork and btw flags" do
  # A launch on `--provider ollama` asks its server which window it is
  # serving before the status feed is built. Nothing here is about that number.
  before do
    stub_request(:get, %r{/api/ps})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate("models" => []))
  end

  # --fork routes through Resume#fork (read-only parent) and, like
  # --resume, must refuse BEFORE any journal opens; --btw threads to
  # Chronicle.for so the journal is born ephemeral.
  it "routes --fork through the resolver's fork method, winning over --resume" do
    forked = ->(**kwargs) { kwargs }
    resolver = Object.new
    resolver.define_singleton_method(:fork) { |selector:, model:| forked.call(selector:, model:) }
    chronicle_factory = spy("chronicle_factory")

    instance = described_class.new({ fork: "@abc123", resume: "ignored", journal: false,
                                     provider: "ollama", model: nil, max_tokens: 16 },
                                   resume_factory: -> { resolver },
                                   chronicle_factory:,
                                   wiring_factory: ->(**) { raise Lain::Error, "stop here" })

    expect { instance.call { |_notice| nil } }.to raise_error(Lain::Error, "stop here")
    expect(chronicle_factory).to have_received(:call).with(hash_including(btw: false))
  end

  it "threads --btw into Chronicle.for as btw: true" do
    chronicle_factory = spy("chronicle_factory")
    instance = described_class.new({ journal: true, btw: true },
                                   chronicle_factory:,
                                   wiring_factory: ->(**) { raise Lain::Error, "stop here" },
                                   live_views_factory: ->(**) {})

    expect { instance.call { |_notice| nil } }.to raise_error(Lain::Error, "stop here")
    expect(chronicle_factory).to have_received(:call).with(enabled: true, btw: true)
  end
end

# The construction-only run `lain up` asks for before it creates a tmux
# session. A refusal a chat raises at construction -- a missing API key, a bad
# --num-ctx, an unknown --compact-strategy -- used to reach the operator only
# from inside a dying pane, where tmux's dead-pane banner eats its first line
# and with it the cause (failure-injection.md §11). `lain up` runs this in a
# child process instead, with the argv it would have put in the pane.
#
# Two bounds define it, and both are asserted below: it opens no record, and it
# asks no server anything. The second is the one that is easy to get wrong --
# an unreachable `--api-base` is a TURN-level failure (failure-injection.md
# §5), so a pre-flight that refused it would stop the cockpit opening for a
# model server that is merely down.
RSpec.describe Lain::CLI::ChatLaunch, "the construction-only pre-flight" do
  # Offline by construction: ollama builds a client without asking anything,
  # and nothing here sets --num-ctx, which is construction's one probe.
  def offline(**overrides)
    { journal: false, provider: "ollama", model: nil, max_tokens: 16 }.merge(overrides)
  end

  describe ".preflight?" do
    it "is off when the variable is unset" do
      expect(described_class.preflight?({})).to be false
    end

    it "is on for exactly 1" do
      expect(described_class.preflight?({ described_class::PREFLIGHT_ENV => "1" })).to be true
    end

    # Not "any non-empty value": LAIN_PREFLIGHT=0 reads as off to everyone who
    # types it, and a chat that silently declined to converse would look like a
    # hang rather than like a mode.
    it "is off for anything else, 0 included" do
      expect(described_class.preflight?({ described_class::PREFLIGHT_ENV => "0" })).to be false
    end
  end

  # The blocker the panel found: LAIN_PREFLIGHT is inherited like any other
  # variable, so a stray one in a shell turned `lain chat` into a process that
  # exited 0 with zero bytes on either stream -- a conversation that never
  # happened and never said so. A mode that cannot be seen is worse than the
  # dead-pane banner this card exists to fix, because the banner eats only ONE
  # line. The notice block is the one output seam this object is lent, and it
  # is where the mode announces itself.
  it "says what it did, rather than exiting silently" do
    said = []

    with_env(described_class::PREFLIGHT_ENV => "1") do
      described_class.new(offline).call { |notice| said << notice }
    end

    expect(said.join).to match(/pre-flight/i)
    expect(said.join).to include(described_class::PREFLIGHT_ENV)
  end

  it "opens no record and holds no conversation" do
    chronicle_factory = spy("chronicle_factory")
    wiring_factory = spy("wiring_factory")

    with_env(described_class::PREFLIGHT_ENV => "1") do
      described_class.new(offline, chronicle_factory:, wiring_factory:).call { |_notice| nil }
    end

    expect(chronicle_factory).not_to have_received(:call)
    expect(wiring_factory).not_to have_received(:call)
  end

  # --resume/--fork resolution READS the record and may repair it, so it is not
  # construction and doing it twice is a change to the session's history. Its
  # refusals stay the pane's to report.
  it "resolves neither --resume nor --fork" do
    resume_factory = spy("resume_factory")

    with_env(described_class::PREFLIGHT_ENV => "1") do
      described_class.new(offline(resume: ""), resume_factory:).call { |_notice| nil }
    end

    expect(resume_factory).not_to have_received(:call)
  end

  describe "the refusals it still raises" do
    def preflighting(options) = described_class.new(options).preflight

    it "refuses --windows without --journal" do
      expect { preflighting(offline(windows: true, journal: false)) }
        .to raise_error(Lain::Error, /--windows needs the session journal/)
    end

    # The pre-flight refuses a SUBSET of what chat refuses, so a refusal chat
    # makes has to be here too or `lain up` loses it into the dead pane.
    it "refuses --non-interactive with nothing to ask" do
      expect { preflighting(offline(non_interactive: true)) }
        .to raise_error(Lain::Error, /--non-interactive needs --prompt/)
    end

    it "refuses a missing ANTHROPIC_API_KEY by name" do
      with_env("ANTHROPIC_API_KEY" => "") do
        expect { preflighting(offline(provider: "anthropic")) }
          .to raise_error(Lain::CLI::Backend::MissingAPIKey, /ANTHROPIC_API_KEY is not set/)
      end
    end

    # The refusal must not state a FALSE cause, which is the whole of this
    # repo's refusal doctrine. A key can be set where it matters -- a tmux
    # server started from a shell that has one hands it to every pane it later
    # spawns -- while this check, reading the environment `lain up` itself was
    # run from, cannot see it. So the message says WHERE it looked and what to
    # do, rather than asserting a global fact it is not in a position to know.
    it "names the environment it looked in, since the chat pane may be handed another" do
      with_env("ANTHROPIC_API_KEY" => "") do
        expect { preflighting(offline(provider: "anthropic")) }
          .to raise_error(Lain::CLI::Backend::MissingAPIKey, /tmux server/)
      end
    end

    it "refuses an unknown --provider by name" do
      expect { preflighting(offline(provider: "nosuchprovider")) }
        .to raise_error(Lain::CLI::UnknownProvider, /nosuchprovider/)
    end

    it "refuses a non-positive --num-ctx by name" do
      expect { preflighting(offline(num_ctx: 0)) }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--num-ctx/)
    end

    it "refuses a scheme-less --api-base by name" do
      expect { preflighting(offline(api_base: "localhost:11434")) }
        .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base/)
    end

    it "refuses an unknown --compact-strategy by name" do
      expect { preflighting(offline(compact: true, compact_strategy: "nosuchstrategy")) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /nosuchstrategy/)
    end

    # A pre-flight must refuse a SUBSET of what chat refuses, never a superset:
    # under --no-compact chat never resolves the flag, so neither may this, or
    # `lain up --no-compact --compact-strategy typo` refuses a chat that would
    # have run.
    it "leaves --compact-strategy alone under --no-compact, exactly as chat does" do
      expect { preflighting(offline(compact: false, compact_strategy: "nosuchstrategy")) }.not_to raise_error
    end

    # The SUMMARIZER tier is a second provider with a second key, and nothing
    # else here asked it to exist. `--summarizer-provider ollama-cloud` with no
    # key used to pre-flight clean and exit 0, then die at the first
    # compaction -- in a pane whose dead-pane banner eats the cause, which is
    # the exact failure this whole method exists to prevent.
    it "refuses a cloud SUMMARIZER arm with no key, not just the chat arm" do
      with_env("OLLAMA_API_KEY" => nil) do
        expect { preflighting(offline(provider: "ollama", summarizer_provider: "ollama-cloud")) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end
    end

    # Not an ollama-cloud fact, and the enumeration is load-bearing on its own
    # because of it: a Backend refuses its own ollama arms at construction, but
    # nothing refuses an ANTHROPIC-summarizer beside an ollama chat until the
    # first compaction tries to build one.
    it "refuses an anthropic SUMMARIZER arm beside a local chat with no key" do
      with_env("ANTHROPIC_API_KEY" => "") do
        expect { preflighting(offline(provider: "ollama", summarizer_provider: "anthropic")) }
          .to raise_error(Lain::CLI::Backend::MissingAPIKey, /ANTHROPIC_API_KEY/)
      end
    end

    it "refuses a cloud CHAT arm with no key" do
      with_env("OLLAMA_API_KEY" => nil) do
        expect { preflighting(offline(provider: "ollama-cloud")) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end
    end

    # The mechanical half of the same finding: Backend::MissingAPIKey and
    # Deployment::MissingAPIKey are SIBLINGS under Lain::Error -- neither is an
    # ancestor of the other -- so a rescue naming one caught nothing of the
    # other and the cloud arm lost the tmux hint. That hint is not an edge case
    # for `lain up --provider ollama-cloud`: it is the modal failure, a key
    # exported in the operator's shell and absent from the tmux server's.
    it "gives the cloud arm the same tmux-environment hint the anthropic arm gets" do
      with_env("OLLAMA_API_KEY" => nil) do
        expect { preflighting(offline(provider: "ollama-cloud")) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /tmux server/)
      end
    end

    it "keeps each arm's own error class through the annotation" do
      expect(Lain::CLI::Backend::MissingAPIKey.ancestors)
        .not_to include(Lain::Provider::Ollama::Deployment::MissingAPIKey)
      expect(Lain::Provider::Ollama::Deployment::MissingAPIKey.ancestors)
        .not_to include(Lain::CLI::Backend::MissingAPIKey)
    end

    # SUBSET, in the direction that bites: a cloud summarizer WITH a key must
    # pre-flight clean, or `lain up` refuses a chat that would have run.
    it "accepts a cloud summarizer arm when the key is there" do
      with_env("OLLAMA_API_KEY" => "sk-preflight-test") do
        expect { preflighting(offline(provider: "ollama", summarizer_provider: "ollama-cloud")) }
          .not_to raise_error
      end
    end
  end

  describe "the network boundary" do
    # The stub registry is not a clean slate here: spec/support/ollama_probe.rb
    # registers /api/ps and /api/show for every example, so an example asserting
    # a request was NEVER made has to reset first (that file says so).
    it "asks no server anything" do
      WebMock.reset!

      expect { described_class.new(offline(api_base: "http://127.0.0.1:1")).preflight }.not_to raise_error
    end

    # Bounded, and degrading to "no ceiling knowable" -- so an endpoint nothing
    # is listening on still launches. This is the case that separates a flag
    # that cannot be resolved from a server that cannot be reached.
    it "does not refuse an --api-base nothing answers on" do
      stub_request(:post, %r{/api/show}).to_timeout

      expect { described_class.new(offline(api_base: "http://10.255.255.1:11434", num_ctx: 8192)).preflight }
        .not_to raise_error
    end

    # `--num-ctx` was the one flag whose resolution asked a server: the trained
    # maximum it is checked against is a fact only a running one has. That
    # question belongs to {#call} now, so the rule above holds for every flag
    # rather than for all but one.
    it "asks no server anything with --num-ctx set either" do
      WebMock.reset!
      show = stub_request(:post, %r{/api/show}).to_timeout

      expect { described_class.new(offline(api_base: "http://127.0.0.1:1", num_ctx: 8192)).preflight }
        .not_to raise_error

      expect(show).not_to have_been_requested
    end

    # Where that refusal went, and the ordering it keeps: only a running server
    # publishes the number an unservable `--num-ctx` is checked against, so the
    # LAUNCH asks and the pre-flight does not -- and it asks on the resume
    # rule's reasoning, before the record exists, so a refusal orphans nothing.
    def trained_at(context_length)
      stub_request(:post, %r{/api/show})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("model_info" => { "general.architecture" => "qwen3moe",
                                                         "qwen3moe.context_length" => context_length }))
    end

    it "refuses an unservable --num-ctx before any journal is opened, naming the trained maximum" do
      trained_at(262_144)
      chronicle_factory = spy("chronicle_factory")
      instance = described_class.new(offline(num_ctx: 999_999, journal: true), chronicle_factory:)

      expect { instance.call { |_notice| nil } }
        .to raise_error(Lain::CLI::Backend::UnservableWindow,
                        /--num-ctx 999999 is above the model's trained maximum of 262144/)
      expect(chronicle_factory).not_to have_received(:call)
    end

    # The same ordering against the other two things a launch leaves behind: a
    # resume may SALVAGE, committing a Timeline and writing the session file for
    # a torn recording, and the reap spawns a detached process. A refusal after
    # either is residue a closed journal is not.
    it "salvages no resume and schedules no reap when --num-ctx is refused" do
      trained_at(262_144)
      resume_factory = spy("resume_factory")
      gc = spy("gc_schedule")
      gc_schedule_factory = ->(**) { gc }
      instance = described_class.new(offline(num_ctx: 999_999, resume: ""), resume_factory:, gc_schedule_factory:)

      expect { instance.call { |_notice| nil } }.to raise_error(Lain::CLI::Backend::UnservableWindow)
      expect(resume_factory).not_to have_received(:call)
      expect(gc).not_to have_received(:call)
    end
  end
end
