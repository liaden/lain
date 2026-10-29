# frozen_string_literal: true

RSpec.describe Lain::Frontend::TTY::Indicator do
  let(:output) { StringIO.new }
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:now) { [100.0] }
  let(:clock) { -> { now.first } }
  let(:erase) { "\r#{TTY::Cursor.clear_line}" }
  let!(:threads_before) { Thread.list.size }

  def indicator(tty: true) = described_class.new(output:, theme:, clock:, tty:)

  after { @indicator&.stop }

  def tickers = Thread.list.size - threads_before

  it "draws nothing before 1 second has passed" do
    @indicator = indicator.tap(&:start)
    now[0] = 100.9

    @indicator.tick

    expect(output.string).to eq("")
  end

  it "rewrites the line in place with the elapsed seconds" do
    @indicator = indicator.tap(&:start)

    now[0] = 101.2
    @indicator.tick
    now[0] = 102.5
    @indicator.tick

    expect(output.string).to eq("#{erase}working… 1s#{erase}working… 2s")
  end

  it "names the work it was started with" do
    @indicator = indicator.tap { |i| i.start("thinking") }
    now[0] = 101

    @indicator.tick

    expect(output.string).to include("thinking… 1s")
  end

  it "erases the line it drew" do
    @indicator = indicator.tap(&:start)
    now[0] = 101
    @indicator.tick
    output.truncate(0)
    output.rewind

    @indicator.clear

    expect(output.string).to eq(erase)
  end

  it "writes nothing on clear when nothing was drawn" do
    @indicator = indicator.tap(&:start)

    @indicator.clear

    expect(output.string).to eq("")
  end

  it "waits a further quiet second after a clear before it draws again" do
    @indicator = indicator.tap(&:start)
    now[0] = 105
    @indicator.clear

    now[0] = 105.5
    @indicator.tick
    expect(output.string).to eq("")

    now[0] = 106
    @indicator.tick

    expect(output.string).to eq("#{erase}working… 1s")
  end

  it "does not redraw after it was stopped" do
    @indicator = indicator.tap(&:start)
    @indicator.stop
    now[0] = 105

    @indicator.tick

    expect(output.string).to eq("")
  end

  it "erases what it drew when stopped" do
    @indicator = indicator.tap(&:start)
    now[0] = 101
    @indicator.tick
    output.truncate(0)
    output.rewind

    @indicator.stop

    expect(output.string).to eq(erase)
  end

  it "leaves no ticker thread once stopped" do
    @indicator = indicator.tap(&:start)
    expect(tickers).to eq(1)

    @indicator.stop

    expect(tickers).to eq(0)
  end

  it "keeps one ticker across a clear" do
    @indicator = indicator.tap(&:start)

    @indicator.clear

    expect(tickers).to eq(1)
  end

  it "draws from its own ticker thread" do
    ticks = [100.0]
    drawn = described_class.new(output:, theme:, clock: -> { ticks[0] += 1 }, tty: true, interval: 0.01)
    @indicator = drawn

    drawn.start
    Timeout.timeout(5) { sleep 0.01 until output.string.include?("working…") }

    expect(output.string).to include("working… 1s")
  end

  it "draws nothing when the output is not a tty" do
    @indicator = indicator(tty: false).tap(&:start)
    now[0] = 105

    @indicator.tick
    @indicator.clear

    expect(output.string).to eq("")
    expect(tickers).to eq(0)
  end
end
