# frozen_string_literal: true

require "tmpdir"
require "json"
require "open3"
require "fileutils"
require "time"

# The in-repo tmux plugin -- a tpm-style install surface over the SAME
# state feed `lain up` builds inline (lib/lain/cli/up.rb). One
# `run-shell .../plugin/tmux/lain.tmux` from any tmux.conf must:
#
# * interpolate `#{lain_status}` in status-left/-right into a
#   `#('lain.tmux' status #{q:pane_current_path})` job -- jq render when
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
# machine. The --btw/--fork flags themselves land elsewhere -- these examples
# pin the COMMAND LINES the bindings would run, not the flags' effect.
#
# The plugin's two shell files are split by what each is ALLOWED to know.
# The feed lives at `$XDG_STATE_HOME/lain/status/<hash>/state.json`,
# and reproducing `sha256(realpath(dir))[0, 12]` needs a digest binary that
# POSIX does not mandate -- so `scripts/lain-status` is TOLD a FILE and
# computes nothing (its whole contract is `[ -s "$state" ]`), while
# `lain.tmux`, which is bash and is the plugin's own entry point, resolves
# the pane's directory to that file at RENDER time. It has to be render time:
# `#{pane_current_path}` is expanded per pane by tmux, long after the
# run-shell line has finished, so nothing can be precomputed when the plugin
# is sourced. `lain.tmux state-path` is the resolver alone, and it is
# cross-pinned against Ruby's locator here for the same reason
# `nvim_plugin_spec.rb` cross-pins the Lua copy: a third spelling of one
# recipe drifts into a blank status bar otherwise.
RSpec.describe "plugin/tmux" do
  def tmux_present? = system("tmux", "-V", out: File::NULL, err: File::NULL)
  def jq_present? = system("jq", "--version", out: File::NULL, err: File::NULL)

  let(:plugin_dir) { File.expand_path("../../plugin/tmux", __dir__) }
  let(:plugin_entry) { File.join(plugin_dir, "lain.tmux") }
  let(:status_script) { File.join(plugin_dir, "scripts", "lain-status") }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  # A scratch `$XDG_STATE_HOME` per example, exported into every shell these
  # examples drive, so nothing here can read or write the real one -- and so
  # the resolver's answer is checkable rather than being wherever this box
  # happens to keep its state.
  def state_home = File.join(@dir, "xdg-state")
  def plugin_env = { "XDG_STATE_HOME" => state_home }

  # Resolved through the REAL locator, never a hand-built spelling: a spec
  # that composes the path itself can agree with a plugin that both got wrong.
  def state_path(dir = @dir)
    Lain::ProjectDir.new(root: dir, paths: Lain::Paths.new(env: plugin_env)).state_path
  end

  def write_state(cache_deadline:, fleet:, inbox_count:, dir: @dir, **extra)
    write_json(state_path(dir),
               JSON.generate({ "cache_deadline" => cache_deadline, "fleet" => fleet,
                               "inbox_count" => inbox_count }.merge(extra.transform_keys(&:to_s))))
  end

  def write_json(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # Both describes below build a cut-down PATH out of symlinks, so each needs
  # the real location of a binary before removing it from view.
  def which(binary)
    ENV.fetch("PATH").split(File::PATH_SEPARATOR)
       .map { |dir| File.join(dir, binary) }.find { |path| File.executable?(path) }
  end

  describe "scripts/lain-status" do
    # One argument, and it is the FILE. The script joins nothing.
    def run_status(env = {}, path: state_path)
      Open3.capture3(env, status_script, path)
    end

    it "embeds Up::Hud::JQ_FILTER verbatim, so the plugin and `lain up` render one HUD" do
      expect(File.read(status_script)).to include(Lain::CLI::Up::Hud::JQ_FILTER)
      expect(File.executable?(status_script)).to be true
    end

    it "renders the warm HUD line from state.json via jq" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a b], inbox_count: 3)

      out, _err, status = run_status

      expect(out.strip).to eq("🔥 fleet:2 inbox:3")
      expect(status.exitstatus).to eq(0)
    end

    # The shipped script and Up::Hud move together or not at all -- the
    # verbatim-embedding example above is the mechanism, this is the effect:
    # the fields StatusFeed gained render identically out of the tmux plugin.
    it "renders the parked-approval count and the context occupancy the state feed now publishes" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a b], inbox_count: 3,
                  approvals_pending: 1, occupancy: 0.34)

      out, _err, status = run_status

      expect(out.strip).to eq("🔥 fleet:2 inbox:3 approve:1 ctx:34%")
      expect(status.exitstatus).to eq(0)
    end

    # Same discipline: the mode lighter arrives already composed, so the
    # script renders it without knowing a posture from a layer -- and stays
    # quiet under the silent default, whose lighter is the empty string.
    it "renders the composed mode lighter, and nothing when it is empty" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0, posture: "manual", mode_lighter: "MAN AA")
      expect(run_status.first.strip).to eq("❄ fleet:0 inbox:0 MAN AA")

      write_state(cache_deadline: nil, fleet: [], inbox_count: 0, posture: "accept_edits", mode_lighter: "")
      expect(run_status.first.strip).to eq("❄ fleet:0 inbox:0")
    end

    # The token spend and its pad ship in the shipped script too, for the same
    # reason the clamp does: the verbatim-embedding example above is the
    # mechanism, this is the effect. Chomped rather than stripped, because the
    # trailing pad is the assertion.
    it "renders the session's token spend, and pads the line with one trailing space" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0, occupancy: 0.34, run_tokens: 27_997)

      out, _err, status = run_status

      expect(out.chomp).to eq("❄ fleet:0 inbox:0 ctx:34% run:27997 ")
      expect(status.exitstatus).to eq(0)
    end

    # The clamp ships in the script too, or a status bar reads "ctx:244%". A
    # live chat now divides by the window its provider reports serving
    # (Lain::CLI::Backend#context_window), but a model no book carries and no
    # server reports on still measures against ContextWindow's 8,192-token
    # conservative fallback -- so a ratio above 1.0 still reaches this renderer.
    it "clamps the occupancy percentage at 100, exactly as Up::Hud does" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: nil, fleet: [], inbox_count: 0, occupancy: 2.44)

      out, _err, status = run_status

      expect(out.strip).to eq("❄ fleet:0 inbox:0 ctx:100%")
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
      write_json(state_path, "{half a jso")

      out, _err, status = run_status

      expect(out.strip).to eq("lain: no state yet")
      expect(status.exitstatus).to eq(0)
    end

    # jq -r on a zero-byte file exits 0 with EMPTY output (so does cat), so a
    # bare existence check would render a silently blank segment -- the exact
    # never-blank violation the script's own contract forbids. Panel probe
    # probe_state_variants.sh, fix round.
    it "prints 'lain: no state yet', never a blank segment, on a zero-byte state file" do
      write_json(state_path, "")

      out, _err, status = run_status

      expect(out.strip).to eq("lain: no state yet")
      expect(status.exitstatus).to eq(0)
    end

    # The renderer's whole input is a FILE, and it does not care
    # whose or where: no `.lain` join, no XDG root, no project hash. This is
    # what lets the two callers that DO know -- `lain up`, which interpolates
    # an absolute path into a session-scoped status-right, and `lain.tmux`,
    # which resolves the pane's directory at render time -- share one renderer
    # without either of them teaching it their own way of finding the file.
    it "renders the HUD from whatever state file path it is handed" do
      skip("jq not found on PATH") unless jq_present?
      arbitrary = write_json(File.join(@dir, "somewhere else", "feed.json"),
                             JSON.generate({ "cache_deadline" => nil, "fleet" => %w[a b c],
                                             "inbox_count" => 2 }))

      out, _err, status = run_status({}, path: arbitrary)

      expect(out.strip).to eq("❄ fleet:3 inbox:2")
      expect(status.exitstatus).to eq(0)
    end

    # The mechanism: Open decision 4 protects this script from growing
    # a hard dependency on a binary POSIX does not mandate. Asserted by
    # READING it, because a missing-binary runtime check passes vacuously on
    # the day someone adds the call behind a `command -v` guard.
    #
    # Comment lines are dropped first, for the reason `project_dir_spec.rb`
    # parses instead of grepping: the file's own header explains WHY it may
    # not call `realpath`, and a scan that cannot tell prose from code makes
    # the explanation the violation.
    it "names no digest or path-resolution binary at all" do
      code = File.read(status_script).lines.grep_v(/^\s*#/).join

      expect(code).not_to match(/sha256sum|shasum|openssl|realpath|readlink/)
    end

    # The effect: strip PATH down to jq alone -- no coreutils, no
    # digest tool -- and the HUD still renders, because resolving the input
    # was somebody else's job.
    it "renders with nothing but jq on PATH" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a], inbox_count: 1)

      out, _err, status = run_status({ "PATH" => jq_only_bin })

      expect(out.strip).to eq("🔥 fleet:1 inbox:1")
      expect(status.exitstatus).to eq(0)
    end

    # "Renders nothing" means renders no HUD: the never-blank contract
    # this script exists for makes the honest sentence the right answer, and
    # the zero-byte and no-state examples above pin the same one.
    it "exits 0 with the honest sentence when the path it was given is not there" do
      out, _err, status = run_status({}, path: File.join(@dir, "no", "such", "state.json"))

      expect(out.strip).to eq("lain: no state yet")
      expect(status.exitstatus).to eq(0)
    end

    # The resolver's degrade path hands over an EMPTY argument rather than
    # inventing a path it could not compute, so no-argument has to be as
    # honest as a missing file.
    it "exits 0 with the honest sentence when it is handed no path at all" do
      out, _err, status = Open3.capture3(status_script)

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

    # The mirror image: jq and NOTHING else -- no cat, no sha256sum, no
    # realpath. `/bin/sh` itself is found by its absolute shebang, not
    # through PATH, so the script still starts.
    def jq_only_bin
      bin = File.join(@dir, "jq-only-bin")
      FileUtils.mkdir_p(bin)
      File.symlink(which("jq"), File.join(bin, "jq"))
      bin
    end
  end

  # The half of the plugin that IS allowed to compute. These need no tmux
  # at all: the resolver is an ordinary argument-in, path-out program, and
  # driving it directly is what makes its agreement with Ruby checkable on
  # every machine rather than only where tmux is installed.
  describe "lain.tmux as the pane's resolver" do
    def resolve(dir = @dir, env: plugin_env)
      out, _err, status = Open3.capture3(env, plugin_entry, "state-path", dir)
      [out.strip, status.exitstatus]
    end

    def render(dir = @dir, env: plugin_env)
      out, _err, status = Open3.capture3(env, plugin_entry, "status", dir)
      [out.strip, status.exitstatus]
    end

    # The cross-language pin CORRECTION 4 asks for, and the reason this
    # subcommand is worth having at all: one recipe now has three spellings
    # (Ruby, Lua, bash), and the two that are not Ruby drift into a silently
    # blank status bar rather than into an error.
    it "resolves a directory to exactly the file Ruby's locator names" do
      expect(resolve).to eq([state_path, 0])
    end

    # `sha256(REALPATH(dir))`, not of the spelling: `lain up PATH` may hand
    # over a symlink while the pane's own `Dir.pwd` is kernel-resolved, and
    # the two have to name one file. Done with `cd -- "$dir" && pwd -P`, a
    # shell builtin, so this costs no `realpath` binary.
    it "resolves through a symlink the way File.realpath does" do
      link = File.join(@dir, "link-to-project")
      File.symlink(@dir, link)

      expect(resolve(link)).to eq([state_path(@dir), 0])
    end

    # $HOME/.local/state when XDG_STATE_HOME is unset, and the SAME when it is
    # set to something relative -- the XDG spec says a non-absolute value is
    # invalid and must be ignored, which is `Paths#present`'s rule and has to
    # be this copy's too.
    it "falls back to $HOME/.local/state, and ignores a relative XDG_STATE_HOME" do
      expect(resolve(env: { "HOME" => @dir, "XDG_STATE_HOME" => nil })).to eq([ruby_state_path("HOME" => @dir), 0])
      expect(resolve(env: { "HOME" => @dir, "XDG_STATE_HOME" => "relative/state" }))
        .to eq([ruby_state_path("HOME" => @dir), 0])
    end

    # Ruby composes these with `File.join`, which collapses ONE separator at
    # the join, so the shell's `${base%/}` has to sit on BOTH bases and not
    # just the XDG one. `$HOME=/` is not a hypothetical: it is what root gets
    # in a container, and `Paths::NonAbsoluteHome`'s docstring accepts it by
    # name (`/.local/state/lain` is a real answer) while
    # `Project::Resolver::UnusableHome` refuses it. A leading `//` is
    # implementation-defined in POSIX rather than merely ugly.
    it "agrees with Ruby on a base spelled with a trailing separator" do
      [{ "XDG_STATE_HOME" => "#{state_home}/" },
       { "HOME" => "#{@dir}/", "XDG_STATE_HOME" => nil },
       { "HOME" => "/", "XDG_STATE_HOME" => nil }].each do |env|
        expect(resolve(env:)).to eq([ruby_state_path(env), 0])
      end
    end

    # `cd` resolves a RELATIVE operand against $CDPATH when one is exported,
    # and echoes the directory it landed on -- so `resolved` became two lines
    # and the hash was of neither directory (measured: the doubled string
    # hashes to 01825ae7aa81, the right directory to 22b239bea2d3, the decoy
    # to 33386425385c). `File.expand_path` always resolves against the cwd.
    # The status bar is safe because #{pane_current_path} is absolute; the
    # blast radius is the `state-path [DIR]` diagnostic, answering silently
    # and confidently -- the failure class every rejected alternative lost on.
    it "ignores an exported CDPATH, which cd would otherwise resolve against" do
      decoy = File.join(@dir, "decoy")
      real = File.join(@dir, "proj")
      [File.join(decoy, "proj"), real].each { |dir| FileUtils.mkdir_p(dir) }

      out, _err, status = Open3.capture3(plugin_env.merge("CDPATH" => decoy),
                                         plugin_entry, "state-path", "proj", chdir: @dir)

      expect([out.strip, status.exitstatus]).to eq([state_path(real), 0])
    end

    # The Ruby side of every cross-pin above, built from the SAME env the
    # shell is handed, so neither side can be tuned to agree with the other.
    def ruby_state_path(env)
      Lain::ProjectDir.new(root: @dir, paths: Lain::Paths.new(env: env.compact)).state_path
    end

    it "renders the HUD for a directory by resolving it and handing the file over" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a b], inbox_count: 3)

      expect(render).to eq(["🔥 fleet:2 inbox:3", 0])
    end

    it "renders the honest sentence for a directory whose project has published nothing" do
      expect(render).to eq(["lain: no state yet", 0])
    end

    # The cost of moving the digest here rather than into the POSIX renderer:
    # a machine with no sha256 binary cannot resolve. It must then supply NO
    # path rather than a guessed one -- so the HUD reads "no state yet", which
    # is true, instead of a confident number from the wrong project.
    it "degrades to the honest sentence when no digest binary exists to resolve with" do
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a], inbox_count: 1)

      expect(render(env: plugin_env.merge("PATH" => bin_holding("bash", "jq", "cat")))).to eq(
        ["lain: no state yet", 0]
      )
    end

    # The render path now runs THROUGH this file, so every binary it looks up
    # before its own degrade logic runs is a new way to blank the segment --
    # the exact failure the renderer exists to prevent, and one the old job
    # (which called scripts/lain-status directly, looking nothing up) did not
    # have. `dirname` was such a binary: CURRENT_DIR ran above every guard, so
    # a PATH without it exited 1 with EMPTY stdout rather than degrading.
    # Nothing outside the digest chain may be reachable on PATH now.
    it "renders with no coreutils on PATH beyond the digest tool" do
      skip("jq not found on PATH") unless jq_present?
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a], inbox_count: 1)

      expect(render(env: plugin_env.merge("PATH" => bin_holding("bash", "jq", "sha256sum")))).to eq(
        ["\u{1f525} fleet:1 inbox:1", 0]
      )
    end

    # A digest tool can be ON PATH and still produce nothing: `shasum` is a
    # perl script and dies without perl, a FIPS-restricted `openssl` refuses
    # digests outright. The realpath leg guards its own emptiness and this one
    # did not -- and `set -e` does not cover it, because errexit is suppressed
    # inside `$( )` when the caller tests with `|| return 1`. The answer was
    # `<state_home>/status//state.json` at exit 0: the diagnostic README
    # advertises for "which file is my status bar reading" naming nothing, and
    # naming it confidently.
    it "refuses to answer when a digest tool is present but yields no digest" do
      %w[3 0].each do |code|
        expect(resolve(env: plugin_env.merge("PATH" => bin_with_mute_digest(code)))).to eq(["", 1])
      end
    end

    # A PATH holding exactly the named binaries and nothing else, so each
    # example names the one thing it is taking away. Artificial -- a box with
    # coreutils has sha256sum -- but a box with neither `shasum` nor `openssl`
    # either is the one the degrade path exists for.
    def bin_holding(*names, as: nil)
      bin = File.join(@dir, as || "bin-#{names.join("-")}")
      FileUtils.mkdir_p(bin)
      names.filter_map { |name| which(name) }
           .each { |path| File.symlink(path, File.join(bin, File.basename(path))) }
      bin
    end

    # `sha256sum` is FIRST in the chain, so a shim there is the one the
    # resolver commits to and the later two are never consulted -- which is
    # what makes a mute first tool the interesting case rather than an absent
    # one. Named per exit code so each row of the example gets its own PATH.
    def bin_with_mute_digest(exit_code)
      bin = bin_holding("bash", "jq", "cat", as: "mute-#{exit_code}-bin")
      shim = File.join(bin, "sha256sum")
      File.write(shim, "#!/bin/sh\nexit #{exit_code}\n")
      FileUtils.chmod(0o755, shim)
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
      system(plugin_env, "tmux", "-L", socket, "-f", conf_path, "new-session", "-d", "-s", "hud",
             "-c", @dir, "-x", "80", "-y", "24", out: File::NULL, err: File::NULL) ||
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
    def pane_path(target) = tmux("display-message", "-p", "-t", target, "\#{pane_current_path}")

    # tmux resolves a pane's cwd by reading the /proc entry of the pane's
    # FOREGROUND PROCESS GROUP, at expansion time -- so a pane whose shell has
    # not been made that group yet expands `#{pane_current_path}` to nothing,
    # and nothing is not a visible failure here: the job then carries no path
    # argument at all, `lain.tmux` falls back to `$PWD` (the rspec process's
    # cwd, this repository), and the render is a perfectly honest
    # "lain: no state yet" -- for the WRONG directory. Every example below
    # would then be comparing renders of a project it never wrote state for.
    #
    # Polled, with the deadline as the assertion, exactly like
    # `wait_for_plugin`: `boot` happens to give the "hud" pane that time by
    # accident, but an example that opens its OWN session has none, which is
    # how this reached CI green here and red there.
    def wait_for_pane_cwd(target)
      deadline = Time.now + 5
      sleep(0.05) while Time.now < deadline && pane_path(target).empty?
      raise "pane #{target.inspect} never reported a cwd; the status job would resolve $PWD" \
        if pane_path(target).empty?
    end

    def eval_status_job(target)
      wait_for_pane_cwd(target)
      raw = tmux("show-options", "-gv", "status-right")
      job = raw.strip.delete_prefix("#(").delete_suffix(")")
      expanded = tmux("display-message", "-p", "-t", target, job)
      out, = Open3.capture3(plugin_env, "sh", "-c", expanded)
      out.strip
    end

    # The job now calls the PLUGIN, not the renderer, and that is the whole
    # shape of the split: `#{pane_current_path}` is expanded per pane at render
    # time, so the directory-to-file step has to run then too -- and it runs in
    # the bash entry point, never in the POSIX renderer.
    it "interpolates \#{lain_status} in status-right into a resolver job on the pane's cwd" do
      boot

      status_right = tmux("show-options", "-gv", "status-right")

      expect(status_right).to eq("#('#{plugin_entry}' status \#{q:pane_current_path})")
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
      # Every metacharacter the status job's shell could act on, not just the
      # quote the original regression used: `$(...)` substitution and a
      # backtick both run at expansion time rather than needing the slot to
      # close first, and the split widened this surface by making the job carry a
      # SUBCOMMAND before the path -- so a cwd that escaped the slot would now
      # land as an argument to a program that dispatches on its first word.
      evil = File.join(@dir, "x'; touch #{canary}; :'y $(touch #{canary}) " \
                             "`touch #{canary}` \"q\" $HOME")
      # Created BEFORE its state is written: the identifier is
      # sha256(REALPATH(dir)), and realpath of a directory that is not there
      # yet falls back to the lexical form -- a different hash from the one
      # the resolver will compute once tmux is sitting in it.
      FileUtils.mkdir_p(evil)
      write_state(cache_deadline: (Time.now + 300).utc.iso8601, fleet: %w[a], inbox_count: 1, dir: evil)
      boot
      system("tmux", "-L", socket, "new-session", "-d", "-s", "evil", "-c", evil,
             "-x", "80", "-y", "24", out: File::NULL, err: File::NULL)
      wait_for_pane_cwd("evil")

      rendered = eval_status_job("evil")

      # The half that is about LAIN, and it holds on every tmux: nothing in
      # that cwd ever reached a shell as code.
      expect(File.exist?(canary)).to be false

      # The other half is about TMUX, and tmux 3.4 gets it wrong. It reports
      # `#{pane_current_path}` with a backslash inserted before every `$` -- a
      # pane sitting in `a$b` formats as `a\$b`, while `/proc/<pane_pid>/cwd`,
      # where that pane's shell demonstrably IS, says `a$b`. Fixed upstream by
      # 3.7. Ubuntu 24.04 LTS ships 3.4, so every GitHub runner has it and no
      # developer box does: this example was green here and red there for three
      # runs before the difference was measured rather than guessed at.
      #
      # It cannot be spelled around, because the `$` is the attack: `$(...)`
      # substitution is precisely what this example exists to prove inert. And
      # lain cannot resolve a path tmux misreports -- so where tmux lies, the
      # RIGHT answer is the plugin's honest fallback, and that is what gets
      # pinned. Compared against the pane rather than parsed out of `tmux -V`,
      # because a distro backport makes the version string lie.
      if pane_path("evil") == File.realpath(evil)
        expect(rendered).to eq("🔥 fleet:1 inbox:1")
      else
        expect(rendered).to eq("lain: no state yet")
      end
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
