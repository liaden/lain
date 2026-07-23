# frozen_string_literal: true

require "tmpdir"
require "json"
require "open3"
require "fileutils"
require "time"

# T6: the in-repo tmux plugin -- a tpm-style install surface over the SAME
# `.lain/state.json` HUD `lain up` builds inline (lib/lain/cli/up.rb). One
# `run-shell .../plugin/tmux/lain.tmux` from any tmux.conf must:
#
# * interpolate `#{lain_status}` in status-left/-right into a
#   `#('scripts/lain-status' #{q:pane_current_path})` job -- jq render when
#   jq is on PATH, raw-cat fallback when it is not, an honest "lain: no
#   state yet" when the pane's project has no state file yet;
# * bind prefix keys for the /btw popup and /fork window, each wrapped in
#   if-shell so a machine without `lain` degrades to a display-message,
#   never a bound error;
# * take every default from an overridable `@lain_*` option.
#
# Same two-tier idiom as spec/lain/cli/up_spec.rb: examples that need a real
# tmux run against a scratch `-L` server (never Joel's real session) and
# skip -- never fail -- when tmux or jq is absent from PATH; everything the
# status script can prove alone runs directly through `sh`, on every
# machine. The --btw/--fork flags themselves land in T3 -- these examples
# pin the COMMAND LINES the bindings would run, not the flags' effect.
RSpec.describe "plugin/tmux" do
  def tmux_present? = system("tmux", "-V", out: File::NULL, err: File::NULL)
  def jq_present? = system("jq", "--version", out: File::NULL, err: File::NULL)

  let(:plugin_dir) { File.expand_path("../../plugin/tmux", __dir__) }
  let(:plugin_entry) { File.join(plugin_dir, "lain.tmux") }
  let(:status_script) { File.join(plugin_dir, "scripts", "lain-status") }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  def write_state(cache_deadline:, fleet:, inbox_count:, dir: @dir)
    FileUtils.mkdir_p(File.join(dir, ".lain"))
    File.write(File.join(dir, ".lain", "state.json"),
               JSON.generate({ "cache_deadline" => cache_deadline, "fleet" => fleet,
                               "inbox_count" => inbox_count }))
  end

  describe "scripts/lain-status" do
    def run_status(env = {})
      Open3.capture3(env, status_script, @dir)
    end

    it "embeds Up::JQ_FILTER verbatim, so the plugin and `lain up` render one HUD" do
      expect(File.read(status_script)).to include(Lain::CLI::Up::JQ_FILTER)
      expect(File.executable?(status_script)).to be true
    end

    it "renders the warm HUD line from state.json via jq" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a b], inbox_count: 3)

      out, _err, status = run_status

      expect(out.strip).to eq("🔥 fleet:2 inbox:3")
      expect(status.exitstatus).to eq(0)
    end

    it "shows the cold glyph once the cache deadline has passed" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now - 300).utc.iso8601, fleet: [], inbox_count: 0)

      out, _err, status = run_status

      expect(out.strip).to eq("❄ fleet:0 inbox:0")
      expect(status.exitstatus).to eq(0)
    end

    it "prints 'lain: no state yet' and exits 0 when there is no state file" do
      out, _err, status = run_status

      expect(out.strip).to eq("lain: no state yet")
      expect(status.exitstatus).to eq(0)
    end

    it "prints 'lain: no state yet', never an error, on a corrupt state file" do
      skip("jq not found on PATH") unless jq_present?
      FileUtils.mkdir_p(File.join(@dir, ".lain"))
      File.write(File.join(@dir, ".lain", "state.json"), "{half a jso")

      out, _err, status = run_status

      expect(out.strip).to eq("lain: no state yet")
      expect(status.exitstatus).to eq(0)
    end

    # jq -r on a zero-byte file exits 0 with EMPTY output (so does cat), so a
    # bare existence check would render a silently blank segment -- the exact
    # never-blank violation the script's own contract forbids. Panel probe
    # probe_state_variants.sh, fix round.
    it "prints 'lain: no state yet', never a blank segment, on a zero-byte state file" do
      FileUtils.mkdir_p(File.join(@dir, ".lain"))
      FileUtils.touch(File.join(@dir, ".lain", "state.json"))

      out, _err, status = run_status

      expect(out.strip).to eq("lain: no state yet")
      expect(status.exitstatus).to eq(0)
    end

    it "falls back to raw state.json via cat when jq is missing" do
      write_state(cache_deadline: nil, fleet: %w[a], inbox_count: 1)

      out, _err, status = run_status({ "PATH" => jqless_bin })

      expect(JSON.parse(out)).to eq({ "cache_deadline" => nil, "fleet" => %w[a], "inbox_count" => 1 })
      expect(status.exitstatus).to eq(0)
    end

    # A PATH holding cat but no jq, so the fallback branch runs
    # deterministically even on machines where jq IS installed.
    def jqless_bin
      bin = File.join(@dir, "jqless-bin")
      FileUtils.mkdir_p(bin)
      cat = %w[/bin/cat /usr/bin/cat].find { |path| File.executable?(path) }
      File.symlink(cat, File.join(bin, "cat"))
      bin
    end
  end

  describe "lain.tmux against a real tmux server" do
    before { skip("tmux not found on PATH") unless tmux_present? }

    let(:socket) { "lain-spec-#{Process.pid}-#{object_id}" }

    after { system("tmux", "-L", socket, "kill-server", out: File::NULL, err: File::NULL) }

    def tmux(*args) = Open3.capture2("tmux", "-L", socket, *args).first.strip

    # Boots a scratch server whose conf carries the tpm-style run-shell line,
    # with `extra_conf` (the @lain_* overrides) sourced BEFORE the plugin so
    # lain.tmux reads them the way a real tmux.conf would order them. The
    # first session ("hud") starts in @dir, so its pane cwd is the scratch
    # project the examples write state into.
    # The run-shell target is INNER-quoted ("'#{entry}'"): tmux hands
    # run-shell's argument to `sh -c` unquoted, so an install path with
    # spaces word-splits (returns 127, plugin never loads) unless the conf
    # line itself carries shell quotes. This is the documented install form
    # (plugin/tmux/README.md) and is what makes the spaced-install example
    # exercise the JOB-BODY fix rather than dying at load.
    def boot(extra_conf = "", entry: plugin_entry)
      conf_path = File.join(@dir, "tmux.conf")
      File.write(conf_path, <<~CONF)
        set -g status-right '\#{lain_status}'
        #{extra_conf}
        run-shell "'#{entry}'"
      CONF
      system("tmux", "-L", socket, "-f", conf_path, "new-session", "-d", "-s", "hud", "-c", @dir,
             "-x", "80", "-y", "24", out: File::NULL, err: File::NULL) ||
        raise("scratch tmux server failed to start")
      wait_for_plugin
    end

    # run-shell in a sourced conf is synchronous in practice, but nothing
    # pins that; polling on the plugin's LAST acts (both keybindings, bound
    # after interpolation) keeps the examples deterministic without sleeping
    # a fixed interval.
    def wait_for_plugin
      deadline = Time.now + 5
      sleep(0.05) while Time.now < deadline && !plugin_loaded?
      raise "lain.tmux did not finish loading within 5s" unless plugin_loaded?
    end

    def plugin_loaded?
      tmux("list-keys").scan("not found on PATH").size >= 2
    end

    def binding_line(key)
      tmux("list-keys").lines.find { |line| line.match?(/-T prefix\s+#{Regexp.escape(key)}\s/) }
    end

    # up_spec.rb's eval_status_job (:37-41), made faithful to tmux's OWN
    # pipeline: the status job's format variables are expanded by a REAL
    # tmux against the named pane (display-message -p expands exactly as the
    # status renderer does, quoting modifiers and all), and only THEN does
    # the result reach `sh -c` -- the same two steps tmux performs, minus
    # the async status-bar refresh timing up_spec.rb records as the flake to
    # avoid. This is what makes the hostile-cwd regression below honest: the
    # expansion, not the spec, decides what the shell sees.
    def eval_status_job(target)
      raw = tmux("show-options", "-gv", "status-right")
      job = raw.strip.sub(/\A#\(/, "").sub(/\)\z/, "")
      expanded = tmux("display-message", "-p", "-t", target, job)
      out, = Open3.capture3("sh", "-c", expanded)
      out.strip
    end

    it "interpolates \#{lain_status} in status-right into a lain-status job on the pane's cwd" do
      boot

      status_right = tmux("show-options", "-gv", "status-right")

      expect(status_right).to eq("#('#{status_script}' \#{q:pane_current_path})")
    end

    it "renders the same warm HUD line `lain up` shows, through the interpolated job" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a b], inbox_count: 3)
      boot

      expect(eval_status_job("hud")).to eq("🔥 fleet:2 inbox:3")
    end

    it "renders 'lain: no state yet' when the pane's project has no state file" do
      boot

      expect(eval_status_job("hud")).to eq("lain: no state yet")
    end

    # tmux substitutes #{pane_current_path} into the job body WITHOUT
    # re-quoting before /bin/sh -c runs it, so a quoted slot in the format
    # string is an injection surface: a pane cwd of x'; touch PWNED; :'y
    # executed its payload (panel probe probe_real_tmux2.sh, fix round). The
    # #{q:...} shell-quote modifier makes tmux itself produce the quoting --
    # the only layer that can do it correctly, because only tmux sees the
    # literal path.
    it "neutralizes a hostile pane cwd -- the HUD renders, the payload never runs" do
      skip("jq not found on PATH") unless jq_present?
      canary = File.join(@dir, "PWNED")
      evil = File.join(@dir, "x'; touch #{canary}; :'y")
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a], inbox_count: 1, dir: evil)
      boot
      system("tmux", "-L", socket, "new-session", "-d", "-s", "evil", "-c", evil,
             "-x", "80", "-y", "24", out: File::NULL, err: File::NULL)

      rendered = eval_status_job("evil")

      expect(File.exist?(canary)).to be false
      expect(rendered).to eq("🔥 fleet:1 inbox:1")
    end

    # The other half of the same quoting hole: the SCRIPT-PATH side of the
    # job splits on an install path with spaces (panel probe
    # probe_plugin_dir_spaces.sh, fix round).
    it "survives an install path with spaces in it" do
      skip("jq not found on PATH") unless jq_present?
      spaced = File.join(@dir, "plugin dir")
      FileUtils.mkdir_p(spaced)
      FileUtils.cp_r(File.join(plugin_dir, "."), spaced)
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a], inbox_count: 1)
      boot("", entry: File.join(spaced, "lain.tmux"))

      expect(eval_status_job("hud")).to eq("🔥 fleet:1 inbox:1")
    end

    it "binds a prefix key that opens the btw popup, guarded down to a message" do
      boot

      line = binding_line("b")

      expect(line).to include("if-shell")
      expect(line).to include("display-popup")
      expect(line).to include("lain chat --btw")
      expect(line).to include("display-message")
    end

    it "binds a prefix key that opens the fork window, guarded down to a message" do
      boot

      line = binding_line("F")

      expect(line).to include("if-shell")
      expect(line).to include("new-window")
      expect(line).to include("lain chat --fork")
      expect(line).to include("display-message")
    end

    it "honors @lain_* overrides for both keys and both command lines" do
      boot(<<~CONF)
        set -g @lain_btw_key "x"
        set -g @lain_fork_key "y"
        set -g @lain_btw_command "mylain chat --btw --profile demo"
        set -g @lain_fork_command "mylain chat --fork"
      CONF

      expect(binding_line("b").to_s).not_to include("display-popup")
      expect(binding_line("x")).to include("display-popup").and include("mylain chat --btw --profile demo")
      expect(binding_line("y")).to include("new-window").and include("mylain chat --fork")
    end
  end
end
