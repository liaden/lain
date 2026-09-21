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
# mattered, and run the real helpers against it. No model, no network, and no
# chat is started; the question is only which pane a driver would aim at.
RSpec.describe "manual-QA sandbox pane resolution", :seam do
  let(:repo) { File.expand_path("../../..", __dir__) }
  let(:generator) { File.join(repo, ".claude/skills/manual-qa/scripts/qa-sandbox.sh") }
  # Unique per run: several agents share this box, so a fixed tag would build
  # over somebody else's sandbox and drive their server.
  #
  # Short on purpose, and it has to be: the tag names the socket too (below),
  # the socket lives inside this run's own TMUX_TMPDIR, and a descriptive name
  # there blows the 108-byte limit a unix socket path has -- measured, tmux
  # answers "File name too long" and the fixture never comes up.
  let(:token) { "t#{Process.pid}#{SecureRandom.hex(3)}" }
  # The SANDBOX's own socket name, not an independent one: `drive.sh` and
  # `peek.sh` source the generated `env.sh` and take `QA_SOCK` from there, so a
  # separately named server here would exercise `panes.sh` and nothing that
  # runs it. An empty `-L` would be worse than either -- it resolves to the
  # DEFAULT tmux server, which may be the operator's own.
  let(:socket) { "lain-qa-#{token}" }
  let(:home) { @home ||= Dir.mktmpdir("qa") }
  # Where the generator puts a sandbox, given that HOME.
  let(:qa) { File.join(home, "tmp", "lain-qa-#{token}") }
  # A read has to be tellable from a refusal that printed nothing, so the two
  # panes an aimed read can land on announce themselves on screen. Neither word
  # may contain `lain`: the foreground chat is here to prove the degraded launch
  # still resolves, and a marker with the exe's name in it would prove nothing.
  let(:chat_marker) { "chatpanemarker" }
  let(:editor_marker) { "editorpanemarker" }

  around do |example|
    example.run
  ensure
    Open3.capture3({ "TMUX_TMPDIR" => @home.to_s }, "tmux", "-L", socket, "kill-server")
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  # One variable keeps the whole fixture disposable: TMUX_TMPDIR puts the socket
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

  # The helpers run exactly as a round runs them -- as scripts, sourcing the
  # generated env.sh for themselves -- because how they resolve QA_SOCK and the
  # pin is part of what is under test. A refusal is an expected outcome here, so
  # this one hands back the status rather than raising on it.
  def helper(name, *args, vars: {})
    Open3.capture3(env.merge(vars), "bash", File.join(qa, name), *args)
  end

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

  # The sandbox and the server it will be asked about, built once per example.
  def panes
    @panes ||= begin
      sh!("bash", generator, token, repo, env: { "HOME" => home })
      build_panes(write_stub(File.join(qa, "stub", "lain")), write_stub(File.join(qa, "phantom.rb")))
    end
  end

  # The shapes that have mattered, on one server:
  #   foreground -- a chat as the cockpit really runs one, its launch line
  #                 having ended in `exec`, and with no `lain` in its argv at
  #                 all, which is the degraded launch the resolver must keep.
  #   wrapped    -- a chat that is NOT its pane's foreground process. The defect.
  #                 It is `lain chat` by argv, because the lain exe alone no
  #                 longer qualifies: the cockpit's input pane is the lain exe too.
  #   input      -- that input pane's shape: `lain input`, wrapped the same way.
  #                 It is not a chat, and counting it made every stock cockpit
  #                 ambiguous. Wrapped so the only thing excluding it is argv.
  #   editor     -- nvim, which `peek.sh <n> nvim` has to go on reaching.
  #   wrapeditor -- an editor that is not its pane's foreground process either.
  #                 `peek.sh <n> nvim` asks the same question drive.sh does, and
  #                 a rule that answers it only for the chat has reverted on the
  #                 read side without saying so.
  #   phantom    -- a plain `ruby` backgrounded under a pane's shell, the shape
  #                 this sandbox's own counter.rb/pathcount.rb/proxy.rb take.
  # Two of each kind is not padding either: it is what makes a pin load-bearing,
  # since resolution alone can only refuse.
  def build_panes(stub, phantom)
    { foreground: spawn("chatfg", %(ruby -e 'puts "#{chat_marker}"; sleep 600')),
      wrapped: spawn("wrapped", "sh -c 'ruby #{stub} chat; sleep 600'"),
      input: spawn("input", "sh -c 'ruby #{stub} input; sleep 600'"),
      editor: spawn("editor", "nvim -u NONE -n #{marked_document}"),
      wrapeditor: spawn("wrapeditor", "sh -c 'nvim -u NONE -n; sleep 900'"),
      phantom: spawn("phantom", "sh -c 'ruby #{phantom} & sleep 600'") }
  end

  # A word no other pane on this server can put on screen, so a read of the
  # editor is tellable from a read of something else that merely succeeded.
  def marked_document
    File.join(qa, "editor.txt").tap { |path| File.write(path, "#{editor_marker}\n") }
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
  def poll_panes(command_name)
    panes # build the sandbox and the server before asking anything about them
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    found = panes_running(command_name)
    while !yield(found) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.2
      found = panes_running(command_name)
    end
    found
  end

  def settled(command_name, count) = poll_panes(command_name) { |found| found.size >= count }

  # A killed window is not gone the instant tmux returns either, and an example
  # about the empty case has to know the emptiness is the one it arranged.
  def drained(command_name) = poll_panes(command_name, &:empty?)

  # An exclusion is evidence only once the excluded process exists; before it
  # has execed, a resolver that would count it has nothing to count yet.
  def await_process(pattern)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    sleep 0.2 until system("pgrep", "-f", pattern, out: File::NULL) ||
                    Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  end

  def tooling? = system("command -v tmux >/dev/null 2>&1") && system("command -v nvim >/dev/null 2>&1")

  it "counts wrapped chats and editors, keeps the ordinary shapes, and ignores a bare ruby listener" do
    skip "needs tmux and nvim" unless tooling?
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
    # The other half of the discriminator: the input pane is the lain exe too,
    # and a rule that asks only "is it lain" calls every stock cockpit ambiguous.
    await_process("#{qa}/stub/lain input$")
    expect(panes_running("ruby")).to contain_exactly(panes[:foreground], panes[:wrapped])
    # Both aims, or the rule has drifted apart on the side nobody watched:
    # `lain up` always execs nvim into the foreground, so an editor rule that
    # matches only the foreground command passes every cockpit test there is and
    # is still the reverted defect.
    expect(settled("nvim", 2)).to contain_exactly(panes[:editor], panes[:wrapeditor])
  end

  it "refuses a pin that names a pane of the kind peek.sh was NOT asked for" do
    skip "needs tmux and nvim" unless tooling?
    settled("ruby", 2)
    settled("nvim", 2)

    pin = { "LAIN_QA_PANE" => panes[:foreground] }
    out, err, status = helper("peek.sh", "20", "nvim", vars: pin)

    # The pin used to be taken before the chat/nvim argument was read at all, so
    # this call came back with the CHAT's screen at exit 0 -- a reading of the
    # wrong surface with nothing about it that looked wrong.
    expect(out).not_to include(chat_marker)
    # The exact code, not merely "not success": a pin path that died for an
    # unrelated reason would satisfy the weaker expectation while the gate this
    # example exists for was gone.
    expect(status.exitstatus).to eq(2)
    # And it has to say which pane and what the alternatives were, or the driver
    # cannot re-aim without going back to tmux by hand.
    expect(err).to include(panes[:foreground], panes[:editor])

    # The same defect one typo away, now that the kind decides the query: an
    # unknown kind word used to fall through to `chat`, so `peek.sh 20 editor`
    # under a chat pin read the chat and said nothing.
    typo_out, _typo_err, typo = helper("peek.sh", "20", "editor", vars: pin)
    expect(typo_out).not_to include(chat_marker)
    expect(typo.exitstatus).to eq(2)

    # The liveness check the kind check was built beside, which now shares one
    # membership predicate with it and with drive.sh's.
    expect(helper("peek.sh", "20", vars: { "LAIN_QA_PANE" => "%99" }).last.exitstatus).to eq(1)
  end

  it "refuses a live pin with nowhere to re-aim, and says how to read that pane raw" do
    skip "needs tmux and nvim" unless tooling?
    settled("nvim", 2)
    settled("ruby", 2)
    [panes[:editor], panes[:wrapeditor]].each { |pane| tmux("kill-window", "-t", pane) }
    expect(drained("nvim")).to be_empty

    out, err, status = helper("peek.sh", "20", "nvim", vars: { "LAIN_QA_PANE" => panes[:foreground] })

    expect(out).to be_empty
    expect(status.exitstatus).to eq(2)
    expect(err).to include("no nvim pane here at all")
    # This arm has no other pane to offer, and a pane the resolver cannot
    # classify at all lands on it -- so without a remedy of its own, a driver
    # who is right and a resolver that is wrong end in a standoff. The pin is
    # what just failed, so the remedy cannot be another pin.
    expect(err).to include("capture-pane -p -t #{panes[:foreground]}")
  end

  it "honours a pin for the kind it does name, on both kinds" do
    skip "needs tmux and nvim" unless tooling?
    settled("ruby", 2)
    settled("nvim", 2)

    # Ambiguous without the pin, both ways: which is what a pin is FOR, and
    # what makes the two reads below evidence rather than coincidence.
    expect(helper("peek.sh", "20").last).not_to be_success
    expect(helper("peek.sh", "20", "nvim").last).not_to be_success

    chat, = helper("peek.sh", "20", vars: { "LAIN_QA_PANE" => panes[:foreground] })
    # A whole screen's worth of lines, not the 20 the other reads take: an empty
    # nvim fills every row it is not using with a `~`, which `peek.sh` counts as
    # content, so a short tail returns the bottom of the tildes and nothing of
    # the buffer -- the same "plausible text" trap in miniature.
    editor, = helper("peek.sh", "60", "nvim", vars: { "LAIN_QA_PANE" => panes[:editor] })

    expect(chat).to include(chat_marker)
    expect(editor).to include(editor_marker)
  end

  it "leaves drive.sh's pin as it was: checked for liveness, and still overriding an ambiguous send" do
    skip "needs tmux and nvim" unless tooling?
    settled("ruby", 2)
    journal = File.join(qa, "records", "journal.ndjson")
    File.write(journal, "{}\n")
    text = "sent-by-the-pane-resolution-spec"
    # Short quiet/max windows: nothing is going to write to that journal, so the
    # wait is pure overhead and its only job here is to terminate.
    args = ["drive.sh", text, "3", "15"]

    expect(helper(*args, vars: { "LAIN_QA_JOURNAL" => journal }).last.exitstatus).to eq(2)
    expect(helper(*args, vars: { "LAIN_QA_JOURNAL" => journal,
                                 "LAIN_QA_PANE" => "%99" }).last.exitstatus).to eq(1)

    out, _err, status = helper(*args, vars: { "LAIN_QA_JOURNAL" => journal,
                                              "LAIN_QA_PANE" => panes[:foreground] })

    expect(status).to be_success
    expect(out).to include("pane #{panes[:foreground]}")
    # The send landed where it was aimed and nowhere else -- the other chat
    # candidate is the pane an unpinned `head -1` used to pick.
    expect(tmux("capture-pane", "-p", "-t", panes[:foreground])).to include(text)
    expect(tmux("capture-pane", "-p", "-t", panes[:wrapped])).not_to include(text)
  end

  it "sends to the pane the cockpit records as its input and reads the one it records as its chat" do
    skip "needs tmux and nvim" unless tooling?
    settled("ruby", 2)
    journal = File.join(qa, "records", "journal.ndjson")
    File.write(journal, "{}\n")
    text = "sent-to-the-recorded-input-pane"
    args = ["drive.sh", text, "3", "15"]
    vars = { "LAIN_QA_JOURNAL" => journal }

    # Ambiguous to the resolver, so what follows is the options answering.
    expect(helper(*args, vars:).last.exitstatus).to eq(2)
    expect(helper("peek.sh", "20").last.exitstatus).to eq(2)

    # What `lain up` records on the session it builds. The input pane is not a
    # resolver candidate at all, so a send landing there came from the option.
    tmux("set-option", "-t", "panes", "@lain_input_pane", panes[:input])
    tmux("set-option", "-t", "panes", "@lain_chat_pane", panes[:foreground])

    out, _err, status = helper(*args, vars:)
    expect(status).to be_success
    expect(out).to include("pane #{panes[:input]}")
    expect(tmux("capture-pane", "-p", "-t", panes[:input])).to include(text)
    # A send to the chat pane is swallowed in a real cockpit, silently.
    expect(tmux("capture-pane", "-p", "-t", panes[:foreground])).not_to include(text)

    read, _err, read_status = helper("peek.sh", "20")
    expect(read_status).to be_success
    expect(read).to include(chat_marker)
  end
end
