# frozen_string_literal: true

require "open3"

RSpec.describe "spec/support/isolated_tmux" do
  let(:support) { File.expand_path("support/isolated_tmux.rb", __dir__) }

  # A fresh Ruby, because the support file acts at load: the suite process has long since loaded it.
  def markers_after_start(own_config: false)
    socket_tmpdir("tx") do |home|
      File.write(File.join(home, ".tmux.conf"), "run-shell 'touch #{home}/user-config-ran'\n")
      File.write(File.join(home, "own.conf"), "run-shell 'touch #{home}/own-config-ran'\n")
      flags = own_config ? ["-f", File.join(home, "own.conf")] : []
      env = { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"), "TMUX_TMPDIR" => home, "TMUX" => nil }
      script = "require #{support.inspect}\n" \
               "system('tmux', '-L', 'isotest', *#{flags.inspect}, 'new-session', '-d')\n" \
               "sleep 0.5\nsystem('tmux', '-L', 'isotest', 'kill-server', err: File::NULL)"
      out, status = Open3.capture2e(env, RbConfig.ruby, "-e", script)
      raise "child failed: #{out}" unless status.success?

      Dir.children(home).grep(/config-ran\z/).sort
    end
  end

  before { skip "needs tmux" unless system("command -v tmux >/dev/null 2>&1") }

  it "keeps a user config that runs plugins out of a spec tmux server" do
    expect(markers_after_start).to eq([])
  end

  it "still loads a config the spec passes with its own -f, and not the user's" do
    expect(markers_after_start(own_config: true)).to eq(["own-config-ran"])
  end
end
