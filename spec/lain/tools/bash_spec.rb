# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::Bash do
  subject(:tool) { described_class.new }

  let(:channel) { RecordingChannel.new }

  def invocation(tool_use_id: "tu_1")
    Lain::Tool::Invocation.new(tool_use_id:, channel:)
  end

  it "runs a command and captures its stdout" do
    result = tool.call({ command: "echo hello" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 0")
    expect(result.content).to include("hello")
  end

  it "captures stderr alongside stdout" do
    result = tool.call({ command: "echo oops 1>&2" }, invocation)
    expect(result.content).to include("oops")
  end

  it "reports a nonzero exit status in the content, not as is_error" do
    # A nonzero exit is often exactly what the model asked to observe (grep
    # with no matches); the tool ran correctly, so this is not a tool failure.
    # `sh -c` in the command keeps this on the STRING arm -- Shell::Verdict
    # abstains on `sh` -- which is where `exit` is a builtin that works.
    result = tool.call({ command: %(sh -c "exit 3") }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 3")
  end

  it "reports a nonzero exit status from the term arm too" do
    result = tool.call({ command: "grep -q lain-no-such-pattern /dev/null" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 1")
  end

  it "runs in the given cwd" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "marker.txt"), "here")
      result = tool.call({ command: "ls", cwd: dir }, invocation)
      expect(result.content).to include("marker.txt")
    end
  end

  describe "timeout" do
    # The real process-group kill, end to end: TERM actually hits a live
    # `sleep 5` group and mixlib reaps it. The injected factory only shortens
    # the TERM->KILL grace -- mixlib-shellout hardcodes `sleep 3` inside
    # reap_errant_child with no option to configure it, and 3 idle seconds
    # would dominate the whole suite's runtime.
    #
    # `sh -c` keeps this on the STRING arm, which is the arm mixlib owns; a bare
    # `sleep 5` is literal and would be run as a term.
    it "kills a command that runs past its timeout" do
      short_grace = lambda do |*args, **opts|
        Mixlib::ShellOut.new(*args, **opts).tap do |shell_out|
          def shell_out.sleep(_grace) = super(0.1)
        end
      end

      result = described_class.new(exec: Lain::Exec::Local.new(shell_out_factory: short_grace))
                              .call({ command: %(sh -c "sleep 5"), timeout: 1 }, invocation)
      expect(result).to be_error
      expect(result.content).to include("timed out")
    end

    # The same posture on the term arm: a Shell::Pipeline::Timeout is an error
    # Result naming the timeout, exactly as mixlib's CommandTimeout is, because
    # a timeout is the tool failing to produce a result rather than a command
    # exiting non-zero.
    it "kills a term that runs past its timeout" do
      backend = Lain::Exec::Local.new(pipeline: Lain::Shell::Pipeline.new(grace: 0.1),
                                      shell_out_factory: ->(*, **) { raise "the term arm must not reach a shell" })
      tool = described_class.new(exec: backend)

      result = tool.call({ command: "sleep 5", timeout: 1 }, invocation)
      expect(result).to be_error
      expect(result.content).to include("timed out after 1s")
    end

    # The rescue->Result mapping in isolation: no subprocess, no clock.
    it "maps CommandTimeout to an error Result naming the timeout" do
      timed_out = Class.new do
        def run_command = raise Mixlib::ShellOut::CommandTimeout, "Command timed out after 7s"
      end
      tool = described_class.new(exec: Lain::Exec::Local.new(shell_out_factory: ->(*, **) { timed_out.new }))

      result = tool.call({ command: %(sh -c "sleep 5"), timeout: 7 }, invocation)
      expect(result).to be_error
      expect(result.content).to include("timed out after 7s")
    end
  end

  describe "attributed live streaming" do
    it "emits stdout bytes as Telemetry::ToolOutput carrying the invocation's tool_use_id and stream" do
      tool.call({ command: "echo from_stdout" }, invocation(tool_use_id: "tu_abc"))

      stdout_events = channel.events.select { |e| e.stream == :stdout }
      expect(stdout_events).not_to be_empty
      expect(stdout_events).to all(be_a(Lain::Telemetry::ToolOutput))
      expect(stdout_events).to all(have_attributes(tool_use_id: "tu_abc"))
      expect(stdout_events.map(&:bytes).join).to include("from_stdout")
    end

    it "emits stderr bytes on the :stderr stream, distinct from stdout" do
      tool.call({ command: "echo to_err 1>&2" }, invocation(tool_use_id: "tu_xyz"))

      stderr_events = channel.events.select { |e| e.stream == :stderr }
      expect(stderr_events).not_to be_empty
      expect(stderr_events).to all(have_attributes(tool_use_id: "tu_xyz"))
      expect(stderr_events.map(&:bytes).join).to include("to_err")
    end
  end

  it "does nothing observable when no channel is injected (Null Object default)" do
    bare = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect { tool.call({ command: "echo quiet" }, bare) }.not_to raise_error
  end

  # The WorkerEnv the Session lends: the default is byte-identical to today
  # (process ENV + Dir.pwd), an injected one isolates env and cwd.
  describe "worker env (session-lent env and cwd)" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session, channel:)
    end

    it "inherits the process env under the default WorkerEnv" do
      ENV["LAIN_WE_PROBE"] = "from_process"
      result = tool.call({ command: "echo $LAIN_WE_PROBE" }, invocation_with(Lain::Session.new))
      expect(result.content).to include("from_process")
    ensure
      ENV.delete("LAIN_WE_PROBE")
    end

    it "exposes an injected env var to the command" do
      env = ENV.to_h.merge("DATABASE_URL" => "postgres://sandbox/db")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env:))
      result = tool.call({ command: "echo $DATABASE_URL" }, invocation_with(session))
      expect(result.content).to include("postgres://sandbox/db")
    end

    it "runs in the WorkerEnv cwd when the input names none" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "marker.txt"), "here")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        result = tool.call({ command: "ls" }, invocation_with(session))
        expect(result.content).to include("marker.txt")
      end
    end

    it "resolves a relative input cwd against the WorkerEnv cwd" do
      Dir.mktmpdir do |dir|
        Dir.mkdir(File.join(dir, "sub"))
        File.write(File.join(dir, "sub", "inner.txt"), "x")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        result = tool.call({ command: "ls", cwd: "sub" }, invocation_with(session))
        expect(result.content).to include("inner.txt")
      end
    end

    # WorkerEnv is an OVERRIDE, not confinement: mixlib applies
    # `environment:` per-key onto the child's already-inherited ENV and never
    # clears it, so a host var the injected env omits still reaches the command.
    # This pins that true behavior -- probe tmp/b1-probes/env_semantics.rb.
    it "leaks a host env var the injected WorkerEnv omits (additive override, not confinement)" do
      ENV["LAIN_HOST_ONLY"] = "leaked"
      curated = { "DATABASE_URL" => "postgres://sandbox" } # deliberately omits LAIN_HOST_ONLY
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: curated))

      result = tool.call({ command: "echo host=[$LAIN_HOST_ONLY]" }, invocation_with(session))

      expect(result.content).to include("host=[leaked]")
    ensure
      ENV.delete("LAIN_HOST_ONLY")
    end

    # The sanctioned scrub: an explicit nil VALUE (not an absent key) removes a
    # var, because mixlib's child does `ENV[k] = nil`, and Ruby's `ENV[k] = nil`
    # deletes. WorkerEnv preserves the nil marker through make_shareable.
    it "scrubs a host env var mapped to nil in the injected WorkerEnv" do
      ENV["LAIN_SCRUB_ME"] = "leaked"
      scrubbed = ENV.to_h.merge("LAIN_SCRUB_ME" => nil)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: scrubbed))

      result = tool.call({ command: "echo host=[$LAIN_SCRUB_ME]" }, invocation_with(session))

      expect(result.content).to include("host=[]")
    ensure
      ENV.delete("LAIN_SCRUB_ME")
    end

    it "runs a TERM in the WorkerEnv's cwd and environment" do
      Dir.mktmpdir do |dir|
        env = ENV.to_h.merge("LAIN_TERM_PROBE" => "from_worker_env")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env:))

        expect(tool.call({ command: "pwd" }, invocation_with(session)).content).to include(File.realpath(dir))
        expect(tool.call({ command: "printenv LAIN_TERM_PROBE" }, invocation_with(session)).content)
          .to include("from_worker_env")
      end
    end

    # End to end through the tool the model actually calls. lain runs under
    # `bundle exec`, so WorkerEnv.default carries BUNDLE_GEMFILE naming LAIN's
    # own Gemfile -- and a child that inherits it resolves lain's bundle instead
    # of the project it was pointed at. Lain::Exec is where that is taken away;
    # these examples pin that the tool goes through it.
    describe "lain's own toolchain is not lent to the command" do
      it "reports no BUNDLE_GEMFILE, though this process carries one" do
        with_env("BUNDLE_GEMFILE" => "/home/tara/dev/lain/Gemfile") do
          result = tool.call({ command: %(sh -c 'echo "[$BUNDLE_GEMFILE]"') },
                             invocation_with(Lain::Session.new))

          expect(result.content).to include("[]")
        end
      end

      it "takes the whole framework family away, not one variable" do
        family = { "BUNDLE_GEMFILE" => "/lain/Gemfile", "BUNDLER_SETUP" => "/lain/setup.rb",
                   "RUBYOPT" => "-rbundler/setup", "RSPEC_OPTS" => "--seed 1" }

        with_env(family) do
          result = tool.call({ command: %(sh -c 'env | grep -E "^(BUNDLE_|BUNDLER_|RSPEC_|RUBYOPT=)"; echo scanned') },
                             invocation_with(Lain::Session.new))

          expect(result.content).to include("--- stdout ---\nscanned\n")
        end
      end

      it "still delivers a variable the session deliberately lent" do
        env = ENV.to_h.merge("LAIN_LENT" => "on loan")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env:))

        result = tool.call({ command: %(sh -c 'echo "[$LAIN_LENT]"') }, invocation_with(session))

        expect(result.content).to include("[on loan]")
      end

      it "keeps GEM_HOME, because the command still has to find its gems" do
        with_env("GEM_HOME" => "/tmp/lain-t1-gems") do
          result = tool.call({ command: %(sh -c 'echo "[$GEM_HOME]"') },
                             invocation_with(Lain::Session.new))

          expect(result.content).to include("[/tmp/lain-t1-gems]")
        end
      end
    end
  end

  # Which arm ran is a decision of Shell::Verdict's, and the tool's job is to
  # make it invisible in the result. These examples pin the choice, not the
  # execution -- Shell::Pipeline's own spec owns what a term does once chosen.
  describe "choosing an arm" do
    # A verdict stand-in that abstains on everything, which is how a command the
    # real verdict would ALLOW can be run through the string arm for comparison.
    let(:abstaining) do
      ->(_command) { Lain::Shell::Verdict::Decision.new(name: :abstain, reason: "pinned", term: []) }
    end

    let(:no_shell) { ->(*, **) { raise "a shell was spawned" } }

    it "runs an allowed command as a term, with no shell process at all" do
      result = described_class.new(exec: Lain::Exec::Local.new(shell_out_factory: no_shell))
                              .call({ command: "printf hi" }, invocation)

      expect(result).to be_ok
      expect(result.content).to include("exit status: 0", "hi")
    end

    # The dispatch half of the card's misparse scenario. `time { echo PWNED; }`
    # is broken=false and fully covered -- neither the node-kind tier nor the
    # byte-coverage backstop sees anything -- so it abstains via the program-
    # runner denylist and reaches the STRING arm and the gate above it, exactly
    # as it does today. What the reconstructed argv would have done instead is
    # pinned in spec/lain/shell/pipeline_spec.rb.
    it "sends an abstained command to the shell arm, as the original string" do
      seen = []
      recording = lambda do |command, **opts|
        seen << command
        Mixlib::ShellOut.new("true", **opts)
      end

      tool = described_class.new(exec: Lain::Exec::Local.new(shell_out_factory: recording))
      tool.call({ command: "time { echo PWNED; }" }, invocation)
      tool.call({ command: "echo $(id)" }, invocation)

      expect(seen).to eq(["time { echo PWNED; }", "echo $(id)"])
    end

    # The flag describes the TOOL, which still takes a string the model wrote.
    # A term arm is not a reason to flip it; which CALLS may skip a human is the
    # escalation ladder's question, asked per call.
    it "still declares that it requires approval" do
      expect(tool.requires_approval?).to be(true)
    end

    # Byte-identity is what keeps the term arm a transparent optimization rather
    # than a behavior change: same exit status, same stdout, same stderr, same
    # encoding, through the one shared template.
    #
    # WHAT HOLDS IT UP IS ONE LINE, `Exec::Local#takes_term?` answering true for
    # every term: nothing that reaches the term arm here can fall back to the
    # string arm, so the two arms never run one command two ways. Narrowing that
    # answer -- a subclass saying `term.size == 1` is enough -- sends
    # `cat README.md | head -20` down the string arm on a term-capable backend
    # and this comparison stops being about the same execution at all.
    it "renders byte-identical content on either arm" do
      ["printf hi", "grep -q lain-no-such-pattern /dev/null", "cat /nonexistent/lain/probe",
       "ls -d ."].each do |command|
        term = described_class.new.call({ command: }, invocation)
        string = described_class.new(verdict: abstaining).call({ command: }, invocation)

        expect(term.content).to eq(string.content), command
        expect(term.content.encoding).to eq(string.content.encoding), command
        expect(term.is_error).to eq(string.is_error), command
      end
    end

    # The one measured divergence, pinned rather than hidden: a shell BUILTIN
    # has no binary to exec, so the term arm reports 127 where `sh -c` exits 3.
    # Implementing builtins would make Shell::Pipeline a shell, and re-running
    # the string after an allow would surrender the property the term arm exists
    # for -- so this is the honest outcome, and a reader meets it here.
    it "answers a shell builtin with command-not-found on the term arm" do
      expect(tool.call({ command: "exit 3" }, invocation).content).to include("exit status: 127", "exit")
      expect(described_class.new(verdict: abstaining).call({ command: "exit 3" }, invocation).content)
        .to include("exit status: 3")
    end
  end

  # Not every backend has a shape for every term -- a container takes one argv,
  # the daemon takes none -- so the tool ASKS before it offers one. The fallback
  # is the string the model itself wrote, which on such a backend is the only
  # arm that command ever had; this tool still never composes a string out of a
  # term it was given.
  describe "asking the backend whether it can take the term" do
    # A real Exec::Local whose two arms both record the shape they were handed,
    # so which arm ran is read from the backend rather than inferred from the
    # result -- the rendering deliberately makes the arms indistinguishable.
    def recording_local
      seen = []
      pipeline = lambda do |term, **|
        seen << term
        Lain::Shell::Pipeline::Result.new(exit_status: 0, stdout: "", stderr: "")
      end
      factory = lambda do |command, **options|
        seen << command
        Mixlib::ShellOut.new("true", **options)
      end
      [Lain::Exec::Local.new(pipeline:, shell_out_factory: factory), seen]
    end

    # A REAL Exec::Docker -- the predicate and the refusal under test are its
    # own -- with only the docker client's spawn recorded, so these examples
    # need no container and no client on PATH.
    def recording_docker
      inner = Class.new do
        attr_reader :command

        def call(command:, **)
          @command = command
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end
      end.new
      [Lain::Exec::Docker.new(project: Dir.pwd, image: "img:1", exec: inner,
                              prober: ->(_timeout) { "Docker version 27.3.1" }), inner]
    end

    # What the container is asked to run, at the tail of the client's argv.
    def entrypoint(inner) = inner.command.first.last(3)

    it "hands the term to a backend that takes any term" do
      backend, seen = recording_local

      described_class.new(exec: backend).call({ command: "cat README.md | head -20" }, invocation)

      expect(seen).to eq([[%w[cat README.md], %w[head -20]]])
    end

    # The user-visible win: `--exec docker` stops erroring on an ordinary
    # pipeline. What reaches the container is what the model wrote, byte for
    # byte, because the fallback is the input string and never a rejoined term.
    it "hands the model's own string to a backend that takes only a one-stage term" do
      backend, inner = recording_docker
      command = "grep -r foo . | wc -l"

      result = described_class.new(exec: backend).call({ command: }, invocation)

      expect(result).to be_ok
      expect(entrypoint(inner)).to eq(["sh", "-c", command])
      expect(entrypoint(inner).last.encoding).to eq(command.encoding)
    end

    it "still offers a one-stage term to that backend, which has a shape for one" do
      backend, inner = recording_docker

      described_class.new(exec: backend).call({ command: "ls -la" }, invocation)

      expect(inner.command.first.last(3)).to eq(["img:1", "ls", "-la"])
    end

    # An abstention produces no term to offer, so the predicate is never
    # consulted and every backend sees the string the model wrote.
    it "runs an abstained command as the string, whatever the backend can take" do
      backend, seen = recording_local
      docker, inner = recording_docker

      described_class.new(exec: backend).call({ command: "echo a && echo b" }, invocation)
      described_class.new(exec: docker).call({ command: "echo a && echo b" }, invocation)

      expect(seen).to eq(["echo a && echo b"])
      expect(entrypoint(inner)).to eq(["sh", "-c", "echo a && echo b"])
    end

    # Through the floor `--exec docker` really builds, because the seam that
    # matters is the one a session assembles rather than the one a spec does.
    it "runs an ordinary pipeline through the tool floor --exec docker builds" do
      docker, inner = recording_docker
      floor = Lain::CLI::Wiring::BaseTools.build(Lain::Memory::Recorder.new, exec: docker)

      result = floor.find { |tool| tool.name == "bash" }
                    .call({ command: "grep -r foo . | wc -l" }, invocation)

      expect(result).to be_ok
      expect(entrypoint(inner)).to eq(["sh", "-c", "grep -r foo . | wc -l"])
    end
  end

  # The description and the command field are the only channel that reaches
  # every consumer of this tool, and they are what the model reads to decide
  # what to send. Two arms run a command here, so prose promising `sh -c`
  # outright is false for every command Shell::Verdict allows -- and the shape
  # that earns the shell-free arm is something the model has no other way to
  # learn. These examples hold the prose to the code by asking the real verdict
  # rather than by restating its rule.
  describe "what the model is told about the two arms" do
    let(:command_field) { tool.input_schema.dig("properties", "command", "description") }

    it "conditions the shell on the command not being fully understood" do
      expect(tool.description).to include("fully understood")
      expect(tool.description).not_to include("Runs a shell command via `sh -c`")
    end

    # An allow is not on its own enough -- #arm_for asks takes_term? too, and
    # Exec::Docker refuses a multi-stage term. Both halves of the request carry
    # that caveat, so neither can be read alone and come away with the property
    # that is kept but not the one that is surrendered.
    it "carries the backend caveat in its own half, not only on the shared field" do
      expect(tool.description).to include("wherever the backend running it takes argv")
      expect(command_field).to include("wherever the backend running it takes argv")
    end

    it "names the shape that earns the shell-free arm, on the shared command field" do
      expect(command_field).to include("literal", "pipes", "cat README.md | head -20")
    end

    it "names the constructs that lose it" do
      expect(command_field).to include("more than one line", "&&", "||", "redirection", "globs", "git", "sudo")
    end

    # The rule the list generalises over is itself a claim the model reasons
    # from, and it takes TWO arms: a program can reach the shell arm by running
    # something its own arguments name, or by having a documented escape into a
    # shell. Naming only the first made the prose wrong about `less`, which is
    # one of the second.
    it "states both reasons a program loses the shell-free arm" do
      expect(command_field).to include("run a program named in its own arguments",
                                       "drop the user into a shell")
    end

    it "advertises only shapes the verdict really allows" do
      decisions = ["ls -la", "cat README.md | head -20", "grep -rn foo lib | wc -l"]
                  .map { |command| Lain::Shell::Verdict.new.call(command) }

      expect(decisions).to all(be_allow)
      expect(decisions[1].term).to eq([%w[cat README.md], %w[head -20]])
    end

    it "warns off constructs the verdict really abstains on" do
      warned = ["echo a && echo b", "echo a || echo b", "echo a ; echo b", "sleep 1 &",
                %(echo "hello world"), "echo foo\\ bar", "echo hi > out.txt", "echo $HOME",
                "ls *.rb", "echo ~/x", "echo a\necho b",
                "git log --oneline -5", "tar -cf x.tar dir", "rsync -a a b",
                "python3 script.py", "sudo ls", "less README.md"]

      expect(warned.map { |command| Lain::Shell::Verdict.new.call(command) }).to all(be_abstain)
    end

    # "More than one line" and not "no newlines": a TRAILING newline still
    # allows, so the stricter wording would have been a fresh false claim.
    it "still allows a single command carrying a trailing newline" do
      expect(Lain::Shell::Verdict.new.call("ls -la\n")).to be_allow
    end

    # Every program the prose names, measured -- the lesson from the wording
    # that was wrong about its own example. The list is held here rather than
    # scraped from the string, so it pins the prose against the verdict in the
    # direction that matters: a name that stops abstaining reds, and so does a
    # name deleted from the description.
    it "names only programs the verdict really abstains on" do
      named = %w[git tar rsync sudo less vim man psql sh python awk]
      commands = ["git status", "tar -cf x.tar dir", "rsync -a a b", "sudo ls", "less README.md",
                  "vim README.md", "man ls", "psql -c select", "sh script.sh", "python script.py",
                  "awk BEGIN"]

      expect(named.all? { |program| command_field.include?(program) }).to be(true)
      expect(commands.map { |command| Lain::Shell::Verdict.new.call(command) }).to all(be_abstain)
    end

    # The family the corrected clause generalises over. None of these is named
    # in the description, so they are what proves the RULE carries rather than
    # the list -- a model reasoning from "can drop the user into a shell"
    # reaches the right answer for each.
    it "generalises correctly to the escape-capable programs it does not name" do
      unnamed = ["nano README.md", "more README.md", "info coreutils", "sqlite3 db.sqlite",
                 "vi README.md", "nvim README.md", "ed README.md", "emacs README.md",
                 "most README.md", "mysql -e select"]

      expect(unnamed.map { |command| Lain::Shell::Verdict.new.call(command) }).to all(be_abstain)
    end
  end

  # A command's output is a whole artifact -- its first N bytes read like
  # the answer and are not -- so an oversized one is REFUSED, and the refusal
  # keeps the one fact truncation would have kept: the exit status.
  #
  # The bound lives in .render_output because that is the single rendering every
  # exec arm goes through, in process and over the daemon alike, so it cannot be
  # applied to one arm and missed on another.
  describe "refusing output too large to hand back" do
    let(:ceiling) { Lain::Tools::Bash::OUTPUT_BOUND.limit }
    let(:oversized_file) do
      File.join(@tmpdir, "big.txt").tap { |path| File.write(path, "x" * (ceiling + 1024)) }
    end
    let(:abstaining) do
      ->(_command) { Lain::Shell::Verdict::Decision.new(name: :abstain, reason: "pinned", term: []) }
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    # `tr` over /dev/zero rather than `yes | head`: an exact byte count, and no
    # SIGPIPE race to make the size depend on scheduling.
    def flooding(bytes, char = "x") = "head -c #{bytes} /dev/zero | tr '\\0' #{char}"

    it "refuses output over the ceiling, naming its size and the ceiling" do
      result = tool.call({ command: flooding(ceiling + 1024) }, invocation)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include((ceiling + 1024).to_s, ceiling.to_s)
    end

    it "keeps the exit status a refused command reported" do
      result = tool.call({ command: "#{flooding(ceiling + 1024)}; exit 3" }, invocation)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("exit status: 3")
    end

    it "carries none of the refused output" do
      result = tool.call({ command: flooding(ceiling + 1024, "S") }, invocation)

      expect(result.content).not_to include("SS")
    end

    it "names a narrower action rather than leaving the model to re-run it" do
      content = tool.call({ command: flooding(ceiling + 1024) }, invocation).content

      expect(content).to match(/head|tail|grep/)
      expect(content).to include("read_file")
    end

    it "counts stdout and stderr together, since both ride the one result" do
      half = (ceiling / 2) + 1024
      command = "#{flooding(half)}; #{flooding(half, "y")} 1>&2"

      expect(tool.call({ command: }, invocation)).to have_attributes(is_error: true)
    end

    it "leaves output under the ceiling untouched" do
      result = tool.call({ command: flooding(1024) }, invocation)

      expect(result).to be_ok
      expect(result.content).to include("exit status: 0", "x" * 1024)
    end

    # The reason the bound is in .render_output rather than in either
    # arm: the same oversized command through the term arm and the string arm
    # must refuse with the same bytes, exactly as a permitted one returns the
    # same bytes (the byte-identity example above).
    it "refuses byte-identically on either arm" do
      command = "cat #{oversized_file}"

      term = described_class.new.call({ command: }, invocation)
      string = described_class.new(verdict: abstaining).call({ command: }, invocation)

      expect(term.content).to eq(string.content)
      expect(term.content.encoding).to eq(string.content.encoding)
      expect(term.is_error).to eq(string.is_error)
      expect(term).to have_attributes(is_error: true)
    end

    # The daemon arm reaches the same ceiling because it reaches the same
    # method: the wire's fields render through this one entry point, so there is
    # no second place for the bound to be missing from.
    it "refuses through the shared rendering the daemon arm also calls" do
      rendered = described_class.render_output(exit_status: 3, stdout: "x" * (ceiling + 1), stderr: "")

      expect(rendered).to have_attributes(is_error: true)
      expect(rendered.content).to include("exit status: 3", (ceiling + 1).to_s)
    end
  end

  # Which arm ran is a decision this tool makes on every call, and until now
  # nothing wrote it down where no ladder ran: the gate journals a `shell
  # verdict` line from inside its escalation record, but `/mode auto` resolves
  # the gate to ApproveAll, which consults no rung. So the tool records the
  # decision itself, on both arms -- an abstention that went through `sh -c` is
  # as much a datapoint as an allow that ran as argv.
  # The one message that exposes this tool's verdict. The approval ladder's
  # rules rung fetches the tool the executor would dispatch and asks it, which
  # is how Approval::Rule::Call#term reaches a parse without the approval
  # namespace constructing a Shell::Verdict of its own.
  describe "the parse it offers a caller that must decide about a call" do
    it "answers the arm, its reason and the term for an input it would run" do
      input = described_class::Input.build({ "command" => "cat README.md | head -20" })

      expect(described_class.new.decision_for(input))
        .to have_attributes(name: :allow, term: [%w[cat README.md], %w[head -20]])
    end

    it "answers from the INJECTED verdict, never one of its own" do
      pinned = Lain::Shell::Verdict::Decision.new(name: :allow, reason: "spec pins", term: [%w[true]].freeze)
      tool = described_class.new(verdict: ->(_command) { pinned })

      expect(tool.decision_for(described_class::Input.build({ "command" => "ls -la" }))).to be(pinned)
    end

    it "is the same verdict #perform picks its arm from, so the two cannot disagree" do
      recorder = RecordingChannel.new
      tool = described_class.new(journal: recorder)
      input = described_class::Input.build({ "command" => "echo a && echo b" })
      tool.call({ command: input.command }, invocation)

      expect(tool.decision_for(input).name)
        .to eq(recorder.events.grep(Lain::Telemetry::ShellArm).map(&:verdict).last)
    end
  end

  describe "journalling which arm ran" do
    let(:journal) { RecordingChannel.new }

    def arms = journal.events.grep(Lain::Telemetry::ShellArm)

    it "records the allow verdict, the call it belongs to, and the term it authorised" do
      described_class.new(journal:).call({ command: "cat README.md | head -20" },
                                         invocation(tool_use_id: "tu_term"))

      expect(arms.map { |arm| [arm.tool_use_id, arm.verdict, arm.arm, arm.term] })
        .to eq([["tu_term", :allow, :term, [%w[cat README.md], %w[head -20]]]])
    end

    # The decision's own sentence, verbatim, rather than one composed here: a
    # reader joining this record to the gate's `shell verdict` line is reading
    # two accounts of ONE Decision, and a paraphrase would make them look like
    # two judgements that happened to agree.
    it "carries the decision's own reason" do
      described_class.new(journal:).call({ command: "ls -la" }, invocation)

      expect(arms.map(&:reason)).to eq([Lain::Shell::Verdict.new.call("ls -la").reason])
    end

    it "records an abstention, which carries no term because no arm chose one" do
      described_class.new(journal:).call({ command: "echo a && echo b" }, invocation)

      expect(arms.map { |arm| [arm.verdict, arm.arm, arm.term] }).to eq([[:abstain, :string, []]])
    end

    # What a bench asks of these records is what FRACTION of commands earn the
    # deterministic arm, so a denominator missing every uninteresting call
    # cannot answer it.
    it "writes exactly one record per call, on both arms" do
      tool = described_class.new(journal:)
      ["ls -la", "echo a && echo b", "printf hi"].each { |command| tool.call({ command: }, invocation) }

      expect(arms.map(&:verdict)).to eq(%i[allow abstain allow])
    end

    # The record is about the DECISION and not the outcome: a nonzero exit
    # rides in the tool result's content and `is_error` means the tool could not
    # produce a result, so neither is a fact about which arm was chosen.
    it "holds nothing about how the command came out" do
      described_class.new(journal:).call({ command: "grep -q lain-no-such-pattern /dev/null" }, invocation)

      expect(arms.map { |arm| arm.to_h.keys }).to eq([%i[tool_use_id verdict arm reason term claim]])
    end

    # A REAL {Exec::Docker} -- the predicate and the fallback under test are its
    # own -- with only the docker client's spawn recorded, so these examples need
    # no container and no client on PATH.
    def recording_docker
      inner = Class.new do
        attr_reader :command

        def call(command:, **)
          @command = command
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end
      end.new
      [Lain::Exec::Docker.new(project: Dir.pwd, image: "img:1", exec: inner,
                              prober: ->(_timeout) { "Docker version 27.3.1" }), inner]
    end

    # THE CASE A VERDICT ALONE GETS WRONG, and it is this chunk's own headline
    # command. {Exec::Docker#takes_term?} is `term.size == 1`, so under
    # `--exec docker` an allowed PIPE falls back to the model's own string and
    # runs as `["sh", "-c", command]` inside the container -- a shell, on a
    # record that named only the allow. The verdict is still an allow, because
    # the verdict is what was DECIDED; the arm is the string one, because that
    # is what RAN. Keeping both is what makes the divergence readable.
    it "records the string arm for an allowed pipe whose backend refused the term" do
      backend, inner = recording_docker

      described_class.new(exec: backend, journal:).call({ command: "cat README.md | head -20" }, invocation)

      expect(inner.command.first.last(3)).to eq(["sh", "-c", "cat README.md | head -20"])
      expect(arms.map { |arm| [arm.verdict, arm.arm] }).to eq([%i[allow string]])
    end

    # The same backend, one stage: docker DOES have a shape for this term, so it
    # runs as argv with no shell in the container and the record says so. The
    # pair of examples is what pins the arm to the backend's real answer rather
    # than to the verdict.
    it "records the term arm on the same backend where the term was taken" do
      backend, inner = recording_docker

      described_class.new(exec: backend, journal:).call({ command: "ls -la" }, invocation)

      expect(inner.command.first.last(3)).to eq(["img:1", "ls", "-la"])
      expect(arms.map { |arm| [arm.verdict, arm.arm] }).to eq([%i[allow term]])
    end

    # The third verdict, which the group tested nowhere. A deny is on the STRING
    # arm at this tool -- #arm_for offers a term only on an allow -- so deny and
    # abstain reach the same arm by different decisions, and only the pair of
    # members tells them apart.
    it "records a denied command, on the string arm" do
      denying = Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["curl"]))
      seen = []
      backend = Lain::Exec::Local.new(shell_out_factory: lambda { |command, **opts|
        seen << command
        Mixlib::ShellOut.new("true", **opts)
      })

      described_class.new(exec: backend, verdict: denying, journal:)
                     .call({ command: "curl http://example.com" }, invocation)

      expect(seen).to eq(["curl http://example.com"])
      expect(arms.map { |arm| [arm.verdict, arm.arm, arm.term] }).to eq([[:deny, :string, []]])
    end

    # The record names the verdict, which is the decision the gate and the tool
    # share, and it is NOT a second account of what the backend then did with
    # it: a backend with no shape for a multi-stage term runs the model's own
    # string under that same allow. Pinned rather than left to be discovered.
    it "records the allow even where the backend had no shape for the term" do
      string_only = Class.new do
        def takes_term?(_term) = false
        def call(command:, **) = Lain::Exec::Capture.new(exit_status: 0, stdout: command.to_s, stderr: "")
      end.new

      result = described_class.new(exec: string_only, journal:).call({ command: "grep -r foo . | wc -l" }, invocation)

      expect(result.content).to include("grep -r foo . | wc -l")
      expect(arms.map { |arm| [arm.verdict, arm.arm] }).to eq([%i[allow string]])
    end

    # `/mode auto` resolves the gate to ApproveAll, so no rung of the ladder
    # runs and nothing above the tool writes anything about the choice of arm --
    # which is what leaves this record as an `auto` session's only account of
    # it. Driven through the real resolution rather than through ApproveAll
    # named by hand: which policy `auto` names is the fact the example rests on.
    it "still records under /mode auto, where no ladder runs" do
      tool = described_class.new(journal:)
      resolution = Lain::Mode::Resolution.for(mode: Lain::Mode.new(posture: :auto),
                                              base: Lain::Toolset.new([tool]),
                                              queue: Lain::Middleware::Gate::DenyAll.new)
      gate = Lain::Middleware::Gate.new(policy: resolution.gate_policy)

      result = dispatch_call("bash", { "command" => "ls -la" }, id: "tu_auto", toolset: resolution.toolset,
                                                                layers: [gate],
                                                                handler: Lain::Effect::Handler::Live.new(channel:))

      expect(resolution.gate_policy).to be_a(Lain::Middleware::Gate::ApproveAll)
      expect(result).to be_ok
      expect(arms.map { |arm| [arm.tool_use_id, arm.verdict] }).to eq([["tu_auto", :allow]])
    end

    # {Telemetry::ShellArm} refuses a record that cannot name the call it is
    # about, and this tool does not soften that into a dropped record -- which
    # would be the silence the whole card exists to end. It holds with the Null
    # journal too, because the record is BUILT on every call and only its
    # destination is Null. The one place `lib/` builds an {Effect::ToolCall}
    # ({Agent::ToolRunner}) names it from the provider's `tool_use.id`, and
    # {Effect::Handler::Live} hands that straight to the invocation, so what
    # this pins is a shape only a caller assembling one by hand can produce.
    it "refuses a call that does not name itself, rather than recording nothing" do
      expect { described_class.new.call({ command: "ls -la" }, Lain::Tool::Invocation.new) }
        .to raise_error(ArgumentError, /must name the call this record is about/)
    end

    # The record is written before the command runs, so a call that never
    # produced a result still left an account of the arm it chose -- which is
    # the datapoint a bench most wants for a command that hung.
    it "records the arm of a call that timed out and produced no result" do
      backend = Lain::Exec::Local.new(pipeline: Lain::Shell::Pipeline.new(grace: 0.1),
                                      shell_out_factory: ->(*, **) { raise "the term arm must not reach a shell" })

      result = described_class.new(exec: backend, journal:).call({ command: "sleep 5", timeout: 1 }, invocation)

      expect(result).to be_error
      expect(arms.map(&:verdict)).to eq([:allow])
    end

    # The Null default: {Tools::Subagent} runs an ungated handler and this file
    # constructs the tool alone, so a build with no journal has to write nowhere
    # rather than raise or fall back to the invocation's output channel.
    it "runs the command and writes nowhere when no journal is injected" do
      result = described_class.new.call({ command: "ls -la" }, invocation)

      expect(result).to be_ok
      expect(channel.events.grep(Lain::Telemetry::ShellArm)).to be_empty
    end
  end
end
