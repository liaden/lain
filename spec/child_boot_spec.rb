# frozen_string_literal: true

require "tmpdir"

RSpec.describe ChildBoot do
  let(:cache) { File.expand_path("../tmp/cache", __dir__) }

  describe ".install" do
    it "adds bootsnap to a bundler-swapped RUBYOPT and names the shared cache" do
      env = { "RUBYOPT" => "-rbundler/setup" }

      described_class.install(env:)

      expect(env).to include("LAIN_BOOTSNAP_CACHE" => cache)
      expect(env["RUBYOPT"]).to include("-r#{File.expand_path("bootsnap_setup.rb", __dir__)}")
    end

    it "leaves a child that has no bundler setup to boot without the cache" do
      env = { "RUBYOPT" => "-W0" }

      described_class.install(env:)

      expect([env["RUBYOPT"], env.key?("LAIN_BOOTSNAP_CACHE")]).to eq(["-W0", false])
    end
  end

  describe "a child of this runner" do
    let(:lib) { File.expand_path("../lib", __dir__) }

    def boot
      probe = 'require "lain"; p defined?(Bootsnap), $LOADED_FEATURES.grep(/bootsnap_setup/).first'
      IO.popen(ENV.to_h, [RbConfig.ruby, "-I#{lib}", "-e", probe], &:read)
    end

    it "loads lain through bootsnap set up by the shared cache file" do
      expect(boot).to eq(%("constant"\n#{ChildBoot::BOOTSNAP_SETUP.inspect}\n))
    end
  end

  describe "the environments that set their own cache home" do
    it "keeps the shared cache in a warm cockpit child" do
      expect(WarmCockpit.env(Dir.tmpdir)).to include("LAIN_BOOTSNAP_CACHE" => ENV.fetch("LAIN_BOOTSNAP_CACHE"))
    end

    it "keeps the shared cache in an e2e sandbox child" do
      sandbox = E2E::Sandbox.create

      expect(sandbox.env).to include("LAIN_BOOTSNAP_CACHE" => ENV.fetch("LAIN_BOOTSNAP_CACHE"))
    ensure
      sandbox&.reap
    end
  end
end
