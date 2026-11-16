# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::CLI::Queue::Picker do
  let(:rows) { "pr:fuze/api#12\trequested by you\tAdd billing\nplan:planning/run.md\tplan done: Ship it\t1111..2222\n" }
  let(:lain) { ["/opt/ruby", "/repo/exe/lain"] }
  let(:out) { StringIO.new }

  around do |example|
    Dir.mktmpdir("lain-picker") do |dir|
      @dir = dir
      example.run
    end
  end

  def stub_fzf(stdout: "", status: 0)
    File.write(File.join(@dir, "stdout"), stdout)
    File.write(File.join(@dir, "status"), status.to_s)
    script = File.join(@dir, "fzf")
    File.write(script, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" > "#{@dir}/argv"
      cat > "#{@dir}/stdin"
      ps -o pgid= -p $$ | tr -d ' ' > "#{@dir}/pgid"
      cat "#{@dir}/stdout"
      exit "$(cat "#{@dir}/status")"
    SH
    FileUtils.chmod(0o755, script)
  end

  def recorded(name) = File.read(File.join(@dir, name))

  def picker(opened, path: @dir, source: "prs")
    described_class.new(rows:, source:, lain:, out:, env: { "PATH" => path }, opener: lambda { |id, critique:|
      opened << [id, critique]
    })
  end

  describe "the fzf run" do
    it "runs fzf in this process group with the rows on stdin and the toggles bound" do
      stub_fzf(status: 1)

      picker([]).call
      argv = recorded("argv").lines(chomp: true)

      expect(recorded("stdin")).to eq(rows)
      expect(recorded("pgid").to_i).to eq(Process.getpgrp)
      expect(argv.each_cons(2).to_a).to include(["--delimiter", "\t"], ["--with-nth", "2.."], ["--expect", "alt-enter"])
      expect(argv).to include(a_string_starting_with("ctrl-t:transform:"), a_string_starting_with("ctrl-k:transform:"))
      expect(argv).to include(a_string_matching(%r{\A/opt/ruby /repo/exe/lain queue show \{1\}\z}))
    end
  end

  describe "the pull request toggles" do
    def toggle(key, prompt)
      stub_fzf(status: 1)
      picker([]).call
      script = recorded("argv").lines(chomp: true).find { |arg| arg.start_with?("#{key}:transform:") }
                               .delete_prefix("#{key}:transform:")
      shell = Lain::Shell::Out.new("sh", "-c", script, environment: { "FZF_PROMPT" => prompt })
      shell.run_command.stdout
    end

    it "starts on my requests" do
      stub_fzf(status: 1)
      picker([]).call

      expect(recorded("argv")).to include("prs mine> ")
    end

    it "ctrl-t widens the scope to team requests, keeping matches off" do
      expect(toggle("ctrl-t", "prs mine> ")).to match(/\Achange-prompt\(prs all> \)\+reload\(.* queue prs --all\)\n\z/)
    end

    it "ctrl-t narrows it again and keeps matches on" do
      expect(toggle("ctrl-t", "prs all +matches> ")).to match(/prs mine \+matches> .*queue prs --matches\)\n\z/)
    end

    it "ctrl-k turns matches on and off, keeping the scope" do
      expect(toggle("ctrl-k", "prs all> ")).to match(/prs all \+matches> .*queue prs --all --matches\)\n\z/)
      expect(toggle("ctrl-k", "prs all +matches> ")).to match(/prs all> .*queue prs --all\)\n\z/)
    end

    it "binds no toggle when the rows are not pull requests" do
      stub_fzf(status: 1)
      picker([], source: "here").call

      expect(recorded("argv").lines(chomp: true)).not_to include(a_string_matching(/transform/))
    end
  end

  describe "the choice" do
    it "opens the row with no critique on Enter" do
      stub_fzf(stdout: "\npr:fuze/api#12\trequested by you\tAdd billing\n")
      opened = []

      expect(picker(opened).call).to eq(:opened)
      expect(opened).to eq([["pr:fuze/api#12", nil]])
    end

    it "opens the row with a critique focused on its reason on Alt-Enter" do
      stub_fzf(stdout: "alt-enter\nplan:planning/run.md\tplan done: Ship it\t1111..2222\n")
      opened = []

      picker(opened).call

      expect(opened).to eq([["plan:planning/run.md", "plan done: Ship it"]])
    end

    it "opens a row that only a reload brought in" do
      stub_fzf(stdout: "\nplan:later\tteam: acme/core\tAdd billing\n")
      opened = []

      picker(opened).call

      expect(opened).to eq([["plan:later", nil]])
    end

    it "opens nothing when fzf names no id" do
      stub_fzf(stdout: "\n\tx\ty\n")
      opened = []

      expect { picker(opened).call }.to raise_error(Lain::Error, /no row/)
      expect(opened).to be_empty
    end

    it "opens nothing on Escape" do
      stub_fzf(stdout: "\npr:fuze/api#12\tr\ts\n", status: 130)
      opened = []

      expect(picker(opened).call).to eq(:cancelled)
      expect(opened).to be_empty
    end

    it "opens nothing when nothing matched" do
      stub_fzf(status: 1)
      opened = []

      expect(picker(opened).call).to eq(:nothing)
      expect(opened).to be_empty
    end

    it "names fzf's own failure" do
      stub_fzf(status: 2)

      expect { picker([]).call }.to raise_error(Lain::Error, /fzf exited 2/)
    end
  end

  describe "an interrupt while fzf runs" do
    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def wait_for(limit: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
      sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    it "stops fzf instead of leaving it running" do
      script = File.join(@dir, "fzf")
      File.write(script, "#!/bin/sh\necho $$ > #{@dir}/pid\nexec sleep 30\n")
      FileUtils.chmod(0o755, script)
      thread = Thread.new do
        picker([]).call
      rescue Interrupt => e
        e
      end
      wait_for { File.size?(File.join(@dir, "pid")) }
      pid = recorded("pid").to_i

      thread.raise(Interrupt)
      wait_for { !alive?(pid) }

      expect(thread.value).to be_a(Interrupt)
      expect(alive?(pid)).to be(false)
    end
  end

  describe "without fzf" do
    it "prints the rows and names fzf" do
      opened = []

      expect { picker(opened, path: "").call }.to raise_error(described_class::NoFzf, /fzf/)
      expect(out.string).to eq(rows)
      expect(opened).to be_empty
    end
  end

  describe "lain queue pick", :seam do
    around do |example|
      Dir.mktmpdir("lain-picker-repo") do |repo|
        FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", repo)
        Dir.mktmpdir("lain-picker-state") do |state|
          Dir.chdir(repo) { with_env("XDG_STATE_HOME" => state, "PATH" => "#{@dir}:#{tools}") { example.run } }
        end
      end
    end

    # A PATH with what git and the stub need and no fzf.
    def tools
      File.join(@dir, "tools").tap do |bin|
        FileUtils.mkdir_p(bin)
        %w[git cat ps tr].each do |name|
          FileUtils.ln_sf(Lain::Shell::Path.find(name, path: ENV.fetch("PATH")), File.join(bin, name))
        end
      end
    end

    def pick(*argv)
      stdout = StringIO.new
      saved = $stdout
      $stdout = stdout
      Lain::CLI::Queue.start(["pick", *argv], debug: true)
    ensure
      $stdout = saved
    end

    it "exits 1 naming fzf when there is none" do
      expect { pick("local") }.to raise_error(Thor::Error, /fzf/)
    end

    it "exits 130 on Escape" do
      stub_fzf(status: 130)

      expect { pick("local") }.to raise_error(SystemExit) { |error| expect(error.status).to eq(130) }
    end

    describe "opening the chosen row" do
      let(:opened) { [] }
      let(:queue) do
        log = opened
        Class.new(Lain::CLI::Queue) do
          desc "open ID", "a stand-in for the sender"
          option :critique, type: :string
          define_method(:open) { |id| log << [id, options[:critique]] }
        end
      end

      def branch_off
        SeedRepo.git(Dir.pwd, "checkout", "-q", "-b", "feature")
        File.write("f.txt", "f\n")
        SeedRepo.git(Dir.pwd, "add", "f.txt")
        SeedRepo.git(Dir.pwd, "commit", "-q", "-m", "f")
        SeedRepo.git(Dir.pwd, "checkout", "-q", "-")
      end

      def printed(command, *argv)
        saved = $stdout
        $stdout = StringIO.new
        command.start(argv, debug: true)
        $stdout.string
      ensure
        $stdout = saved
      end

      def choose(key)
        branch_off
        stub_fzf(stdout: "#{key}\n#{printed(Lain::CLI::Queue, "local").lines.first}")
        printed(queue, "pick", "local")
      end

      it "opens with no critique on Enter" do
        choose("")

        expect(opened).to match([[a_string_starting_with("branch:"), nil]])
      end

      it "opens with a critique focused on the reason on Alt-Enter" do
        choose("alt-enter")

        expect(opened).to match([[a_string_starting_with("branch:"), "unmerged branch feature"]])
      end
    end

    it "takes none of the prs flags or --json" do
      %w[--all --matches --json].each do |flag|
        expect { pick("local", flag) }.to raise_error(Thor::UnknownArgumentError, /#{flag}/)
      end
    end

    it "refuses an unknown source" do
      expect { pick("nowhere") }.to raise_error(Thor::Error, /nowhere/)
    end
  end
end
