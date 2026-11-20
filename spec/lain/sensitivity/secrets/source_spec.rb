# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Secrets::Source do
  let(:history) do
    split = Lain::Sensitivity::HistoryLiterals::Split.new(known: %w[history-ordinary-value history-secret-value],
                                                          refusable: %w[history-secret-value])
    Class.new do
      define_method(:split) { split }
      define_method(:to_a) { split.known }
    end.new
  end
  let(:paths) do
    { "SSH_AUTH_SOCK" => "/run/user/1000/ssh-agent.socket",
      "PASSWORD_STORE_DIR" => "/home/probe/.password-store",
      "GOOGLE_APPLICATION_CREDENTIALS" => "/home/probe/.config/gcloud/application_default_credentials.json",
      "PASSWORD_STORE_KEY_DIR" => "~/.local/share/password-store",
      "GPG_AUTH_SOCK" => "/run/user/1000/gnupg/S.gpg-agent.ssh",
      "PASSWORD_STORE_HOME" => "~/.password-store" }
  end
  let(:aws) { %w[/k3J9xQ2mZ7pL4vR8n T1wY6bH0cF5gD2eA9sU3iO].join }
  let(:tilde_token) { "~/fakeTok3nZq8xV2nL4tR7yW1kP9mB3cJ6" }
  let(:env) do
    { "DB_PASSWORD" => "spec-db-password-24bytes", "API_TOKEN" => tilde_token, "AWS_SECRET_ACCESS_KEY" => aws,
      "SHORT_TOKEN" => "short", **paths }
  end

  def source_over(env) = described_class.new(child_env: Lain::Exec::ChildEnv.from(env), history:)

  it "lists every value the masker knows, the environment's and the history's" do
    expect(source_over(env).to_a).to include("spec-db-password-24bytes", "/run/user/1000/ssh-agent.socket",
                                             "history-ordinary-value", "history-secret-value")
  end

  describe "#for" do
    it "adds the calling worker's own environment to what the source knows" do
      worker_env = Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LENT_TOKEN" => "worker-lent-value-9" })
      context = Struct.new(:worker_env).new(worker_env)

      expect(source_over({}).for(context)).to include("worker-lent-value-9", "history-secret-value")
    end

    it "reads as to_a for no context" do
      expect(source_over(env).for(nil)).to eq(source_over(env).to_a)
    end
  end

  describe "#for_reads" do
    let(:history) do
      split = Lain::Sensitivity::HistoryLiterals::Split.new(known: %w[history-ordinary-value history-secret-value],
                                                            refusable: %w[history-secret-value])
      Class.new do
        define_method(:split) { split }
        define_method(:to_a) { split.known }
        define_method(:refusable) { split.refusable }
      end.new
    end

    it "lists the environment's values, the worker's lent ones and the refusable history, not ordinary config" do
      worker_env = Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LENT_TOKEN" => "worker-lent-value-9" })
      context = Struct.new(:worker_env).new(worker_env)

      expect(source_over(env).for_reads(context))
        .to include("spec-db-password-24bytes", "worker-lent-value-9", "history-secret-value")
        .and(not_include("history-ordinary-value"))
    end

    it "leaves out a path or a number only where the variable's name is not secret" do
      values = { "SSH_AUTH_SOCK" => "/run/user/1000/ssh-agent.socket", "DB_PASSWORD" => "48213907",
                 "SECRET_PATH_TOKEN" => "/var/lib/app/tok3n-x9q" }

      expect(source_over(values).for_reads(nil))
        .to include("48213907", "/var/lib/app/tok3n-x9q").and(not_include("/run/user/1000/ssh-agent.socket"))
    end

    describe "a number a plain-named variable shares with another source" do
      let(:digits) { "48213907" }

      def reads(env, pass: [], over: history)
        described_class.new(child_env: Lain::Exec::ChildEnv.new(env:, pass:), history: over).for_reads(nil)
      end

      it "keeps the password a passed connection string holds" do
        expect(reads({ "DATABASE_URL" => "postgres://app:#{digits}@db.internal/app", "BUILD_NUMBER" => digits },
                     pass: %w[DATABASE_URL])).to include(digits)
      end

      it "keeps a value a secret-named variable also holds" do
        expect(reads({ "DB_PASSWORD" => digits, "BUILD_NUMBER" => digits })).to include(digits)
      end

      it "keeps a value the history refuses" do
        refusing = Class.new do
          define_method(:refusable) { ["48213907"] }
          define_method(:to_a) { ["48213907"] }
        end.new

        expect(reads({ "BUILD_NUMBER" => digits }, over: refusing)).to include(digits)
      end

      it "drops it where only a plain-named variable lists it" do
        expect(reads({ "BUILD_NUMBER" => digits, "SSH_AUTH_SOCK" => "/run/user/1000/agent.sock" }))
          .not_to include(digits, "/run/user/1000/agent.sock")
      end
    end

    it "also seeks a multi-line value spelled with CRLF line ends" do
      value = "first-line-secret-aa\nsecond-line-secret-bb"

      expect(source_over("APP_SECRET" => value).for_reads(nil))
        .to include(value, "first-line-secret-aa\r\nsecond-line-secret-bb")
    end

    it "also seeks a CRLF-stored value spelled with LF line ends" do
      value = "first-line-secret-aa\r\nsecond-line-secret-bb"

      expect(source_over("APP_SECRET" => value).for_reads(nil))
        .to include(value, "first-line-secret-aa\nsecond-line-secret-bb")
    end

    it "reads the null session's worker for no context" do
      expect(source_over(env).for_reads(nil)).to eq(source_over(env).for_reads(Lain::Session::Null.instance))
    end
  end

  describe "DEFAULT" do
    it "is the process child environment over no history" do
      expect(described_class::DEFAULT).to have_attributes(child_env: Lain::Exec::ChildEnv::DEFAULT,
                                                          history: Lain::Sensitivity::HistoryLiterals::Null)
    end

    it "is shareable" do
      expect(Ractor.shareable?(described_class::DEFAULT)).to be(true)
    end
  end

  describe "#egress" do
    subject(:egress) { source_over(env).egress }

    it "refuses a secret-named value and a refusable history value" do
      expect(egress.refused).to include("spec-db-password-24bytes", "history-secret-value")
    end

    it "refuses a secret shaped like a path: an absolute one the detector finds, and a ~/ token" do
      expect(egress.refused).to include(aws, tilde_token)
    end

    # Each arm of the path rule alone: a path the detector finds a credential
    # in, and one random enough to be a key.
    it "refuses a path-shaped value that holds a detected credential or is high-entropy" do
      egress = source_over("AGENT_TOKEN" => "/run/user/1000/#{%w[AKIA Z7Q3VKXW4NP2RT5M].join}",
                           "AWS_SECRET_KEY" => %w[/wJalrXUtnFEMI/ K7MDENG/bPxRfiCYEXAMPLEKEY].join).egress

      expect(egress.refused).to include("/run/user/1000/#{%w[AKIA Z7Q3VKXW4NP2RT5M].join}",
                                        %w[/wJalrXUtnFEMI/ K7MDENG/bPxRfiCYEXAMPLEKEY].join)
    end

    it "only flags a path under a secret-shaped name, ~/ included, and ordinary history" do
      expect(egress.flagged).to include(*paths.values, "history-ordinary-value")
      expect(egress.refused).not_to include(*paths.values, "history-ordinary-value")
    end

    it "keeps nothing under the floor" do
      expect(egress.refused + egress.flagged).not_to include("short")
    end

    it "answers frozen, deeply" do
      expect(Ractor.shareable?(egress)).to be(true)
    end

    it "reads the history once" do
      allow(history).to receive(:split).and_call_original
      allow(history).to receive(:to_a).and_call_original

      source_over(env).egress

      expect(history).to have_received(:split).once
      expect(history).not_to have_received(:to_a)
    end
  end

  describe "#egress over a passed variable" do
    let(:password) { "fakeS3cretPassw0rdXyZ" }

    it "refuses the password the detector finds in a passed connection string" do
      egress = source_over("DATABASE_URL" => "postgres://app:#{password}@db.internal:5432/app",
                           "LAIN_ENV_PASS" => "DATABASE_URL").egress

      expect(egress.refused).to include(password)
    end

    it "only flags a hinted token the detector does not shape" do
      url = "https://my-bucket-Name2024x.s3.amazonaws.com"
      egress = source_over("S3_BUCKET_URL" => url, "LAIN_ENV_PASS" => "S3_BUCKET_URL").egress

      expect(egress.flagged).to include("my-bucket-Name2024x")
      expect(egress.refused).not_to include("my-bucket-Name2024x")
    end
  end
end
