# frozen_string_literal: true

RSpec.describe WarmPool::Pool do
  let(:booted) { [] }
  let(:child_class) do
    Struct.new(:key, :reaped) do
      def reap = self.reaped = true
    end
  end

  def pool(expected:)
    described_class.new(expected:) { |key| child_class.new(key, false).tap { |child| booted << child } }
  end

  it "boots the first child on demand and a spare behind it while more are expected" do
    warm = pool(expected: 3)

    first = warm.take(:xterm)

    expect([booted.size, booted.last.equal?(first)]).to eq([2, false])
  end

  it "hands over the spare it booted ahead rather than booting again" do
    warm = pool(expected: 3)
    warm.take(:xterm)
    spare = booted.last

    expect([warm.take(:xterm).equal?(spare), booted.size]).to eq([true, 3])
  end

  it "boots no spare once the last expected child is taken" do
    warm = pool(expected: 1)

    warm.take(:xterm)

    expect(booted.size).to eq(1)
  end

  it "keys spares by what the child cannot be told after it boots" do
    warm = pool(expected: 4)
    warm.take(:xterm)

    expect(warm.take(:dumb).key).to eq(:dumb)
  end

  it "boots a spare for a key only while more of that key are expected" do
    warm = described_class.new(expected: { a: 2, b: 1 }) { |key| child_class.new(key, false).tap { |c| booted << c } }

    warm.take(:b)

    expect(booted.map(&:key)).to eq([:b])
  end

  it "reaps only the spares left over, once each, however often it is drained" do
    warm = pool(expected: 3)
    taken = warm.take(:xterm)
    reaps = Hash.new(0).compare_by_identity
    booted.each { |child| child.define_singleton_method(:reap) { reaps[self] += 1 } }

    2.times { warm.drain }

    expect([reaps[taken], reaps[booted.last]]).to eq([0, 1])
  end

  it "refuses a key nobody expected before booting anything" do
    warm = described_class.new(expected: { a: 1 }) { |key| child_class.new(key, false).tap { |c| booted << c } }

    expect { warm.take(:unlisted) }.to raise_error(KeyError, /unlisted.*\[:a\]/)
    expect(booted).to be_empty
  end

  it "refuses a take beyond the expected count, naming the key, the count and the take, before booting" do
    warm = described_class.new(expected: { a: 2 }) { |key| child_class.new(key, false).tap { |c| booted << c } }
    2.times { warm.take(:a) }
    booted_before = booted.size

    expect { warm.take(:a) }.to raise_error(ArgumentError, /:a.*expected 2 times.*take 3/)
    expect(booted.size).to eq(booted_before)
  end
end

RSpec.describe WarmPool::Group do
  describe "a group that declares a pool" do
    let(:events) { [] }

    def pooled_group(takers:, idle: 0)
      log = events
      RSpec::Core::ExampleGroup.describe("pooled") do
        warm_pool(:children) do |key|
          child = Struct.new(:key, :log) { def reap = log << :reaped }.new(key, log)
          log << :booted
          child
        end

        takers.times { |index| it("takes #{index}") { expect(children.take(:a)).not_to be_nil } }
        idle.times { |index| it("idles #{index}") { expect(children).not_to be_nil } }
      end
    end

    it "sizes the pool by the examples that will run, booting no spare after the last" do
      pooled_group(takers: 3).run(RSpec::Core::NullReporter)

      expect(events.count(:booted)).to eq(3)
    end

    it "drains the pool after the group" do
      pooled_group(takers: 2, idle: 1).run(RSpec::Core::NullReporter)

      expect(events.count(:reaped)).to eq(1)
    end
  end
end

RSpec.describe OncePerFile do
  describe "a group whose examples ask the same slow question" do
    asked = []
    once(:answer) { (asked << :asked) && 42 }

    it "computes it for the first example that asks" do
      expect(answer).to eq(42)
    end

    it "does not compute it again for the next" do
      answer
      expect([answer, asked.size]).to eq([42, 1])
    end
  end
end

RSpec.describe WarmPool do
  describe "a parked child whose worker died" do
    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    it "exits on its own within a second" do
      Dir.mktmpdir("warm-ppid") do |dir|
        go = described_class.go_path(dir)
        park = described_class::PARK
        reader, writer = IO.pipe
        worker = Process.spawn(RbConfig.ruby, "-e", <<~RUBY, out: writer)
          child = Process.spawn({ "WARM_GO" => #{go.inspect}, "WARM_PPID" => Process.pid.to_s },
                                RbConfig.ruby, "-e", #{park.inspect})
          puts child
          $stdout.flush
        RUBY
        writer.close
        child = reader.gets.to_i
        Process.wait(worker)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        sleep(0.02) while alive?(child) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        expect(alive?(child)).to be(false)
      ensure
        Process.kill("KILL", child) if child&.positive? && alive?(child)
      end
    end
  end
end

RSpec.describe WarmCockpit do
  it "parks a chat until released, then runs its script with the released arguments" do
    booted = described_class.chat(prefix: "warm-chat",
                                  script: 'File.write(File.join(ARGV[0], "out"), ARGV.drop(1).join(" "))')
    booted.tell(booted.dir, "one", "two")
    out = File.join(booted.dir, "out")
    wait_until(timeout: 15, reason: "the released chat writing its output") { File.exist?(out) }

    expect(File.read(out)).to eq("one two")
  ensure
    booted&.reap
  end
end
