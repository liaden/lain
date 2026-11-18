# frozen_string_literal: true

require "etc"

RSpec.describe "the suite's home" do
  it "keeps a Paths built from a hash with no HOME off a config.rb planted under the process HOME" do
    Dir.mktmpdir do |home|
      planted = File.join(home, ".config", "lain", "config.rb")
      FileUtils.mkdir_p(File.dirname(planted))
      File.write(planted, "raise 'a spec read the real home'\n")

      with_env("HOME" => home) do
        paths = Lain::Paths.new(env: SpecHome.env("XDG_RUNTIME_DIR" => "/run/user/7"))

        Dir.mktmpdir { |root| expect { Lain::Config.middleware(root:, paths:) }.not_to raise_error }
        expect(paths.user_config).not_to start_with(home)
      end
    end
  end

  it "leaves a hash that names its own HOME or config home alone" do
    named = { "HOME" => "/h" }
    configured = { "XDG_CONFIG_HOME" => "/c" }

    expect([SpecHome.env(named), SpecHome.env(configured)]).to eq([named, configured])
  end

  it "has every literal-hash Paths.new(env: ...) in spec/ name a home or go through SpecHome.env" do
    exempt = [__FILE__, File.expand_path("lain/paths_spec.rb", __dir__)]
    bare = Dir[File.expand_path("**/*.rb", __dir__)].reject { exempt.include?(_1) }.flat_map do |file|
      File.read(file).scan(/Paths\.new\(env: (\{.*?\})(?:,|\))/m).flatten
          .grep_v(/"HOME"|XDG_CONFIG_HOME/).map { "#{file}: #{_1}" }
    end

    expect(bare).to be_empty
  end
end
