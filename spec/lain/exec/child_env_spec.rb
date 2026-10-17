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

  describe "a parent's environment" do
    it "withholds every secret-shaped name from a child handed the parent's own environment" do
      expect(child_of(parent).keys).not_to include("OLLAMA_API_KEY", "SSH_AUTH_SOCK", "GITHUB_TOKEN")
    end

    it "withholds a name it does not keep, by an explicit nil the spawn deletes" do
      expect(child_env.call(parent)).to include("EDITOR" => nil, "GITHUB_TOKEN" => nil)
    end

    it "withholds a secret the caller omitted, which would otherwise be inherited" do
      expect(child_env.call({})).to include("OLLAMA_API_KEY" => nil, "SSH_AUTH_SOCK" => nil, "GITHUB_TOKEN" => nil)
    end

    it "keeps the toolchain, each with its value" do
      toolchain = { "PATH" => "/usr/bin", "HOME" => "/home/u", "LANG" => "C.UTF-8", "TERM" => "xterm",
                    "TMPDIR" => "/home/u/tmp", "LD_LIBRARY_PATH" => "/opt/lib", "GEM_HOME" => "/home/u/gems",
                    "MISE_SHELL" => "zsh", "MISE_DATA_DIR" => "/home/u/.mise", "CARGO_HOME" => "/home/u/.cargo" }
      kept = described_class.new(env: toolchain)

      expect(kept.call(toolchain)).to eq(toolchain)
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
