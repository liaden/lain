# frozen_string_literal: true

RSpec.describe Lain::Confine::Launcher do
  let(:launcher) { Class.new { include Lain::Confine::Launcher }.new }
  let(:profile) { Lain::Confine::Profile::NONE }

  it "asks its includer for what a profile's masks bind, and for the wrap that binds them" do
    expect { launcher.masked(profile) }.to raise_error(NotImplementedError, /must implement #masked/)
    expect { launcher.wrap(Lain::Shell::Term.of(%w[true]), profile, trace_fd: 3, bound: nil) }
      .to raise_error(NotImplementedError, /must implement #wrap/)
  end
end
