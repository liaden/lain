# frozen_string_literal: true

RSpec.describe Lain::Config::Attention do
  it "waits 30 seconds by default" do
    expect(described_class.empty.delay).to eq(30)
  end

  it "reads a declared delay" do
    expect(described_class.from({ "delay" => 5 }, path: "/u/config.rb:1").delay).to eq(5)
  end

  it "accepts zero and a fraction of a second" do
    expect([0, 0.5].map { |delay| described_class.from({ "delay" => delay }, path: nil).delay }).to eq([0, 0.5])
  end

  it "refuses a negative delay, naming the key and the value" do
    expect { described_class.from({ "delay" => -1 }, path: "/u/config.rb:2") }
      .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:2: .*delay.*-1})
  end

  it "refuses a delay that is not a number, naming the key and the value" do
    expect { described_class.from({ "delay" => "soon" }, path: "/u/config.rb:2") }
      .to raise_error(Lain::Config::Refusal, /delay.*"soon"/)
  end

  it "refuses a complex number, naming the key and the value" do
    expect { described_class.from({ "delay" => Complex(1, 2) }, path: "/u/config.rb:2") }
      .to raise_error(Lain::Config::Refusal, /delay.*1\+2i/)
  end

  it "refuses an infinite delay, naming the key and the value" do
    expect { described_class.from({ "delay" => Float::INFINITY }, path: "/u/config.rb:2") }
      .to raise_error(Lain::Config::Refusal, /delay.*Infinity/)
  end

  it "refuses an unknown key, naming it" do
    expect { described_class.from({ "dealy" => 5 }, path: "/u/config.rb:3") }
      .to raise_error(Lain::Config::Refusal, /dealy.*delay/)
  end
end
