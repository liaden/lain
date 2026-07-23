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

  describe "the ensure-close bracket" do
    let(:conductor) { spy("conductor") }
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
      chronicle = spy("chronicle")
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

    # Dir.chdir into the tmpdir so the I1 StatusFeed sink (now always on the
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
            chronicle.telemetry_kwargs.fetch(:journal) << Lain::Telemetry::TurnUsage.new(
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

    # I1 wiring: the state feed is a live-view tee sink even without --nvim, so
    # `.lain/state.json` publishes for the tmux HUD (`lain up`'s chat window
    # carries no --nvim). A turn that touched the cache slides the deadline; a
    # journal-only run still fans telemetry through the tee to the state feed.
    it "publishes .lain/state.json when telemetry flows, under --journal even with no --nvim" do
      Dir.mktmpdir do |dir|
        with_env("XDG_STATE_HOME" => dir) do
          Dir.chdir(dir) do
            instance = launch({ journal: true })
            instance.open_chronicle

            chronicle = instance.chronicle
            chronicle.start(context:, toolset: Lain::Toolset.new)
            chronicle.telemetry_kwargs.fetch(:journal) << Lain::Telemetry::TurnUsage.new(
              digest: "blake3:t1", model: nil, stop_reason: :end_turn,
              usage: { "cache_read_input_tokens" => 10 }
            )
            chronicle.close

            state = JSON.parse(File.read(File.join(dir, ".lain", "state.json")))
            expect(state).to include("cache_deadline", "fleet", "inbox_count")
            expect(state["cache_deadline"]).not_to be_nil
          end
        end
      end
    end

    # Pure --no-journal --no-nvim opens no tee at all, so a headless-ish run
    # stays byte-identical: no state feed, no state.json written.
    it "opens no live-view tee (and no state.json) under --no-journal --no-nvim" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          instance = launch({ journal: false })
          instance.open_chronicle

          expect(instance.live_views).to be_nil
          expect(File.exist?(File.join(dir, ".lain", "state.json"))).to be(false)
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

  # A resolver double honoring Resume#call's keyword signature.
  def refusing_resolver(refusal)
    resolver = Object.new
    resolver.define_singleton_method(:call) { |selector:, model:| refusal.call(selector:, model:) }
    resolver
  end
end
