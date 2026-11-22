# frozen_string_literal: true

require "open3"
require "rbconfig"

# The one rule every exec backend asks for a child's environment. Driven with an
# injected environment, so each example states the whole parent it reasons about.
RSpec.describe Lain::Exec::ChildEnv do
  subject(:child_env) { described_class.new(env: parent) }

  let(:parent) do
    { "PATH" => "/usr/bin", "HOME" => "/home/u", "OLLAMA_API_KEY" => "sk-o", "SSH_AUTH_SOCK" => "/run/agent",
      "GITHUB_TOKEN" => "ghp_x", "EDITOR" => "vim" }
  end

  def child_of(lent) = child_env.call(lent).compact

  describe "#received" do
    it "is what a child handed that env holds: the kept, the passed and the lent, never a scrubbed loader" do
      process = { "PATH" => "/usr/bin", "LD_LIBRARY_PATH" => "/opt/lib", "RUBYOPT" => "-W0", "EDITOR" => "vi",
                  "TOOL_DIR" => "/opt/t" }

      received = described_class.new(env: process, pass: %w[TOOL_DIR]).received(process.merge("ADDED" => "1"))

      expect(received).to eq("PATH" => "/usr/bin", "TOOL_DIR" => "/opt/t", "ADDED" => "1")
    end
  end

  describe "#received_unlent" do
    it "is what the child holds beside what lain lends it" do
      source = Struct.new(:environment).new({ "GH_TOKEN" => "gho_example" })
      lending = described_class.new(env: { "PATH" => "/usr/bin" }, lend: described_class::Lend.new(source))

      expect(lending.received_unlent({ "PATH" => "/usr/bin" })).to eq("PATH" => "/usr/bin")
    end
  end

  describe "#environment" do
    it "is the live parent environment" do
      live = { "PATH" => "/usr/bin" }
      env = described_class.new(env: live)
      live["EDITOR"] = "vim"

      expect(env.environment).to eq("PATH" => "/usr/bin", "EDITOR" => "vim")
    end
  end

  describe "a parent's environment" do
    it "withholds every secret-shaped name from a child handed the parent's own environment" do
      expect(child_of(parent).keys).not_to include("OLLAMA_API_KEY", "SSH_AUTH_SOCK", "GITHUB_TOKEN")
    end

    it "withholds a name it does not keep, by an explicit nil the spawn deletes" do
      expect(child_env.call(parent)).to include("EDITOR" => nil, "GITHUB_TOKEN" => nil)
    end

    it "withholds herdr's pane variables, so a bash child cannot report into lain's pane" do
      herdr = { "HERDR_ENV" => "1", "HERDR_PANE_ID" => "w1:p7", "HERDR_BIN_PATH" => "/opt/herdr",
                "HERDR_SOCKET_PATH" => "/run/herdr.sock" }

      expect(described_class.new(env: parent.merge(herdr)).call(parent.merge(herdr)).compact.keys.grep(/\AHERDR_/))
        .to be_empty
    end

    it "withholds a secret the caller omitted, which would otherwise be inherited" do
      expect(child_env.call({})).to include("OLLAMA_API_KEY" => nil, "SSH_AUTH_SOCK" => nil, "GITHUB_TOKEN" => nil)
    end

    it "keeps the toolchain, each with its value" do
      toolchain = { "PATH" => "/usr/bin", "HOME" => "/home/u", "LANG" => "C.UTF-8", "TERM" => "xterm",
                    "TMPDIR" => "/home/u/tmp", "GEM_HOME" => "/home/u/gems",
                    "MISE_SHELL" => "zsh", "MISE_DATA_DIR" => "/home/u/.mise", "CARGO_HOME" => "/home/u/.cargo" }
      kept = described_class.new(env: toolchain)

      expect(kept.call(toolchain)).to eq(toolchain)
    end

    it "withholds LD_LIBRARY_PATH unless it is passed by name" do
      env = { "LD_LIBRARY_PATH" => "/opt/lib" }

      expect(described_class.new(env:).call(env)).to eq("LD_LIBRARY_PATH" => nil)
      expect(described_class.new(pass: %w[LD_LIBRARY_PATH], env:).call(env)).to eq(env)
    end

    it "keeps the isolated git config the specs set" do
      git = { "GIT_CONFIG_GLOBAL" => "/tmp/gitconfig", "GIT_CONFIG_NOSYSTEM" => "1" }

      expect(described_class.new(env: git).call(git)).to eq(git)
    end

    it "keeps a container client's daemon connection" do
      connection = { "DOCKER_HOST" => "ssh://box", "DOCKER_CONTEXT" => "remote", "DOCKER_CONFIG" => "/home/u/.docker",
                     "DOCKER_CERT_PATH" => "/certs", "DOCKER_TLS_VERIFY" => "1",
                     "CONTAINER_HOST" => "unix:///run/podman.sock", "CONTAINER_CONNECTION" => "box" }

      expect(described_class.new(env: connection).call({})).to be_empty
    end

    it "withholds a secret-shaped name even where the kept namespace covers it" do
      parent = { "LAIN_SPEC_TOKEN" => "t", "MISE_GITHUB_TOKEN" => "m" }

      expect(described_class.new(env: parent).call(parent)).to eq("LAIN_SPEC_TOKEN" => nil, "MISE_GITHUB_TOKEN" => nil)
    end
  end

  describe "what the caller lent" do
    it "passes a variable the parent lacks" do
      expect(child_of(parent.merge("DATABASE_URL" => "postgres://db"))).to include("DATABASE_URL" => "postgres://db")
    end

    it "passes a changed value of a variable the parent holds" do
      expect(child_of(parent.merge("EDITOR" => "nano"))).to include("EDITOR" => "nano")
    end

    it "passes a secret-shaped name the parent lacks, because it was lent on purpose" do
      expect(child_of(parent.merge("LAIN_LENT_TOKEN" => "lent"))).to include("LAIN_LENT_TOKEN" => "lent")
    end

    it "keeps an explicit nil as the removal it asks for" do
      expect(child_env.call(parent.merge("PATH" => nil))).to include("PATH" => nil)
    end
  end

  describe "what a lend adds to every child" do
    let(:told) { [] }

    # Answers `environment` the way an account does, counting each ask.
    def source(answer = { "GH_TOKEN" => "lent-token-value" })
      Class.new do
        attr_reader :asks

        define_method(:initialize) { @asks = 0 }
        define_method(:environment) { (@asks += 1) && (answer.is_a?(Exception) ? raise(answer) : answer) }
      end.new
    end

    def lending(from, env: parent)
      described_class.new(env:, lend: described_class::Lend.new(from, notice: told.method(:<<)))
    end

    it "hands each child the lent value, asking the source once" do
      from = source
      env = lending(from)

      2.times { expect(env.call(parent)).to include("GH_TOKEN" => "lent-token-value") }
      expect(from.asks).to eq(1)
    end

    it "hands a lent value the parent also holds, which the allowlist alone would withhold" do
      exported = parent.merge("GH_TOKEN" => "exported-token")

      expect(lending(source("GH_TOKEN" => "exported-token"), env: exported).call(exported))
        .to include("GH_TOKEN" => "exported-token")
    end

    it "asks nothing until a child is built, so #environment and construction stay quiet" do
      from = source
      env = lending(from)

      expect(env.environment).not_to have_key("GH_TOKEN")
      expect(from.asks).to eq(0)
    end

    it "names a resolved lent value in #environment, so masking and egress learn it" do
      env = lending(source)
      env.call({})

      expect(env.environment).to include("GH_TOKEN" => "lent-token-value")
    end

    it "degrades a refused lend to no value and 1 notice, asking again on each child" do
      from = source(Lain::Error.new("gh has no token for nobody; run `gh auth login`"))
      env = lending(from, env: parent.merge("GH_TOKEN" => "exported-token"))

      2.times { expect(env.call({})).to include("GH_TOKEN" => nil) }
      expect([told, from.asks]).to eq([["gh has no token for nobody; run `gh auth login`"], 2])
      expect(env.environment).to include("GH_TOKEN" => "exported-token")
    end

    it "lends the value once a source that refused answers, and remembers it from then on" do
      answers = [Lain::Error.new("run `gh auth login`"), { "GH_TOKEN" => "lent-token-value" }]
      from = Class.new do
        define_method(:environment) { answers.first.is_a?(Exception) ? raise(answers.shift) : answers.first }
      end.new
      env = lending(from)

      expect(Array.new(3) { env.call({})["GH_TOKEN"] }).to eq([nil, "lent-token-value", "lent-token-value"])
      expect(told.size).to eq(1)
    end

    it "answers a child env free of the lend, which neither asks the source nor carries what it lent" do
      from = source
      env = lending(from)
      env.call({})
      own = env.unlent

      expect([own.environment.key?("GH_TOKEN"), own.call({}).key?("GH_TOKEN"), from.asks]).to eq([false, false, 1])
    end

    it "lends nothing by default, so an exported token is withheld" do
      exported = parent.merge("GH_TOKEN" => "exported-token")

      expect(described_class.new(env: exported).call(exported)).to include("GH_TOKEN" => nil)
    end
  end

  describe "names the human passes" do
    let(:parent) { { "RAILS_ENV" => "test", "JAVA_HOME" => "/opt/jdk", "EDITOR" => "vim" } }

    it "passes each named variable from the parent" do
      passing = described_class.new(pass: %w[RAILS_ENV JAVA_HOME], env: parent)

      expect(passing.call(parent)).to eq("RAILS_ENV" => "test", "JAVA_HOME" => "/opt/jdk", "EDITOR" => nil)
    end

    it "reads them from LAIN_ENV_PASS" do
      env = parent.merge("LAIN_ENV_PASS" => "RAILS_ENV,JAVA_HOME")

      passed = described_class.from(env).call(env).compact.keys

      expect(passed).to contain_exactly("RAILS_ENV", "JAVA_HOME", "LAIN_ENV_PASS")
    end

    it "ignores an empty entry in LAIN_ENV_PASS" do
      env = parent.merge("LAIN_ENV_PASS" => "RAILS_ENV,,JAVA_HOME")

      expect(described_class.from(env).passes?("")).to be(false)
    end

    it "joins the names a project passes to the ones LAIN_ENV_PASS lists" do
      env = parent.merge("LAIN_ENV_PASS" => "JAVA_HOME")

      passed = described_class.from(env, pass: %w[RAILS_ENV]).call(env).compact.keys

      expect(passed).to contain_exactly("RAILS_ENV", "JAVA_HOME", "LAIN_ENV_PASS")
    end

    it "says whether a name is one it passes" do
      passing = described_class.new(pass: %w[RAILS_ENV], env: parent)

      expect(%w[RAILS_ENV EDITOR].map { |name| passing.passes?(name) }).to eq([true, false])
    end

    it "refuses a secret-shaped name at construction, naming it and the remedy" do
      expect { described_class.new(pass: %w[RAILS_ENV GITHUB_TOKEN], env: parent) }
        .to raise_error(described_class::Refused, /GITHUB_TOKEN.*remove/)
    end

    it "refuses a secret-shaped name whatever its case" do
      expect { described_class.new(pass: %w[github_token], env: parent) }.to raise_error(described_class::Refused)
    end
  end

  describe "the scrubs that hold whether lent or not" do
    let(:scrubbed) do
      { "BUNDLE_GEMFILE" => "/lain/Gemfile", "RUBYOPT" => "-rbundler/setup", "CDPATH" => "/elsewhere",
        "LD_PRELOAD" => "/x.so", "LD_AUDIT" => "/a.so", "BASH_FUNC_x%%" => "() { :; }" }
    end

    it "deletes each one inherited from the parent" do
      expect(described_class.new(env: scrubbed).call({})).to eq(scrubbed.transform_values { nil })
    end

    it "deletes each one the caller lent" do
      expect(described_class.new(env: {}).call(scrubbed)).to eq(scrubbed.transform_values { nil })
    end

    it "deletes one the human named in the pass list" do
      passing = described_class.new(pass: %w[RUBYOPT], env: scrubbed)

      expect(passing.call(scrubbed)).to include("RUBYOPT" => nil)
    end
  end

  # A fresh boot, because the default is built from the environment lain
  # starts under and a spec process has long since started.
  describe "the default a fresh boot builds", :seam do
    def boot(script, env)
      Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", script)
    end

    it "passes the names LAIN_ENV_PASS lists to a child" do
      script = 'require "lain"; print Lain::Exec::Local.new.call(command: "printenv RAILS_ENV", ' \
               "cwd: Dir.pwd, env: ENV.to_h, timeout: 10).stdout"

      stdout, stderr, = boot(script, "RAILS_ENV" => "staging", "LAIN_ENV_PASS" => "RAILS_ENV")

      expect([stdout, stderr]).to eq(["staging\n", ""])
    end

    it "refuses a secret-shaped pass at lain's launch in one line, before any command" do
      exe = File.expand_path("../../../exe/lain", __dir__)

      _stdout, stderr, status = Open3.capture3({ "LAIN_ENV_PASS" => "GITHUB_TOKEN" }, RbConfig.ruby, exe, "--help")

      expect(status.exitstatus).to eq(1)
      expect(stderr.lines.size).to eq(1)
      expect(stderr).to include("GITHUB_TOKEN", "LAIN_ENV_PASS")
    end
  end

  it "is what Exec.child_env answers with for the live process" do
    with_env("LAIN_SPEC_CHILD_ENV_TOKEN" => "sk-live") do
      expect(Lain::Exec.child_env(ENV.to_h)).to include("LAIN_SPEC_CHILD_ENV_TOKEN" => nil)
    end
  end
end
