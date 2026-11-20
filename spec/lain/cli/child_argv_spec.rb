# frozen_string_literal: true

RSpec.describe Lain::CLI::ChildArgv do
  def build(root: "/proj", cwd: "/proj/app", path: "/sessions/a.ndjson", typed: {}, mode: Lain::Mode.new)
    described_class.new(root:, cwd:, journal_path: -> { path }, typed:, mode: -> { mode })
  end

  describe "#chat" do
    it "pins the live run's root and cwd, so a child started from another directory finds the same project" do
      expect(build.chat("--fork", "a.ndjson@abc"))
        .to eq(%w[chat --root /proj --cwd /proj/app --approval ask --fork a.ndjson@abc])
    end

    it "carries the model flags the human typed, spelled as the flag" do
      argv = build(typed: { provider: "ollama", api_base: "http://h:1", num_ctx: 8192 }).chat

      expect(argv).to eq(%w[chat --root /proj --cwd /proj/app --provider ollama --api-base http://h:1 --num-ctx 8192
                            --approval ask])
    end

    it "keeps the extra words the caller adds, even a --fork or --prompt of its own" do
      argv = build(root: nil, cwd: nil).chat("--btw", "--fork", "s@d", "--prompt", "why")

      expect(argv).to eq(%w[chat --approval ask --btw --fork s@d --prompt why])
    end

    it "starts the child at the approval the run holds now, not the one it launched with" do
      mode = Lain::Mode.new(approval: :auto)
      argv = described_class.new(root: nil, cwd: nil, journal_path: -> {}, typed: {}, mode: -> { mode })

      mode = Lain::Mode.new(approval: :bypass)

      expect(argv.chat).to eq(%w[chat --approval bypass])
    end

    it "has no chat_flags parameter" do
      expect(described_class.instance_method(:initialize).parameters.map(&:last)).not_to include(:chat_flags)
    end

    it "names no root or cwd that the run did not resolve" do
      expect(build(root: nil, cwd: nil).chat).to eq(%w[chat --approval ask])
    end
  end

  describe "#watch" do
    it "names this chat's session file" do
      expect(build.watch).to eq(%w[watch --session /sessions/a.ndjson])
    end

    it "reads the path when asked, so a promoted session is the one a later window watches" do
      path = "/sessions/1-9.btw.ndjson"
      argv = described_class.new(root: nil, cwd: nil, journal_path: -> { path }, typed: {}, mode: -> { Lain::Mode.new })

      path = "/sessions/1-9.ndjson"

      expect(argv.watch).to eq(%w[watch --session /sessions/1-9.ndjson])
    end

    it "names no session for a run with no journal" do
      expect(build(path: nil).watch).to eq(%w[watch])
    end
  end

  describe "#printable" do
    it "is one line a shell reads back as the same words" do
      line = described_class.printable(build.chat("--prompt", %(why `rm` "x" $HOME?)))

      expect(line).to start_with("lain chat --root /proj")
      expect(line.delete_prefix("lain ").shellsplit).to eq(build.chat("--prompt", %(why `rm` "x" $HOME?)))
    end
  end

  describe "an api base that carries credentials" do
    let(:typed) { { api_base: "http://user:fake-pass@h:11434" } }

    it "reaches the child's argv as typed, the same exposure as the parent's own" do
      expect(build(typed:).chat).to include("--api-base", "http://user:fake-pass@h:11434")
    end

    it "is masked in every line shown to the human" do
      line = described_class.printable(build(typed:).chat("--fork", "x"))

      expect(line).to include("--api-base http://***@h:11434")
      expect(line).not_to include("fake-pass")
    end

    it "leaves a URL whose path merely holds an at sign as it was" do
      argv = %w[chat --api-base http://h:11434/a@b --prompt https://example.com/x@y]

      expect(described_class.printable(argv)).to eq("lain chat --api-base http://h:11434/a@b --prompt https://example.com/x@y")
    end
  end

  describe ".fresh" do
    it "is what a restart keeps of the typed chat flags" do
      expect(described_class.fresh(%w[--resume x --prompt hi --model m])).to eq(%w[--model m])
    end

    it "drops only the named flags when asked" do
      expect(described_class.fresh(%w[--resume x --prompt hi], drop: %w[--resume])).to eq(%w[--prompt hi])
    end
  end
end
