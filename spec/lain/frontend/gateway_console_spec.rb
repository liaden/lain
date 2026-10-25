# frozen_string_literal: true

require "pty"
require "stringio"

RSpec.describe Lain::Frontend::GatewayConsole do
  let(:output) { StringIO.new }
  let(:body) { '{"model":"m","stream":false,"messages":[]}' }

  def request(text = body, flagged: [])
    Lain::Gateway::Server::Request.new(endpoint: "/api/chat", bytes: text.bytesize, body: text, flagged:)
  end

  def console(answer) = described_class.new(input: StringIO.new(answer), output:)

  it "shows the endpoint, the byte count and the exact body before asking" do
    console("y\n").approve?(request)

    expect(output.string).to include("POST /api/chat", "#{body.bytesize} bytes", body, "[y/N]")
  end

  { "y\n" => true, "yes\n" => true, "Y\n" => true, "n\n" => false, "\n" => false,
    "yy\n" => false }.each do |typed, approved|
    it "answers #{approved} to #{typed.inspect}" do
      expect(console(typed).approve?(request)).to be(approved)
    end
  end

  it "repeats the endpoint and the byte count on the question line" do
    console("n\n").approve?(request)

    expect(output.string.lines.last).to eq("Forward POST /api/chat, #{body.bytesize} bytes? [y/N] ")
  end

  it "collapses a run of whitespace between tokens into a counted marker" do
    padded = %({"model":"m","stream":false,"messages":[{"role":"user","content":"payload"}]#{"\n" * 400}})

    console("n\n").approve?(request(padded))

    expect(output.string).to include("[400 newlines]")
    expect(output.string).not_to include("\n\n\n")
  end

  it "counts a long mixed run and leaves a single space alone" do
    console("n\n").approve?(request(%({"a": "b", "c":#{" \t" * 10}"d"})))

    expect(output.string).to include('{"a": "b", "c":[20 blank characters]"d"}')
  end

  it "raises at the end of input rather than reading it as a no" do
    expect { console("").approve?(request) }.to raise_error(described_class::Unanswered)
  end

  it "keeps a pretty-printed body as it is" do
    pretty = JSON.pretty_generate({ model: "m", stream: false, messages: [{ role: "user", content: "hi" }] })

    console("n\n").approve?(request(pretty))

    expect(output.string).to include(pretty)
  end

  it "counts a stack of blank lines however short" do
    console("n\n").approve?(request(%({"a":\n\n"b"})))

    expect(output.string).to include('{"a":[2 newlines]"b"}')
  end

  { "spaces" => " ", "no-break spaces" => "\u00A0", "braille blanks" => "\u2800", "hangul fillers" => "\u3164",
    "hangul choseong fillers" => "\u115F", "hangul jungseong fillers" => "\u1160",
    "halfwidth hangul fillers" => "\uFFA0", "ideographic spaces" => "\u3000" }.each do |name, blank|
    it "counts a long run of #{name} inside a string" do
      console("n\n").approve?(request(%({"content":"EXFIL#{blank * 20_000}ok"})))

      expect(output.string).to include("EXFIL[20000 blank characters]ok")
    end
  end

  it "keeps whitespace inside a string as it is" do
    console("n\n").approve?(request('{"a":"x   y"}'))

    expect(output.string).to include('{"a":"x   y"}')
  end

  it "keeps the payload and the question on one screen of a real terminal" do
    padded = %({"model":"m","stream":false,"content":"leaked-payload"#{"\n" * 400}})
    PTY.open do |screen, terminal|
      described_class.new(input: StringIO.new("n\n"), output: terminal).approve?(request(padded))
      shown = screen.read_nonblock(1 << 20)

      expect(shown.lines.size).to be < 24
      expect(shown).to include("leaked-payload", "Forward POST /api/chat, #{padded.bytesize} bytes?")
    end
  end

  it "discards a line typed before the question, so it cannot answer it" do
    PTY.open do |keyboard, terminal|
      keyboard.write("y\n")
      sleep 0.1
      asked = Thread.new { described_class.new(input: terminal, output:).approve?(request) }
      wait_until(reason: "the question") { output.string.include?("[y/N]") }
      keyboard.write("n\n")

      expect(asked.value).to be(false)
    end
  end

  it "flushes the question, which has no newline to flush it" do
    flushed = Class.new(StringIO) do
      attr_reader :seen

      def flush = (@seen = string.dup)
    end.new

    described_class.new(input: StringIO.new("n\n"), output: flushed).approve?(request)

    expect(flushed.seen).to end_with("[y/N] ")
  end

  it "shows what the inspection flagged" do
    console("n\n").approve?(request(flagged: ["a private key block"]))

    expect(output.string).to include("a private key block")
  end

  it "escapes a control character so the body cannot redraw the prompt" do
    console("n\n").approve?(request("{\"a\":\"\e[2J\"}"))

    expect(output.string).not_to include("\e")
    expect(output.string).to include('\e[2J')
  end

  it "shows a body that is not valid UTF-8 without raising" do
    expect { console("n\n").approve?(request("{\"a\":\"\xFF\"}".b)) }.not_to raise_error
  end

  it "asks one request at a time when two arrive together" do
    reader, writer = IO.pipe
    gateway = described_class.new(input: reader, output:)
    answers = Array.new(2) { Thread.new { gateway.approve?(request) } }
    wait_until(reason: "the first prompt") { output.string.include?("[y/N]") }
    sleep 0.2

    expect(output.string.scan("[y/N]").size).to eq(1)
    writer.write("y\n")
    wait_until(reason: "the second prompt") { output.string.scan("[y/N]").size == 2 }
    writer.write("n\n")
    expect(answers.map(&:value).sort_by(&:to_s)).to eq([false, true])
  ensure
    [reader, writer].each(&:close)
  end

  it "announces each caveat beside the URL" do
    described_class.new(input: StringIO.new, output:).announce(url: "u", log: "l", caveats: ["only env secrets"])

    expect(output.string).to include("only env secrets")
  end

  it "announces the URL and the log" do
    described_class.new(input: StringIO.new, output:)
                   .announce(url: "http://127.0.0.1:1/?token=ab", log: "/tmp/g.ndjson")

    expect(output.string).to include("http://127.0.0.1:1/?token=ab", "/tmp/g.ndjson")
  end
end
