# frozen_string_literal: true

require "json"
require "open3"
require "stringio"
require "tmpdir"

# bin/qa-lain, like exe/lain, ends in a guarded `.start`, so this `load` defines
# the Thor class without parsing rspec's ARGV.
load File.expand_path("../../bin/qa-lain", __dir__)

RSpec.describe QALain do
  let(:root) { File.expand_path("../..", __dir__) }

  it "declares review and survey, each routing a bare target through `open`" do
    expect([described_class.subcommand_classes["review"], described_class.subcommand_classes["survey"]])
      .to eq([QALain::Review, QALain::Survey])
    expect([QALain::Review, QALain::Survey].map(&:default_command)).to eq(%w[open open])
  end

  it "refuses an unknown switch on review, naming it" do
    expect { described_class.start(%w[review open feature/x --nope], debug: true) }
      .to raise_error(Thor::UnknownArgumentError, /--nope/)
  end

  it "hands review's scope and base to the lib as a Symbol and a String" do
    review = instance_double(Lain::CLI::Review, present: "drawn")
    allow(Lain::CLI::Review).to receive(:new).and_return(review)

    expect { described_class.start(%w[review feature/x --scope by_directory --base main], debug: true) }
      .to output(/drawn/).to_stdout
    expect(review).to have_received(:present).with("feature/x", scope: :by_directory, base: "main")
  end

  it "offers every registered strategy on review's --scope" do
    scope = QALain::Review.commands.fetch("open").options.fetch(:scope)

    expect(scope.enum).to match_array(Lain::Review::Partition::STRATEGIES.values.map(&:name))
  end

  describe "the executables", :seam do
    def run_exe(*argv, chdir: root, env: {})
      Open3.capture3({ "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "BUNDLER_SETUP" => nil }.merge(env),
                     RbConfig.ruby, *argv, chdir:)
    end

    def git(dir, *args)
      out, status = Open3.capture2e(SeedRepo::SCRUB, "git", "-C", dir, *args)
      raise out unless status.success?
    end

    it "reviews a branch as text" do
      Dir.mktmpdir("qa-lain-review") do |dir|
        git(dir, "init", "-q", "-b", "main")
        File.write(File.join(dir, "a.rb"), "a\n")
        git(dir, "add", ".")
        git(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "base")
        git(dir, "checkout", "-q", "-b", "feature/x")
        File.write(File.join(dir, "a.rb"), "a\nb\n")
        git(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qam", "change")

        env = { "HOME" => dir, "XDG_STATE_HOME" => File.join(dir, "state"),
                "XDG_CACHE_HOME" => File.join(dir, "cache") }
        out, err, status = run_exe(File.join(root, "bin/qa-lain"), "review", "feature/x", chdir: dir, env:)

        expect([status.success?, out, err]).to match([true, %r{feature/x.*a\.rb}m, ""])
      end
    end

    it "lists review, survey, bench, usage, friction and verify under qa-lain and none under lain" do
      qa, = run_exe(File.join(root, "bin/qa-lain"), "help")
      lain, = run_exe(File.join(root, "exe/lain"), "help")

      expect(qa).to match(/qa-lain review.*qa-lain survey/m)
      expect(qa).to include("qa-lain bench", "qa-lain usage", "qa-lain friction", "qa-lain verify")
      expect(lain).not_to match(/lain (review|survey|bench|usage|friction|verify)\b/)
    end

    it "boots both through Lain::Boot::Launch, which itself writes nothing to stderr" do
      sources = %w[exe/lain bin/qa-lain].map { File.read(File.join(root, _1)) }
      launch = File.read(File.join(root, "lib/lain/boot/launch.rb"))

      expect(sources).to all(include("Lain::Boot::Launch.call"))
      expect(launch).not_to match(/\b(?:abort|warn)\b|\$stderr|STDERR/)
    end
  end

  describe "the QA sandbox shims", :seam do
    it "writes a lain and a qa-lain shim, each under ruby 4.0.9" do
      Dir.mktmpdir("qa-shim") do |home|
        script = File.join(root, ".claude/skills/manual-qa/scripts/qa-sandbox.sh")
        _, err, status = Open3.capture3({ "HOME" => home }, "bash", script, "shimtag", root)
        shims = %w[lain qa-lain].map { File.read(File.join(home, "tmp/lain-qa-shimtag/shim", _1)) }

        expect(status.success?).to be(true), err
        expect(shims.map { _1[/ruby@[\d.]+/] }).to eq(["ruby@4.0.9"] * 2)
        expect(shims.map { _1[%r{exec "[^"]+/(exe/lain|bin/qa-lain)"}, 1] }).to eq(%w[exe/lain bin/qa-lain])
      end
    end
  end

  describe "bench, verify, usage and friction live here and not under lain" do
    # The model-calling bench commands build a provider backend, which asks ollama
    # what window it serves; nothing here is about that number.
    before do
      stub_request(:get, %r{/api/ps})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => []))
    end

    def help_for(*argv)
      printed = StringIO.new
      original = $stdout
      $stdout = printed
      described_class.start([*argv, "--help"], debug: true)
      printed.string
    ensure
      $stdout = original
    end

    it "declares the four verbs, bench as a subcommand class" do
      expect(described_class.subcommand_classes["bench"]).to eq(QALain::Bench)
      expect(described_class.commands.keys).to include("usage", "friction", "verify")
    end

    %w[usage friction verify].each do |verb|
      it "prints #{verb}'s usage for `#{verb} --help`" do
        expect(help_for(verb)).to include("Usage:", verb)
      end
    end

    it "prints bench sweep's flags for `bench sweep --help`" do
      expect(help_for("bench", "sweep")).to include("Usage:", "--split")
    end

    it "refuses an unknown switch on `qa-lain bench variance`, naming it" do
      expect { described_class.start(%w[bench variance /tmp --nope], debug: true) }
        .to raise_error(Thor::UnknownArgumentError, /--nope/)
    end

    it "covers every Thor class bin/qa-lain defines with the unknown-switch refusal" do
      expect([described_class, QALain::Review, QALain::Survey, QALain::Bench].reject(&:check_unknown_options))
        .to eq([])
    end

    it "leaves no bench, verify, usage or friction verb on lain" do
      expect(LainCLI.commands.keys & %w[bench usage friction verify review survey]).to eq([])
    end

    it "names the judge-denials arms from Arms in approval-replay's help" do
      option = described_class::Bench.commands.fetch("approval_replay").options.fetch(:judge_denials)

      expect(option.banner).to eq(Lain::CLI::Arms::JUDGE_DENIALS.join("|"))
    end

    it "sends the default window of 24 hours when --window is omitted" do
      report = instance_double(Lain::Bench::CLI, variance_report: "report")
      allow(Lain::Bench::CLI).to receive(:new).and_return(report)
      expect { described_class.start(%w[bench variance /tmp], debug: true) }.to output("report\n").to_stdout
      expect(report).to have_received(:variance_report).with(["/tmp"], window_hours: 24)
    end

    it "hands `bench variance --window` to the report as hours" do
      report = instance_double(Lain::Bench::CLI, variance_report: "report")
      allow(Lain::Bench::CLI).to receive(:new).and_return(report)
      expect do
        described_class.start(%w[bench variance /tmp --window 720], debug: true)
      end.to output("report\n").to_stdout
      expect(report).to have_received(:variance_report).with(["/tmp"], window_hours: 720)
    end
  end

  # `--cheap-model` names a model, not a Lain::CLI::Backend field, so it reaches
  # `Bench::CLI#arms_report` the way `--system`/`--isolation`/`--journal` do:
  # read literally off `options`, never through the model flag band.
  describe "bench arms --cheap-model" do
    it "declares the flag and forwards it to arms_report literally" do
      entry = instance_double(Lain::Bench::CLI)
      calls = []
      allow(Lain::Bench::CLI).to receive(:new).and_return(entry)
      allow(entry).to receive(:arms_report) { |**kwargs|
        calls << kwargs
        "the report"
      }

      expect { described_class::Bench.start(%w[arms suite/tasks.yml --cheap-model qwen3:4b], debug: true) }
        .to output("the report\n").to_stdout

      expect(described_class::Bench.commands.fetch("arms").options).to have_key(:cheap_model)
      expect(calls.last).to include(cheap_model: "qwen3:4b")
    end
  end

  # The servability check, through the whole exe path with only the wire faked:
  # the server's own 404 for the model is the refusal, and it comes before a
  # single chat request.
  describe "bench arms --cheap-model a model the server has not got" do
    around { |example| Dir.mktmpdir("lain-arms-cheap") { |dir| (@dir = dir) && example.run } }

    it "refuses naming the model, and sends no chat request" do
      stub_request(:post, "http://localhost:11434/api/show")
        .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("error" => "model 'nonesuch:1b' not found"))
      chat = stub_request(:post, "http://localhost:11434/api/chat")
      allow(Lain::Arm::Driver).to receive(:new).and_raise("the arms ran, so the check came after the spend")
      fixture = File.expand_path("../fixtures/arms/tasks.yml", __dir__)
      argv = ["arms", fixture, "--provider", "ollama", "--model", "qwen3:4b", "--cheap-model", "nonesuch:1b",
              "--isolation", "worktree", "--journal", File.join(@dir, "arms.ndjson")]

      expect { with_env("LAIN_PROVIDER" => nil) { described_class::Bench.start(argv, debug: true) } }
        .to raise_error(Thor::Error, /nonesuch:1b/)
      expect(chat).not_to have_been_requested
    end
  end

  # The bench's backend is built with no board, so it binds the environment's
  # secrets itself. The model id stands in for a value the environment names
  # as a secret, because every request certainly carries it.
  describe "the bench's model backend" do
    it "refuses a request that carries a secret from the command's environment" do
      chat = stub_request(:post, "http://localhost:11434/api/chat")
      backend = described_class::Bench.new([], { provider: "ollama", model: "qwen3:4b" }).send(:model_backend)
      request = Lain::Request.new(model: "qwen3:4b", max_tokens: 64, stream: false,
                                  messages: [{ role: "user", content: "hi" }])

      expect { with_env("SPEC_SERVICE_TOKEN" => "qwen3:4b") { backend.provider.complete(request) } }
        .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused, /known secret/)
      expect(chat).not_to have_been_requested
    end
  end

  # One flag band for every command that asks a model, so a knob a chat honours
  # cannot be one another command silently drops.
  describe "the model flag band on the bench commands" do
    band = %i[provider api_base model max_tokens temperature seed num_batch num_ctx]

    %w[record arms].each do |name|
      it "declares the whole band on `qa-lain bench #{name}`, with no provider default to outrank the environment" do
        options = described_class::Bench.commands.fetch(name).options

        expect(options.keys.map(&:to_sym)).to include(*band)
        expect(Lain::CLI::RunProfile::FIELDS.map { |field| options.fetch(field).default }).to all(be_nil)
      end
    end

    # The Backend a bench command builds, captured at the one Bench::CLI call
    # it is handed to.
    def bench_backend(argv, method, env)
      entry = instance_double(Lain::Bench::CLI)
      seen = []
      allow(Lain::Bench::CLI).to receive(:new).and_return(entry)
      allow(entry).to receive(method) { |**kwargs| (seen << kwargs.fetch(:backend)) && ["done"] }
      expect { with_env(env) { described_class::Bench.start(argv, debug: true) } }.to output.to_stdout
      seen.fetch(0)
    end

    def encoded_options(backend)
      timeline = Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store).commit(role: :user,
                                                                                     content: [{
                                                                                       "type" => "text", "text" => "hi"
                                                                                     }])
      Lain::Provider::Ollama.new.encode(backend.context.render(timeline:, toolset: Lain::Toolset.new))[:options]
    end

    it "sends LAIN_NUM_BATCH on every ollama request `bench arms` encodes" do
      backend = bench_backend(%w[arms suite/tasks.yml --provider ollama], :arms_report,
                              "LAIN_NUM_BATCH" => "2048", "LAIN_PROVIDER" => nil)

      expect(encoded_options(backend).except(:num_predict)).to eq(num_batch: 2048)
    end

    it "sends LAIN_NUM_BATCH on every ollama request `bench record` encodes" do
      backend = bench_backend(%w[record task.txt --out runs --provider ollama], :record,
                              "LAIN_NUM_BATCH" => "2048", "LAIN_PROVIDER" => nil)

      expect(encoded_options(backend).except(:num_predict)).to eq(num_batch: 2048)
    end

    it "takes the provider from LAIN_PROVIDER when `bench arms` is given none" do
      backend = bench_backend(%w[arms suite/tasks.yml], :arms_report, "LAIN_PROVIDER" => "ollama")

      expect(backend.run_profile.provider).to eq("ollama")
    end

    # The generation cap shares the object and answers to no flag, so what a
    # flagless run proves is that no TYPED sampler knob was invented for it --
    # num_batch is the one exception, defaulting in regardless of a flag.
    it "sends only the num_batch default from a flagless ollama `bench arms`" do
      backend = bench_backend(%w[arms suite/tasks.yml --provider ollama], :arms_report,
                              "LAIN_NUM_BATCH" => nil, "LAIN_NUM_CTX" => nil)

      expect(encoded_options(backend)).to eq(num_predict: 4096, num_batch: 2048)
    end
  end
end
