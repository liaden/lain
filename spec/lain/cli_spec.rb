# frozen_string_literal: true

# exe/lain is a script, not a lib file: it ends in `LainCLI.start(ARGV)`,
# guarded by `$PROGRAM_NAME == __FILE__` so this `load` defines the class
# WITHOUT parsing rspec's ARGV or touching the network. We test at the Thor
# class seam -- build_provider/build_context/build_agent -- rather than by
# spawning one. The exception is the `:seam` block at the FOOT of this file:
# the exe's bundler line is invisible to a `load` into an already-bundled
# process, so nothing but a subprocess in a foreign directory can see it.
load File.expand_path("../../exe/lain", __dir__)

RSpec.describe LainCLI do
  let(:toolset) { Lain::Toolset.new }
  let(:channel) { Lain::Channel.new }

  # T10: `--provider ollama` asks its server which window it is serving before
  # the run's book is built ({Lain::CLI::Backend#context_window}). Nothing here
  # is about that number, and "nothing resident" leaves
  # {Lain::ContextWindow::CONSERVATIVE_FALLBACK} in charge exactly as before.
  before do
    stub_request(:get, %r{/api/ps})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate("models" => []))
  end

  # The provider/model choice lives in Backend, a plain object over the flags,
  # so it is exercised directly -- no Thor instance, no network.
  def backend(**options) = LainCLI::Backend.new(options)

  # The chat-assembly seams (build_toolset/build_agent) moved off the Thor
  # class into Lain::CLI::Wiring, so they are exercised on a Wiring built with a
  # plain options hash and the Null chronicle -- the same records-nothing duct
  # a directly-constructed CLI instance used to get from #chronicle.
  def wiring(chronicle: Lain::CLI::Chronicle::Null.new, **options)
    Lain::CLI::Wiring.new(options:, chronicle:, status_feed: instance_double(Lain::StatusFeed))
  end

  describe LainCLI::Backend, "#provider" do
    it "constructs a Provider::Ollama honoring --api-base" do
      provider = backend(provider: "ollama", api_base: "http://localhost:11434").provider
      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(provider.instance_variable_get(:@config).ollama_api_base).to eq("http://localhost:11434")
    end

    it "constructs a Provider::Anthropic for --provider anthropic" do
      # Anthropic reads ANTHROPIC_API_KEY at construction too (offline, no
      # request); a placeholder is enough to build the object.
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend(provider: "anthropic").provider
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
    end

    it "fails loudly on an unknown provider, naming the valid set" do
      expect { backend(provider: "gemini").provider }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "gemini", expected one of.*anthropic.*ollama/m)
    end

    it "constructs a Provider::Bedrock for --provider bedrock" do
      # Bedrock is env-configured, same as Anthropic above: Bedrock reads
      # AWS_BEARER_TOKEN_BEDROCK / AWS_REGION at construction (offline, no
      # request); stub them so the object can be built without the developer's
      # shell leaking in or the run failing for a missing region.
      provider = with_env("AWS_BEARER_TOKEN_BEDROCK" => "tok", "AWS_REGION" => "us-east-1") do
        backend(provider: "bedrock").provider
      end
      expect(provider).to be_a(Lain::Provider::Bedrock)
    end
  end

  describe "provider-dependent --model default" do
    it "defaults to Ollama's model when --provider ollama and no --model" do
      agent = wiring
              .send(:build_agent, toolset:, channel:, session: Lain::Session.new,
                                  backend: backend(provider: "ollama", api_base: nil, model: nil, max_tokens: 4096))
      expect(agent.context.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    # session: is required on build_agent -- a defaulted fresh Session would
    # let a caller wire a recorder-bearing toolset to an agent whose manifest
    # can never see that recorder, with no error anywhere (T1 panel fix).
    it "requires session: on build_agent so memory cannot be silently mis-wired" do
      backend = LainCLI::Backend.new({ provider: "ollama" })
      expect { wiring.send(:build_agent, toolset:, channel:, backend:) }.to raise_error(ArgumentError, /session/)
    end

    it "honors an explicit --model over the provider default" do
      model = backend(provider: "ollama", model: "qwen3:8b", max_tokens: 4096).context.model
      expect(model).to eq("qwen3:8b")
    end

    it "defaults to Bedrock's model when --provider bedrock and no --model" do
      model = backend(provider: "bedrock", model: nil, max_tokens: 4096).context.model
      expect(model).to eq("anthropic.claude-opus-4-8")
    end

    it "the chat command's --provider flag defaults to anthropic" do
      expect(described_class.commands.fetch("chat").options.fetch(:provider).default).to eq("anthropic")
    end
  end

  describe "--help text" do
    it "lists bedrock alongside anthropic and ollama in the --provider description" do
      description = described_class.commands.fetch("chat").options.fetch(:provider).description
      expect(description).to include("anthropic").and include("ollama").and include("bedrock")
    end

    it "still scopes the --api-base description to ollama" do
      description = described_class.commands.fetch("chat").options.fetch(:api_base).description
      expect(description).to match(/ollama/i)
      expect(description).not_to match(/bedrock/i)
    end
  end

  # T1 AC6: the chat toolset closes the memory loop -- the model can read
  # back, through memory_read, what it wrote through the SAME toolset's
  # memory_write, because both tools share the one session Recorder.
  describe "the chat toolset" do
    let(:recorder) { Lain::Memory::Recorder.new }
    # The research subagent this toolset wires in builds its own provider
    # eagerly (Anthropic validates ANTHROPIC_API_KEY at construction, unlike
    # the SDK client it replaced there -- see T17w), so building the toolset
    # at all needs a key present even though nothing here makes a request.
    let(:chat_toolset) do
      ask_human = Lain::Tools::AskHuman.new(parent: -> {})
      with_env("ANTHROPIC_API_KEY" => "sk-test") do
        wiring.send(:build_toolset, recorder, backend: backend(provider: "anthropic"),
                                              parent: -> {}, journal: Lain::Channel.new, ask_human:)
      end
    end

    it "contains a memory_read tool" do
      expect(chat_toolset.names).to include("memory_read")
    end

    it "reads back an id written through the same toolset's memory_write" do
      written = chat_toolset.fetch("memory_write")
                            .call({ "id" => "aspirin-dosing",
                                    "description" => "Aspirin dosing bounds for adults",
                                    "body" => "81mg to 325mg daily" })
      expect(written.ok?).to be(true)

      read = chat_toolset.fetch("memory_read").call({ "id" => "aspirin-dosing" })
      expect(read.ok?).to be(true)
      expect(read.content).to eq("81mg to 325mg daily")
    end
  end

  # T13: the session-record lifecycle lives in Lain::CLI::Chronicle (see its
  # spec); the chat bracket that opens/closes it lives in Lain::CLI::ChatLaunch
  # (see chat_launch_spec, where the Null default and the --nvim/--journal
  # wiring examples moved). Wiring drives the assembly seams over the Null
  # duck, so build_toolset/build_agent record nothing here.
  describe "the chronicle seam" do
    # `@instrumentation` is fetched, not read with a bare instance_variable_get:
    # this assertion was `@turn_middleware.to_a == []` before T22, and `nil.to_a`
    # is `[]` -- so it passed unchanged after the ivar it names stopped existing.
    # An empty expectation has to prove it measured something first.
    it "wires the chronicle's (empty, for Null) turn middleware into build_agent" do
      agent = wiring.send(:build_agent, toolset:, channel:, session: Lain::Session.new,
                                        backend: backend(provider: "ollama", model: nil, max_tokens: 4096))
      agent.instance_variables.include?(:@instrumentation) or
        raise KeyError, "the Agent no longer carries @instrumentation: this seam needs updating"
      instrumentation = agent.instance_variable_get(:@instrumentation)

      expect(instrumentation).to be_a(Lain::Agent::Instrumentation)
      expect(instrumentation.turn_middleware.to_a).to eq([])
      # The tool phase over the SAME chronicle is NOT empty, so "empty" above is
      # a reading of the Null chronicle and not of an unwired instrumentation.
      expect(instrumentation.tool_middleware.to_a.map(&:class))
        .to eq([Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths])
    end
  end

  # AC2: --temperature 0 --seed 7 reach the Ollama wire payload's options, but
  # NOT the Request digest -- temperature is a sampler knob, not a prompt.
  describe "temperature and seed threading" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    def render(**options)
      backend(**options).context.render(timeline:, toolset:)
    end

    it "carries options.temperature 0 and options.seed 7 into the encoded payload" do
      request = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: 0, seed: 7)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to include(temperature: 0, seed: 7)
    end

    it "renders a Request whose cache_payload is identical to the flagless render" do
      tuned = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: 0, seed: 7)
      plain = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: nil, seed: nil)
      expect(tuned.cache_payload).to eq(plain.cache_payload)
      expect(tuned).to have_same_digest_as(plain)
    end

    it "omits absent sampler keys entirely (0 is present, nil is not)" do
      request = render(provider: "ollama", model: nil, max_tokens: 4096, temperature: 0, seed: nil)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to eq(temperature: 0)
    end
  end

  # A real notifier is opt-in ({Lain::Notify.for} refuses to build one for a
  # caller that did not ask), and THIS flag is the opt-in a human's normal
  # `lain chat` supplies. Read off Thor's own declaration rather than by
  # spawning a chat: the default IS the whole of what keeps the human notified,
  # and `spec/lain/cli/wiring_spec.rb` pins that a run carrying it gets the real
  # adapter. The pair is what says the desktop gate silenced agents and specs
  # without silencing the human.
  describe "chat's --desktop flag" do
    let(:desktop) { described_class.commands.fetch("chat").options.fetch(:desktop) }

    it "defaults ON, so a human typing `lain chat` still gets desktop notifications" do
      expect(desktop.default).to be(true)
    end

    it "is a boolean, so `--no-desktop` silences one run without an env var" do
      expect(desktop.type).to eq(:boolean)
    end
  end

  # `up` trailing args ride Thor's real `.start` argv path (method_option
  # defaults and the post-`--` splat both exist only there), so these examples
  # drive `.start` itself with Up and Kernel.exec doubled out.
  describe "up argv threading through .start" do
    let(:plan) { Lain::CLI::Up::LaunchPlan.new(messages: [], argv: %w[tmux attach]) }

    # `debug: true` so Thor RE-RAISES a refusal instead of turning it into
    # `exit(1)`: RSpec does not rescue SystemExit inside an example, so an
    # unexpected refusal here ends the whole run and reports the examples that
    # had already passed as a clean pass. Measured against a deliberate
    # regression in `up`'s argv split, which stopped the run 22 examples short
    # with one reported failure.
    it "routes post--- args into Up.new(chat_args:)" do
      up = instance_double(Lain::CLI::Up, launch_plan: plan)
      allow(Lain::CLI::Up).to receive(:new).and_return(up)
      allow(Kernel).to receive(:exec)

      described_class.start(["up", "--", "--model", "claude-x", "--no-journal"], debug: true)

      expect(Lain::CLI::Up).to have_received(:new)
        .with(hash_including(chat_args: ["--model", "claude-x", "--no-journal"]))
    end

    # A SECOND stray positional, because the first is `up`'s PATH now -- a lone
    # `lain up typo` is a directory that does not exist, and refuses as one.
    it "refuses trailing args when the invocation carried no -- separator" do
      expect(Lain::CLI::Up).not_to receive(:new)
      expect { described_class.start(%w[up /tmp typo]) }
        .to output(/pass chat flags after `--`/).to_stderr
        .and raise_error(SystemExit)
    end

    # The cockpit is what `lain up` is FOR, so a bare invocation gets it
    # without a flag. Up's contract is unchanged and asserted in its own terms:
    # "" is the derive-the-per-project-socket value, nil is off.
    #
    # `debug: true` for the reason above: an unexpected refusal here would
    # `exit(1)` rather than fail, ending the run and reporting the examples
    # that had already passed as a clean pass. Measured on this very helper --
    # a deliberate regression in `up`'s argv split took the file from 32
    # examples to 22, reporting "0 failures", and the truncation point moved
    # with the seed.
    def start_up(argv)
      allow(Lain::CLI::Up).to receive(:new).and_return(instance_double(Lain::CLI::Up, launch_plan: plan))
      allow(Kernel).to receive(:exec)

      described_class.start(argv, debug: true)
    end

    it "spawns the nvim cockpit by default, with no flag at all" do
      start_up(%w[up])

      expect(Lain::CLI::Up).to have_received(:new).with(hash_including(nvim: ""))
    end

    # `--no-nvim` is Thor's own negation of a BOOLEAN `--nvim` now, not a
    # separately declared flag: `--nvim` used to take an optional value, which
    # meant it swallowed the token after it -- fatal once `up` grew a PATH.
    it "takes --no-nvim as the opt-out, handing Up the nil that means off" do
      start_up(%w[up --no-nvim])

      expect(Lain::CLI::Up).to have_received(:new).with(hash_including(nvim: nil))
    end

    it "still honours an explicit socket, now spelled --nvim-socket, over the default" do
      start_up(%w[up --nvim-socket /tmp/explicit.sock])

      expect(Lain::CLI::Up).to have_received(:new).with(hash_including(nvim: "/tmp/explicit.sock"))
    end
  end
end

# The one thing about `exe/lain` that only a SUBPROCESS can say, which is why
# these are the only examples in this file that spawn one: everything above
# `load`s the exe into THIS process, where bundler has long since been set up
# by `bundle exec rspec` -- so no example up there can see the require line at
# all, and none did while `lain` was unable to start in anybody else's
# repository.
#
# Found by the manual pass, 2026-08-05, against a real checkout of rack:
# `lain review open 2490` died in `Bundler::GemNotFound` looking for one of
# RACK's development dependencies. `bundler/setup` resolves the Gemfile it
# finds by walking UP FROM THE CWD, and reviewing somebody else's repository
# means running there. It is the review surface's whole use case.
#
# `help` is the payload because it is the cheapest command that still proves
# the whole boot ran: it needs Thor, `require "lain"` and the compiled
# extension, touches no network and writes no state, and it returned in ~1s.
RSpec.describe "exe/lain outside its own repository", :seam do
  let(:exe) { File.expand_path("../../exe/lain", __dir__) }
  let(:lib) { File.expand_path("../../lib", __dir__) }

  # BUNDLE_* and RUBYOPT are how `bundle exec rspec` reaches its children, and
  # inheriting them would hand the child THIS bundle and hide the defect
  # entirely -- the child would pass no matter what the exe did.
  # The env hash is IO.popen's OWN first argument, never the head of the command
  # array: inside the array it is not read as an environment at all, RUBYOPT
  # survives as `-rbundler/setup`, and the child then loads bundler from
  # gem_prelude BEFORE reaching a line of this exe -- which fails identically
  # whether the exe is fixed or not. That mistake made the first draft of these
  # examples red against the fix, for a reason that had nothing to do with it.
  # BUNDLER_SETUP is the one that is easy to miss and defeats the whole file:
  # rubygems reads it from `<internal:gem_prelude>` (`rubygems.rb`'s last line,
  # `require ENV["BUNDLER_SETUP"] if …`), so bundler is loaded BEFORE the first
  # line of the exe and the child dies identically whether the exe is fixed or
  # not. Clearing RUBYOPT alone is not enough, which cost a debugging round.
  def runner_env
    { "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "BUNDLE_BIN_PATH" => nil,
      "BUNDLE_APP_CONFIG" => nil, "BUNDLER_SETUP" => nil }
  end

  def lain(*argv, chdir:, script: exe)
    out = IO.popen(runner_env, [RbConfig.ruby, "-I#{lib}", script, *argv],
                   chdir:, err: %i[child out], &:read)
    [out, $CHILD_STATUS.exitstatus]
  end

  # A Gemfile naming a gem that cannot exist, so a resolution that reaches it
  # fails LOUDLY and by name. A real project's Gemfile would work too and would
  # make the failure depend on what happens to be installed.
  def hostile_project
    Dir.mktmpdir("lain-foreign-project") do |dir|
      File.write(File.join(dir, "Gemfile"),
                 %(source "https://rubygems.org"\ngem "a-gem-that-cannot-exist-#{SecureRandom.hex(6)}"\n))
      yield dir
    end
  end

  it "starts in a project whose Gemfile it cannot resolve, rather than dying in that project's bundle" do
    hostile_project do |dir|
      output, status = lain("help", chdir: dir)

      expect(output).not_to include("Bundler::GemNotFound")
      expect(status).to eq(0)
    end
  end

  # The INSTALLED gem, simulated by the one difference that matters: the
  # packaged gem ships no Gemfile beside `exe/` (verified against
  # pkg/lain-0.1.0.gem), so the guard sees no sibling and skips bundler
  # entirely. Copying the script is what reproduces that layout without
  # requiring a build.
  it "boots with no bundler at all when no Gemfile sits beside it, as the packaged gem does not" do
    hostile_project do |dir|
      Dir.mktmpdir("lain-fake-gem") do |gem_dir|
        installed = File.join(gem_dir, "exe")
        FileUtils.mkdir_p(installed)
        FileUtils.cp(exe, File.join(installed, "lain"))

        output, status = lain("help", chdir: dir, script: File.join(installed, "lain"))

        expect(output).not_to include("Bundler")
        expect(status).to eq(0)
      end
    end
  end

  # The half a guard alone does not fix, and the reason BUNDLE_GEMFILE is
  # pinned rather than merely conditioned: a source checkout run from
  # elsewhere -- `ruby ~/dev/lain/exe/lain` inside the repository under review
  # -- still had `bundler/setup` walking up from the CWD to the wrong Gemfile.
  it "resolves ITS OWN Gemfile from a source checkout, not the one it is standing in" do
    hostile_project do |dir|
      output, status = lain("help", chdir: dir)

      expect(status).to eq(0)
      expect(output).to include("lain review")
    end
  end
end

# T-env: the `direnv` case -- a project pins its endpoint in `.envrc` and stops
# retyping it. Driven through `LainCLI`'s REAL option parsing rather than by
# calling EnvDefaults directly, because the thing that can break is the wiring
# between the two: a `default:` evaluated at class-body load, which is a place
# where "I read the env" and "Thor used what I read" are separate claims.
RSpec.describe LainCLI, "endpoint flags from the environment" do
  # The Thor class body has already run, so its defaults are frozen at whatever
  # the env held when `load` happened. Re-declaring onto a throwaway Thor
  # subclass is what lets an example choose the environment first -- and it
  # exercises the same `ModelFlags.declare` the exe calls.
  # `debug: true` on the same rule as `start_up` above: Thor renders a refusal
  # as `exit(1)`, RSpec does not rescue SystemExit inside an example, and a
  # truncated run reports what had already passed as a pass.
  def options_under(env, argv)
    seen = []
    with_env(env) do
      probe_class(seen).start(["probe", *argv], debug: true)
    end
    seen.first
  end

  # A throwaway Thor whose only command records what Thor parsed. `seen` is
  # closed over rather than assigned to a global, which the cop forbids and
  # which would leak between examples anyway.
  def probe_class(seen)
    Class.new(Thor) do
      def self.exit_on_failure? = true
      LainCLI::ModelFlags.declare(self)
      desc "probe", "capture parsed options"
      define_method(:probe) { seen << options }
    end
  end

  it "takes the provider and model from LAIN_PROVIDER and LAIN_MODEL" do
    options = options_under({ "LAIN_PROVIDER" => "ollama", "LAIN_MODEL" => "qwen3:4b" }, [])

    expect(options["provider"]).to eq("ollama")
    expect(options["model"]).to eq("qwen3:4b")
  end

  # PRECEDENCE, and the reason the reader sits in the `default:` slot: Thor
  # consults a default only when the flag is absent, so this holds without
  # anything comparing parsed options against defaults afterward -- the version
  # that cannot tell `--provider ollama` from silence.
  it "lets an explicit flag beat the environment" do
    options = options_under({ "LAIN_PROVIDER" => "ollama" }, ["--provider", "bedrock"])

    expect(options["provider"]).to eq("bedrock")
  end

  it "falls back to the built-in default when the environment says nothing" do
    options = options_under({ "LAIN_PROVIDER" => nil, "LAIN_MAX_TOKENS" => nil }, [])

    expect(options["provider"]).to eq("anthropic")
    expect(options["max_tokens"]).to eq(4_096)
  end

  it "reads the numeric band as numbers, not strings" do
    options = options_under({ "LAIN_MAX_TOKENS" => "8192", "LAIN_TEMPERATURE" => "0.7" }, [])

    expect(options["max_tokens"]).to eq(8_192)
    expect(options["temperature"]).to eq(0.7)
  end

  # Thor validates an `enum:` BEFORE it dispatches, so this list is a scope
  # vocabulary like any other -- and the one most easily missed, because a
  # registry that knows about a strategy while Thor does not fails at the flag
  # with the registry never consulted. `lain review --scope by_directory` was
  # exactly that failure until A3.
  describe "the --scope flag of `lain review open`" do
    def scope_option = LainCLI::Review.commands.fetch("open").options.fetch(:scope)

    it "offers every registered strategy, so shipping one is all it takes to reach it" do
      expect(scope_option.enum).to match_array(Lain::Review::Partition::STRATEGIES.values.map(&:name))
    end

    it "offers nothing the registry would then refuse" do
      expect { scope_option.enum.each { |scope| Lain::Review::Session.scope!(scope) } }.not_to raise_error
    end
  end

  # The rule this whole seam is drawn on: the environment may say HOW the model
  # answers, never what lain is ALLOWED to do or whether it keeps a record. A
  # stray export must not disable the approval gate for every session started in
  # that directory, and must not silently stop the Journal.
  it "refuses to take approval or journalling from the environment" do
    source = File.read(File.expand_path("../../exe/lain", __dir__))

    expect(source).not_to include("LAIN_YOLO")
    expect(source).not_to include("LAIN_JOURNAL")
  end
end
