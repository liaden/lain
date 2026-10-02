# frozen_string_literal: true

RSpec.describe ChildBoot do
  let(:probe) do
    script = 'require "lain"; print [defined?(Bundler).inspect, GC.count, Lain::VERSION.class, ' \
             'ENV["RUBY_GC_HEAP_0_INIT_SLOTS"], ENV["BUNDLER_SETUP"].inspect].join(" ")'
    IO.popen([RbConfig.ruby, "-e", script], err: File::NULL, &:read).split
  end

  describe "a child spawned with the inherited environment" do
    it "boots lain without bundler/setup and without BUNDLER_SETUP" do
      skip "kill switch set" if ENV["LAIN_NO_CHILD_BOOT"] == "1"

      expect(probe.values_at(0, 2, 4)).to eq(%w[nil String nil])
    end

    it "has the heap sized, so the boot collects at most 8 times" do
      skip "kill switch set" if ENV["LAIN_NO_CHILD_BOOT"] == "1"

      expect([probe[3], probe[1].to_i]).to match([ChildBoot::GC_SETTINGS.fetch("RUBY_GC_HEAP_0_INIT_SLOTS"), be <= 8])
    end
  end

  describe ".install" do
    let(:env) { { "RUBYOPT" => "-W0 -r/gems/bundler/setup -rother", "BUNDLER_SETUP" => "/x" } }

    before do
      allow(described_class).to receive(:cache_dir).and_return(Dir.mktmpdir("child_boot_spec"))
    end

    after { FileUtils.remove_entry(described_class.cache_dir) }

    it "swaps -rbundler/setup for a generated load-path file that exists" do
      described_class.install(env:)
      file = env["RUBYOPT"][/-r(\S*child_boot\S*\.rb)/, 1]

      expect([env["RUBYOPT"], File.file?(file), env.key?("BUNDLER_SETUP")])
        .to match([/\A-W0 -r\S+\.rb -rother\z/, true, false])
    end

    it "names the file by the load paths it resolves, so any change in resolution is a new file" do
      allow(described_class).to receive(:script).and_return("# one\n", "# two\n", "# one\n")
      names = Array.new(3) { described_class.install(env: env.dup) }

      expect([names[0] == names[2], names[0] == names[1]]).to eq([true, false])
    end

    it "sizes the heap without overriding a value already set" do
      env["RUBY_GC_HEAP_0_INIT_SLOTS"] = "1"
      described_class.install(env:)

      expect(env["RUBY_GC_HEAP_0_INIT_SLOTS"]).to eq("1")
    end

    it "writes the sizing into a fresh environment" do
      described_class.install(env:)

      expect(env.slice(*described_class::GC_SETTINGS.keys)).to eq(described_class::GC_SETTINGS)
    end

    it "treats only 1 as the kill switch" do
      zero = env.merge("LAIN_NO_CHILD_BOOT" => "0")
      described_class.install(env: zero)

      expect(zero).to include(described_class::GC_SETTINGS)
    end

    it "leaves the environment alone when the kill switch is set" do
      switched = env.merge("LAIN_NO_CHILD_BOOT" => "1")

      expect { described_class.install(env: switched) }.not_to(change { switched.dup })
    end

    it "does not touch RUBYOPT when the worker is not under bundler" do
      env["RUBYOPT"] = "-W0"
      described_class.install(env:)

      expect(env["RUBYOPT"]).to eq("-W0")
    end
  end

  describe "the generated file" do
    let(:cache) { Dir.mktmpdir("child_boot_spec") }
    let(:path) do
      allow(described_class).to receive(:cache_dir).and_return(cache)
      described_class.send(:load_path_file)
    end

    after { FileUtils.remove_entry(cache) }

    def run(code)
      IO.popen({ "RUBYOPT" => "-r#{path}", "BUNDLER_SETUP" => nil }, [RbConfig.ruby, "-e", code], err: %i[child out],
               &:read)
    end

    it "raises for a gem outside the lock, as bundler/setup does" do
      skip "worker is not under bundler" unless defined?(Bundler)

      expect(run('begin; gem "actioncable"; rescue Exception => e; print e.class; end')).to eq("Gem::MissingSpecError")
    end

    it "raises for a version outside the lock" do
      skip "worker is not under bundler" unless defined?(Bundler)

      expect(run('begin; gem "activesupport", "8.1.3.1"; rescue Exception => e; print e.class; end'))
        .to eq("Gem::MissingSpecVersionError")
    end

    it "runs gem executables, as under bundler/setup" do
      skip "worker is not under bundler" unless defined?(Bundler)

      expect(run("system('bundle', 'exec', 'ruby', '-e', '1') && system('rake', '-T', out: File::NULL); " \
                 "print $?.success?")).to end_with("true")
    end

    it "activates a locked gem when asked for it" do
      skip "worker is not under bundler" unless defined?(Bundler)

      expect(run('gem "msgpack"; print Gem.loaded_specs.key?("msgpack")')).to eq("true")
    end
  end

  describe "a child spawned through Lain::Exec.child_env" do
    it "has RUBYOPT scrubbed, so it keeps its own bundle" do
      expect(Lain::Exec.child_env({})).to include("RUBYOPT" => nil)
    end
  end
end
