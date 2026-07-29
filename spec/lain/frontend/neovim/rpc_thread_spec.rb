# frozen_string_literal: true

# {RpcThread::Listener}'s own contract, plain Ruby -- no editor needed. The
# round trip that actually WIRES a listener into a live nvim session is the
# :nvim group's job (neovim_spec.rb, neovim_request_spec.rb,
# neovim_runtime_spec.rb); this file pins the abstract base's refusal and
# {Listener::Null}'s no-op answers on their own (T34).
RSpec.describe Lain::Frontend::Neovim::RpcThread::Listener do
  subject(:listener) { described_class.new }

  describe "the abstract base" do
    it "refuses RPC-thread death" do
      expect { listener.died }.to raise_error(NotImplementedError, /must implement #died/)
    end

    it "refuses a resend" do
      expect { listener.resend(["line"]) }.to raise_error(NotImplementedError, /must implement #resend/)
    end

    it "refuses a compose write" do
      expect { listener.compose_written(["line"], 1) }
        .to raise_error(NotImplementedError, /must implement #compose_written/)
    end

    it "refuses a compose abandon" do
      expect { listener.compose_abandoned(1) }
        .to raise_error(NotImplementedError, /must implement #compose_abandoned/)
    end
  end
end

RSpec.describe Lain::Frontend::Neovim::RpcThread::Listener::Null do
  subject(:null) { described_class.new }

  it "answers every hand-off as a silent no-op" do
    expect(null.died).to be_nil
    expect(null.resend(["line"])).to be_nil
    expect(null.compose_written(["line"], 3)).to be_nil
    expect(null.compose_abandoned(3)).to be_nil
  end

  it "is the RpcThread default, so a caller wiring none of the four gets a real duck" do
    rpc = Lain::Frontend::Neovim::RpcThread.new(socket_path: "/nonexistent")

    expect(rpc.instance_variable_get(:@listener)).to be_a(described_class)
  ensure
    rpc&.stop
  end
end
