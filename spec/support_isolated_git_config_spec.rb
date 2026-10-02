# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "spec/support/isolated_git_config" do
  let(:support) { File.expand_path("support/isolated_git_config.rb", __dir__) }

  # A fresh Ruby, because the support file acts at load: the suite process has long since loaded it.
  def run_in_hostile_home(script)
    Dir.mktmpdir("lain-hostile-home-") do |home|
      File.write(File.join(home, ".gitconfig"),
                 "[rerere]\n\tenabled = true\n[maintenance]\n\tauto = true\n[gc]\n\tauto = 1\n" \
                 "[user]\n\tname = Hostile\n\temail = hostile@example.test\n")
      env = { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"),
              "GIT_CONFIG_GLOBAL" => nil, "GIT_CONFIG_SYSTEM" => nil, "GIT_CONFIG_NOSYSTEM" => nil }
      out, status = Open3.capture2e(env, RbConfig.ruby, "-e", "require #{support.inspect}\n#{script}")
      [out, status]
    end
  end

  it "keeps a global rerere setting out of a fixture repository" do
    out, status = run_in_hostile_home(<<~RUBY)
      Dir.mktmpdir { |dir| puts `git -C \#{dir} init -q && git -C \#{dir} config --get rerere.enabled`.inspect }
    RUBY

    expect([status.success?, out.strip]).to eq([true, '""'])
  end

  it "does not start git maintenance when a fixture commits" do
    out, status = run_in_hostile_home(<<~RUBY)
      Dir.mktmpdir do |dir|
        ENV["GIT_TRACE2_EVENT"] = File.join(dir, "trace")
        system("git", "-C", dir, "init", "-q")
        system("git", "-C", dir, "-c", "user.name=a", "-c", "user.email=a@b.c", "commit", "-q", "--allow-empty", "-m", "x")
        puts File.read(ENV["GIT_TRACE2_EVENT"]).scan(/maintenance/).size
      end
    RUBY

    expect([status.success?, out.strip]).to eq([true, "0"])
  end

  it "withholds the developer's identity from spec git" do
    out, = run_in_hostile_home(<<~RUBY)
      puts `git config --global --get user.name`.inspect
    RUBY

    expect(out.strip).to eq('""')
  end
end
