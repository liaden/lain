# frozen_string_literal: true

RSpec.describe Lain::Frontend::TTY::Notifier do
  let(:output) { StringIO.new }
  let(:fed) { [] }
  let(:feed) { ->(*args) { fed << args } }
  let(:displayed) { [] }
  let(:tmux) { ->(note) { displayed << note } }

  def notifier(env, project: "lain-demo", **rest)
    described_class.for(env:, feed:, tmux:, output:, project:, **rest)
  end

  it "writes OSC 9 for iTerm, then hands the note to tmux and the feed" do
    notifier({ "TERM_PROGRAM" => "iTerm.app" }).call("ask settled")

    expect(output.string).to eq("\e]9;ask settled\a")
    expect(displayed).to eq(["ask settled"])
    expect(fed).to eq([["lain", "lain-demo", "ask settled"]])
  end

  it "writes OSC 99 for kitty" do
    notifier({ "KITTY_WINDOW_ID" => "3" }).call("ask settled")

    expect(output.string).to eq("\e]99;;ask settled\e\\")
  end

  it "writes OSC 777 with the project as its title otherwise" do
    notifier({}).call("ask settled")

    expect(output.string).to eq("\e]777;notify;lain-demo;ask settled\a")
  end

  it "wraps the sequence in the tmux passthrough envelope and still runs tmux" do
    notifier({ "TMUX" => "/tmp/tmux-1/default,1,0", "KITTY_WINDOW_ID" => "3" }).call("ask settled")

    expect(output.string).to eq("\ePtmux;\e\e]99;;ask settled\e\e\\\e\\")
    expect(displayed).to eq(["ask settled"])
  end

  it "strips control bytes and semicolons a note could use to end the sequence early" do
    notifier({}).call("a;b\e]0;x\a\n")

    expect(output.string).to eq("\e]777;notify;lain-demo;a b ]0 x  \a")
  end

  it "titles the feed entry lain when no project is named" do
    described_class.for(env: {}, feed:, tmux:, output:).call("hi")

    expect(fed).to eq([%w[lain lain hi]])
  end

  it "never raises when the output, tmux or feed fails" do
    boom = ->(*) { raise "boom" }
    broken = Object.new.tap { |o| o.define_singleton_method(:print) { |*| raise IOError } }

    expect { described_class.for(env: {}, feed: boom, tmux: boom, output: broken).call("x") }.not_to raise_error
  end

  it "still reaches the feed when tmux fails" do
    described_class.for(env: {}, feed:, tmux: ->(_) { raise "boom" }, output:).call("x")

    expect(fed.size).to eq(1)
  end

  it "masks the note before the sequence, tmux and the feed see it" do
    notifier({}, mask: ->(text) { text.gsub("hunter2", "[masked]") }).call("pw hunter2 leaked")

    expect([output.string, displayed, fed.flatten]).to all(satisfy { |seen| !seen.to_s.include?("hunter2") })
    expect(fed.sole.last).to eq("pw [masked] leaked")
  end

  it "caps the text at the tmux message limit for the sequence and the feed" do
    notifier({}).call("x" * 1000)

    expect(output.string).to include("x" * Lain::Frontend::TTY::TmuxMessage::LIMIT)
    expect(output.string).not_to include("x" * (Lain::Frontend::TTY::TmuxMessage::LIMIT + 1))
    expect(fed.sole.last.size).to eq(Lain::Frontend::TTY::TmuxMessage::LIMIT)
  end

  it "strips control bytes from what the feed is given, title and body alike" do
    notifier({}, project: "a\e[2Jb").call("line\none\e]0;x\a")

    expect(fed).to eq([["lain", "a [2Jb", "line one ]0;x "]])
  end

  it "writes to the output it is rebound to and to no other" do
    other = StringIO.new

    notifier({}).bound_to(other).call("hi")

    expect([output.string, other.string]).to eq(["", "\e]777;notify;lain-demo;hi\a"])
  end

  describe "deferred" do
    it "shows the tmux message at once and writes no sequence and no feed entry" do
      notifier({}, deferred: true).call("ask settled")

      expect([output.string, displayed, fed]).to eq(["", ["ask settled"], []])
    end

    it "sends the sequence and the feed entry, and no tmux message, when asked to notify" do
      notifier({}, deferred: true).notify("blocked: bash")

      expect([output.string, displayed, fed]).to eq(["\e]777;notify;lain-demo;blocked: bash\a", [],
                                                     [["lain", "lain-demo", "blocked: bash"]]])
    end

    it "notifies through the output the terminal rebound it to" do
      other = StringIO.new
      original = notifier({}, deferred: true)
      original.bound_to(other)
      original.notify("hi")

      expect([output.string, other.string]).to eq(["", "\e]777;notify;lain-demo;hi\a"])
    end

    it "never raises when the output or the feed fails" do
      boom = ->(*) { raise "boom" }

      expect { described_class.for(env: {}, feed: boom, output: nil, deferred: true).notify("x") }.not_to raise_error
    end
  end

  describe ".for_chat" do
    it "defers the sequence and the feed entry when asked" do
      allow(Lain::Notices).to receive(:for).with(env: {}, notes: anything).and_return(feed)
      described_class.for_chat([], "/work/demo", env: {}, output:, deferred: true, notes: Lain::Sink::Null.new).call("hi")

      expect([output.string, fed]).to eq(["", []])
    end

    it "masks with the secrets the thunk answers at each note, and feeds the project's notify-feed" do
      allow(Lain::Notices).to receive(:for).with(env: {}, notes: anything).and_return(feed)
      secrets = ["alpha-secret-1"]
      session = described_class.for_chat(secrets, "/work/demo", env: {}, output:, notes: Lain::Sink::Null.new)

      session.call("a alpha-secret-1 bravo-secret-2")
      secrets << "bravo-secret-2"
      session.call("a alpha-secret-1 bravo-secret-2")

      expect(fed.map(&:last)).to eq(["a <redacted:1> bravo-secret-2", "a <redacted:1> <redacted:2>"])
      expect(fed.map { |args| args[1] }).to all(eq("demo"))
    end
  end
end
