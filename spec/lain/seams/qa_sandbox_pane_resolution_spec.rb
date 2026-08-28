# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"

# The manual-QA driver helpers are emitted from single-quoted heredocs inside
# `qa-sandbox.sh`, so every line of their pane-resolution rule is literal string
# data: `bash -n` and shellcheck read the GENERATOR and never the rule. That gap
# is why the same defect -- a chat under a shell wrapper contributing no
# candidate, so an ambiguous send looked unambiguous and went to the other chat
# -- was emitted twice. This is the gate that reads the rule itself: generate a
# real sandbox, stand up a real tmux server carrying each pane shape that has
# mattered, and source the real `panes.sh` to ask it what it sees. No model, no
# network, and no chat is started; the question is only which pane a driver
# would aim at.
RSpec.describe "manual-QA sandbox pane resolution", :seam do
  let(:repo) { File.expand_path("../../..", __dir__) }
  let(:generator) { File.join(repo, ".claude/skills/manual-qa/scripts/qa-sandbox.sh") }
  # Unique per run: several agents share this box, so a fixed socket name would
  # drive somebody else's server. An empty `-L` would be worse still -- it
  # resolves to the DEFAULT tmux server, which may be the operator's own.
  let(:token) { "panespec-#{Process.pid}-#{SecureRandom.hex(4)}" }
  # Short on purpose, and it can afford to be: the socket lives inside this
  # run's own TMUX_TMPDIR, so nothing else can collide with it. A descriptive
  # name there blows the 108-byte limit a unix socket path has -- measured, tmux
  # answers "File name too long" and the fixture never comes up.
  let(:socket) { "qa#{SecureRandom.hex(3)}" }
  let(:home) { @home ||= Dir.mktmpdir("qa") }
  # Where the generator puts a sandbox, given that HOME.
  let(:qa) { File.join(home, "tmp", "lain-qa-#{token}") }

  around do |example|
    example.run
  ensure
    Open3.capture3({ "TMUX_TMPDIR" => @home.to_s }, "tmux", "-L", socket, "kill-server")
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  # R5 of the review, in one variable: TMUX_TMPDIR puts the server's socket
  # inside the directory the `ensure` already removes, so a run leaves nothing
  # in the shared /tmp/tmux-$UID tree and cannot collide with the operator's own
  # tmux however the name is spelled.
  def env = { "TMUX_TMPDIR" => home }

  def sh!(*argv, env: {})
    out, err, status = Open3.capture3(env, *argv)
    raise "#{argv.first} failed (#{status.exitstatus}): #{err}#{out}" unless status.success?

    out
  end

  def tmux(*argv) = sh!("tmux", "-L", socket, *argv, env:)

  # tmux prints the id it assigned, so no expectation has to guess %0 from %1.
  # The escape keeps tmux's own format placeholder out of Ruby's interpolation.
  def pane_id_format = "\#{pane_id}"

  def spawn(name, command)
    args = if @session
             ["new-window", "-d", "-n", name]
           else
             @session = true
             ["new-session", "-d", "-s", "panes", "-n", name]
           end
    tmux(*args, "-P", "-F", pane_id_format, command).strip
  end

  # `sleep` rather than `exit`: a pane whose command has died resolves only by
  # accident, and tmux reports it dead rather than reporting its command.
  def write_stub(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "sleep 600\n")
    path
  end

  # The four shapes that have mattered, on one server:
  #   foreground -- a chat as the cockpit really runs one, its launch line
  #                 having ended in `exec`, and with no `lain` in its argv at
  #                 all, which is the degraded launch the resolver must keep.
  #   wrapped    -- a chat that is NOT its pane's foreground process. The defect.
  #   editor     -- nvim, which `peek.sh <n> nvim` has to go on reaching.
  #   wrapeditor -- an editor that is not its pane's foreground process either.
  #                 `peek.sh <n> nvim` asks the same question drive.sh does, and
  #                 a rule that answers it only for the chat has reverted on the
  #                 read side without saying so.
  #   phantom    -- a plain `ruby` backgrounded under a pane's shell, the shape
  #                 this sandbox's own counter.rb/pathcount.rb/proxy.rb take.
  def panes
    @panes ||= begin
      sh!("bash", generator, token, repo, env: { "HOME" => home })
      stub = write_stub(File.join(qa, "stub", "lain"))
      phantom = write_stub(File.join(qa, "phantom.rb"))
      { foreground: spawn("chatfg", "ruby -e 'sleep 600'"),
        wrapped: spawn("wrapped", "sh -c 'ruby #{stub}; sleep 600'"),
        editor: spawn("editor", "nvim -u NONE -n"),
        wrapeditor: spawn("wrapeditor", "sh -c 'nvim -u NONE -n; sleep 900'"),
        phantom: spawn("phantom", "sh -c 'ruby #{phantom} & sleep 600'") }
    end
  end

  # Sourced, never reimplemented: a copy of the rule here would pass while the
  # helper the round actually runs was broken.
  def panes_running(command_name)
    sh!("bash", "-c", <<~SH, env:).split
      set -euo pipefail
      export QA_SOCK=#{socket}
      . #{qa}/panes.sh
      qa_panes_running #{command_name}
    SH
  end

  # tmux answers before a pane's command has execed, so the shapes are not all
  # present the instant `new-window` returns. Poll rather than sleep a guess --
  # and sleep between polls, because a run that is going to fail would otherwise
  # spin `bash` and `tmux` flat out for the whole deadline.
  def settled(command_name, count)
    panes # build the sandbox and the server before asking anything about them
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    found = panes_running(command_name)
    while found.size < count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.2
      found = panes_running(command_name)
    end
    found
  end

  it "counts wrapped chats and editors, keeps the ordinary shapes, and ignores a bare ruby listener" do
    skip "needs tmux and nvim" unless system("command -v tmux >/dev/null 2>&1") &&
                                      system("command -v nvim >/dev/null 2>&1")
    chats = settled("ruby", 2)

    # The defect: the wrapper pane's foreground command is a shell, so a
    # resolver reading only what tmux calls the pane's current command sees one
    # chat where there are two, and sends to the survivor without a word.
    expect(chats).to contain_exactly(panes[:foreground], panes[:wrapped])
    # The narrowing that keeps the fix usable. The phantom's path contains
    # "lain" -- it lives under lain-qa-<tag> -- so a substring test over the
    # descendant's argv would NOT have excluded it, and every send for the rest
    # of a round would refuse.
    expect(chats).not_to include(panes[:phantom])
    # Both aims, or the rule has drifted apart on the side nobody watched:
    # `lain up` always execs nvim into the foreground, so an editor rule that
    # matches only the foreground command passes every cockpit test there is and
    # is still the reverted defect.
    expect(settled("nvim", 2)).to contain_exactly(panes[:editor], panes[:wrapeditor])
  end
end
