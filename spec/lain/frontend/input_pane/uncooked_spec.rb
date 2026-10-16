# frozen_string_literal: true

require "pty"

# The idle pane's terminal over a real PTY: the mode and the paste setting are
# the kernel's and the terminal's, so a double would only restate the ioctl.
RSpec.describe Lain::Frontend::InputPane::Uncooked do
  let(:pty) { PTY.open }
  let(:keyboard) { pty.first }
  let(:terminal) { pty.last }

  after { pty.each { |io| io.close unless io.closed? } }

  def modes = `stty -F #{terminal.path} -a`.split(/[\s;]+/) & %w[icanon -icanon echo -echo isig -isig]

  it "turns line editing and echo off for the block, keeps signals, and gives the mode back after" do
    inside = described_class.new(terminal).around { modes }

    expect([inside, modes]).to eq([%w[isig -icanon -echo], %w[isig icanon echo]])
  end

  it "turns bracketed paste on for the block and off after" do
    inside = described_class.new(terminal).around { pty_read(keyboard, "\e[?2004h".bytesize) }
    terminal.close

    expect([inside, pty_drained(keyboard)]).to eq(["\e[?2004h", "\e[?2004l"])
  end

  it "waits a recheck between waits that fail with EINVAL, rather than spinning" do
    failing = Class.new do
      attr_reader :waits

      def initialize = @waits = 0

      def wait_readable(*)
        @waits += 1
        raise Errno::EINVAL
      end
    end.new
    reading = Thread.new { Sync { described_class.new(failing).around { |uncooked| uncooked.reads { nil } } } }
    sleep(0.35)

    expect(failing.waits).to be_between(1, 5)
  ensure
    reading&.kill&.join(1)
  end

  it "takes keys again once the terminal comes back cooked, as after Ctrl-Z and fg" do
    got = Queue.new
    reading = Thread.new do
      Sync { described_class.new(terminal).around { |uncooked| uncooked.reads { |bytes| got << bytes } } }
    end
    Enumerator.produce { sleep(0.02) && modes }.find { |now| now.include?("-icanon") }

    terminal.cooked!
    sleep(0.3)
    keyboard.write("x")

    expect([got.pop(timeout: 3), modes.include?("-icanon")]).to eq(["x", true])
  ensure
    reading&.kill&.join(1)
  end
end
