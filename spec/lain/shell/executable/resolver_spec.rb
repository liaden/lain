# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Shell::Executable::Resolver do
  around do |example|
    Dir.mktmpdir("resolver-root") do |root|
      Dir.mktmpdir("resolver-home") do |home|
        @root = File.realpath(root)
        @home = File.realpath(home)
        example.run
      end
    end
  end

  attr_reader :root, :home

  let(:fresh_paths) { [] }
  let(:fresh) { Struct.new(:paths) { def fresh?(path) = paths.include?(path) }.new(fresh_paths) }
  let(:host_env) { {} }
  let(:resolver) { described_class.new(root:, fresh:, host_env:) }

  # A planted binary: a script's shebang would resolve to its interpreter instead.
  def plant(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "\x7FELF".b)
    File.chmod(0o755, path)
    path
  end

  def resolve(*argvs, path:, env: {}, cwd: root)
    worker_env = Lain::WorkerEnv.new(cwd:, env: env.merge("PATH" => path))
    resolver.for(worker_env).call(Lain::Shell::Term.of(*argvs))
  end

  describe "a planted cat that shadows the system one" do
    subject(:stage) { resolve(%w[cat README.md], path: "#{root}/bin:/usr/bin").sole }

    before { plant("#{root}/bin/cat") }

    it "resolves to the project's cat, classed :project, shadowing /usr/bin/cat" do
      expect(stage).to have_attributes(name: "cat", resolved: "#{root}/bin/cat", realpath: "#{root}/bin/cat",
                                       klass: :project)
      expect(stage.shadowed).to include("/usr/bin/cat")
    end

    it "flags the project directory on PATH" do
      expect(stage.anomalies).to include(:project_path_entry)
    end
  end

  it "resolves no program reached through a process's descriptors, whose file is whatever that fd holds" do
    stages = resolve(%w[/proc/self/exe -c id], %w[/proc/self/fd/0], %w[/dev/fd/0], %w[/dev/stdin], path: "/usr/bin")

    expect(stages.map(&:klass)).to all(eq(:unresolved))
  end

  it "classes no run file reached through a process's descriptors, whatever that process's stdin is" do
    bound = resolver.for(Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "/usr/bin" }))

    expect(%w[/dev/stdin /dev/fd/0 /proc/self/fd/0].map { bound.run_file(_1).klass }).to all(eq(:unresolved))
  end

  it "classes a program no user can replace as :system" do
    stage = resolve(%w[cat README.md], path: "/usr/bin").sole

    expect(stage).to have_attributes(resolved: "/usr/bin/cat", chain: ["/usr/bin/cat"], klass: :system,
                                     anomalies: [], shadowed: [])
  end

  it "follows a user symlink into rm, listing every link, and classes it :user" do
    FileUtils.mkdir_p("#{home}/bin")
    File.symlink("/usr/bin/rm", "#{home}/bin/ls")

    stage = resolve(%w[ls], path: "#{home}/bin:/usr/bin").sole

    expect(stage).to have_attributes(resolved: "#{home}/bin/ls", realpath: "/usr/bin/rm", klass: :user)
    expect(stage.chain).to eq(["#{home}/bin/ls", "/usr/bin/rm"])
  end

  it "keeps a mise install's identity: the chain ends at that file, classed :user" do
    ruby = plant("#{home}/.local/share/mise/installs/ruby/4.0.6/bin/ruby")

    stage = resolve(%w[ruby -v], path: "#{File.dirname(ruby)}:/usr/bin").sole

    expect(stage).to have_attributes(resolved: ruby, realpath: ruby, chain: [ruby], klass: :user)
  end

  it "classes a system file reached through a symlink in the project as :project" do
    FileUtils.mkdir_p("#{root}/bin")
    File.symlink("/usr/bin/cat", "#{root}/bin/cat")

    expect(resolve(%w[cat], path: "#{root}/bin").sole).to have_attributes(realpath: "/usr/bin/cat", klass: :project)
  end

  it "classes a file reached through a directory symlinked into the project as :project" do
    plant("#{root}/bin/cat")
    File.symlink("#{root}/bin", "#{home}/pbin")

    stage = resolve(%w[cat], path: "#{home}/pbin").sole

    expect(stage).to have_attributes(resolved: "#{home}/pbin/cat", chain: ["#{home}/pbin/cat"], klass: :project)
  end

  it "classes a project file as :project when the root is given through a symlink" do
    File.symlink(root, "#{home}/rootlink")
    plant("#{root}/bin/cat")
    linked = described_class.new(root: "#{home}/rootlink", fresh:, host_env:)

    stage = linked.for(Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "#{root}/bin" })).call(Lain::Shell::Term.of(%w[cat]))

    expect(stage.sole.klass).to eq(:project)
  end

  # A lease cuts a copy of the project, so what it holds is the project's
  # whether or not anything in this lineage has changed it.
  describe "a worker a lease cut a checkout for" do
    def leased(checkout, path) = Lain::WorkerEnv.new(cwd: checkout, env: { "PATH" => path }, checkout:)

    it "classes a file in the checkout :project and flags its directory on PATH" do
      cat = plant("#{home}/lease/bin/cat")

      stage = resolver.for(leased("#{home}/lease", "#{File.dirname(cat)}:/usr/bin"))
                      .call(Lain::Shell::Term.of(%w[cat x])).sole

      expect(stage).to have_attributes(resolved: cat, klass: :project)
      expect(stage.anomalies).to include(:project_path_entry)
    end

    it "classes the checkout's file :project when the checkout is spelled through a symlink" do
      plant("#{home}/lease/bin/cat")
      File.symlink("#{home}/lease", "#{home}/leaselink")

      stage = resolver.for(leased("#{home}/leaselink", "#{home}/lease/bin")).call(Lain::Shell::Term.of(%w[cat x])).sole

      expect(stage.klass).to eq(:project)
    end
  end

  it "classes a file :user when any directory above it is writable, not only its parent" do
    locked = plant("#{home}/a/bin/tool")
    File.chmod(0o555, locked)
    File.chmod(0o555, File.dirname(locked))

    expect(resolve(%w[tool], path: File.dirname(locked)).sole.klass).to eq(:user)
  ensure
    File.chmod(0o755, File.dirname(locked))
  end

  it "reads a relative link from the link's real directory, leaving `..` for the kernel" do
    FileUtils.mkdir_p(["#{home}/a/bin", "#{home}/a/lib"])
    File.symlink("/usr/bin/cat", "#{home}/a/lib/real")
    File.symlink("../lib/real", "#{home}/a/bin/x")

    stage = resolve(%w[x], path: "#{home}/a/bin").sole

    expect(stage.chain).to eq(["#{home}/a/bin/x", "#{home}/a/bin/../lib/real", "/usr/bin/cat"])
    expect(stage.realpath).to eq("/usr/bin/cat")
  end

  describe "a relative link reached through a symlinked directory" do
    before do
      plant("#{root}/lib/cat")
      FileUtils.mkdir_p("#{home}/other/bin")
      File.symlink("../../../#{File.basename(root)}/lib/cat", "#{home}/other/bin/cat")
    end

    def through(pbin)
      File.symlink("#{home}/other/bin", pbin)
      resolve(%w[cat], path: "#{pbin}:/usr/bin").sole
    end

    it "follows `..` from where the kernel does, as root and home share a parent" do
      skip "root and home need one parent" unless File.dirname(root) == File.dirname(home)

      expect(through("#{home}/pbin")).to have_attributes(realpath: "#{root}/lib/cat", klass: :project)
    end

    context "when the text fold lands on a decoy" do
      let(:fresh_paths) { ["#{root}/lib/cat"] }

      it "classes and freshens the file that runs, not the decoy" do
        skip "root and home need one parent" unless File.dirname(root) == File.dirname(home)
        FileUtils.mkdir_p(["#{home}/x/y/z", "#{home}/#{File.basename(root)}/lib"])
        File.symlink("/usr/bin/cat", "#{home}/#{File.basename(root)}/lib/cat")

        stage = through("#{home}/x/y/z/pbin")

        expect(stage).to have_attributes(realpath: "#{root}/lib/cat", klass: :project, fresh: true)
        expect(stage.chain.last).to eq("#{home}/other/bin/../../../#{File.basename(root)}/lib/cat")
      end
    end
  end

  it "lists each later PATH hit once by realpath, never one that is the resolved file itself" do
    plant("#{root}/one/cat")
    FileUtils.mkdir_p(["#{root}/two", "#{root}/three"])
    File.symlink("#{root}/one/cat", "#{root}/two/cat")
    File.symlink("/usr/bin/cat", "#{root}/three/cat")

    stage = resolve(%w[cat], path: "#{root}/one:#{root}/two:#{root}/three:/usr/bin").sole

    expect(stage.shadowed).to eq(["#{root}/three/cat"])
  end

  # execvp tries such a file and gets EACCES before it finds the real one, so the
  # tripwire must be able to tell that refusal from a plant.
  describe "PATH candidates it skipped as not executable" do
    before do
      FileUtils.mkdir_p(["#{home}/noexec", "#{home}/dir/wc"])
      File.write("#{home}/noexec/wc", "not a program\n")
    end

    it "names a non-executable file and a directory met before the program it resolved" do
      stage = resolve(%w[wc -l], path: "#{home}/missing:#{home}/noexec:#{home}/dir:/usr/bin").sole

      expect(stage).to have_attributes(resolved: "/usr/bin/wc", skipped: ["#{home}/noexec/wc", "#{home}/dir/wc"])
    end

    context "when a candidate was written or changed this lineage" do
      let(:fresh_paths) { ["#{home}/noexec/wc"] }

      # A plant made executable between resolve and exec would otherwise pass as noise.
      it "leaves it out" do
        expect(resolve(%w[wc -l], path: "#{home}/noexec:#{home}/dir:/usr/bin").sole.skipped).to eq(["#{home}/dir/wc"])
      end
    end

    it "names none past the program it resolved" do
      expect(resolve(%w[wc -l], path: "/usr/bin:#{home}/noexec").sole.skipped).to eq([])
    end

    it "names them for a program it could not find at all" do
      expect(resolve(%w[wc], path: "#{home}/noexec").sole).to have_attributes(klass: :unresolved,
                                                                              skipped: ["#{home}/noexec/wc"])
    end
  end

  describe "wrappers" do
    before do
      plant("#{home}/bin/bundle")
      plant("#{home}/bin/rspec")
    end

    it "unwraps nice and bundle exec to name rspec as the program, nice and bundle as wrappers" do
      stage = resolve(%w[nice -n 19 bundle exec rspec], path: "#{home}/bin:/usr/bin").sole

      expect(stage.name).to eq("rspec")
      expect(stage.wrappers.map(&:name)).to eq(%w[nice bundle])
      expect(stage.wrappers.map(&:resolved)).to eq(["/usr/bin/nice", "#{home}/bin/bundle"])
    end

    it "leaves a program under bundle exec :unresolved, since bundler rewrites its PATH" do
      stage = resolve(%w[bundle exec rspec], path: "#{home}/bin:/usr/bin").sole

      expect(stage).to have_attributes(name: "rspec", klass: :unresolved)
    end

    it "leaves a program under direnv exec :unresolved, since the .envrc sets its env" do
      plant("#{home}/bin/direnv")

      stage = resolve(%w[direnv exec . cat x], path: "#{home}/bin:/usr/bin").sole

      expect(stage).to have_attributes(name: "cat", klass: :unresolved)
      expect(stage.wrappers.map(&:name)).to eq(%w[direnv])
    end

    it "unwraps time and timeout to the program they run" do
      stage = resolve(%w[time -p timeout -s KILL 5 cat x], path: "/usr/bin").sole

      expect(stage).to have_attributes(name: "cat", resolved: "/usr/bin/cat", klass: :system)
      expect(stage.wrappers.map(&:name)).to eq(%w[time timeout])
    end

    it "resolves what env runs under the PATH env assigns" do
      plant("#{root}/evil/cat")

      stage = resolve(["env", "PATH=#{root}/evil", "cat", "x"], path: "/usr/bin").sole

      expect(stage).to have_attributes(resolved: "#{root}/evil/cat", klass: :project)
      expect(stage.wrappers.map(&:name)).to eq(%w[env])
    end

    it "resolves under env -i against the default search path" do
      stage = resolve(%w[env -i cat x], path: "#{home}/bin").sole

      expect(stage).to have_attributes(resolved: "/bin/cat", realpath: "/usr/bin/cat")
    end

    it "leaves a wrapper option it cannot read :unresolved, named by the wrapper, rather than guessing" do
      stages = resolve(%w[env -S cat], %w[env -C /tmp cat], %w[nice --foo cat], %w[time --bogus cat],
                       %w[timeout --bogus 5 cat], %w[bundle exec --bogus rspec], path: "/usr/bin")

      expect(stages.map { |stage| [stage.name, stage.klass] }).to eq(
        [%w[env unresolved], %w[env unresolved], %w[nice unresolved], %w[time unresolved],
         %w[timeout unresolved], %w[bundle unresolved]].map { |name, klass| [name, klass.to_sym] }
      )
      expect(stages.first.wrappers.map(&:resolved)).to eq(["/usr/bin/env"])
    end

    it "reads an option's value attached to it" do
      stages = resolve(%w[nice -n19 cat], %w[nice --adjustment=5 cat], %w[timeout --signal=KILL 5 cat],
                       %w[time -fx cat], path: "/usr/bin")

      expect(stages.map(&:resolved)).to all(eq("/usr/bin/cat"))
    end

    it "drops what env -u unsets, in each spelling" do
      stages = resolve(%w[env -u LD_PRELOAD ls], %w[env -uLD_PRELOAD ls], %w[env --unset=LD_PRELOAD ls],
                       path: "/usr/bin", env: { "LD_PRELOAD" => "/x.so" })

      expect(stages.map(&:anomalies)).to all(eq([]))
      expect(stages.map(&:wrappers).map { |wrappers| wrappers.sole.anomalies }).to all(eq([:ld_preload]))
    end

    it "takes a wrapper with nothing to run as the program itself" do
      expect(resolve(%w[env], path: "/usr/bin").sole).to have_attributes(name: "env", klass: :system, wrappers: [])
    end

    it "unwraps a wrapper named by path, and classes the wrapper itself" do
      nice = plant("#{root}/bin/nice")

      stage = resolve([nice, "cat"], path: "/usr/bin").sole

      expect(stage.name).to eq("cat")
      expect(stage.wrappers.sole).to have_attributes(resolved: nice, klass: :project)
    end
  end

  describe "a project script's shebang" do
    def script(first_line, path: "#{root}/bin/rails")
      plant(path).tap { File.write(_1, "#{first_line}\nputs 1\n") }
    end

    let(:ruby) { plant("#{home}/.local/share/mise/installs/ruby/4.0.10/bin/ruby") }

    it "runs the interpreter env names, found on the call's PATH, as `ruby bin/rails` would" do
      rails = script("#!/usr/bin/env ruby")

      stage = resolve(%w[bin/rails runner x], path: "#{File.dirname(ruby)}:/usr/bin").sole

      expect(stage).to have_attributes(name: "ruby", resolved: ruby, klass: :user)
      expect(stage.run_files.map(&:path)).to include(rails)
      expect(stage.wrappers.sole).to have_attributes(name: "bin/rails", resolved: rails, klass: :project)
    end

    it "runs an interpreter named by its absolute path" do
      rails = script("#!#{ruby}")

      stage = resolve(%w[bin/rails runner x], path: "/usr/bin").sole

      expect(stage).to have_attributes(name: ruby, resolved: ruby, klass: :user)
      expect(stage.run_files.map(&:path)).to include(rails)
      expect(stage.wrappers.map(&:resolved)).to eq([rails])
    end

    it "keeps an outer wrapper outermost" do
      rails = script("#!/usr/bin/env ruby")

      stage = resolve(%w[nice bin/rails runner x], path: "#{File.dirname(ruby)}:/usr/bin").sole

      expect(stage.name).to eq("ruby")
      expect(stage.wrappers.map(&:resolved)).to eq(["/usr/bin/nice", rails])
    end

    it "carries the script's freshness on its wrapper and its run file" do
      script("#!/usr/bin/env ruby")
      fresh_paths << "#{root}/bin/rails"

      stage = resolve(%w[bin/rails], path: "#{File.dirname(ruby)}:/usr/bin").sole

      expect(stage.wrappers.sole.fresh).to be(true)
      expect(stage.run_files.find { _1.path == "#{root}/bin/rails" }.fresh).to be(true)
    end

    it "keeps today's resolution for env with flags, a line with an argument, no shebang, or no interpreter" do
      lines = ["#!/usr/bin/env -S ruby -w", "#!#{ruby} -w", "puts 1", "#!/usr/bin/env no-such-interpreter-here"]
      stages = lines.each_with_index.map do |line, at|
        script(line, path: "#{root}/bin/s#{at}")
        resolve(["bin/s#{at}"], path: "#{File.dirname(ruby)}:/usr/bin").sole
      end

      expect(stages.map { [_1.name, _1.klass, _1.wrappers] }).to eq((0..3).map { ["bin/s#{_1}", :project, []] })
    end

    it "keeps today's resolution when the env a shebang names is the project's own" do
      env = plant("#{root}/bin/env")
      script("#!#{env} ruby")

      stage = resolve(%w[bin/rails], path: "#{File.dirname(ruby)}:/usr/bin").sole

      expect(stage).to have_attributes(name: "bin/rails", resolved: "#{root}/bin/rails", klass: :project, wrappers: [])
    end

    it "keeps the script a run file of an interpreter whose own run files it does not know" do
      rails = script("#!/usr/bin/env cat")

      stage = resolve(%w[bin/rails], path: "/usr/bin").sole

      expect(stage).to have_attributes(name: "cat", klass: :system)
      expect(stage.run_files.map(&:path)).to include(rails)
    end

    it "reads no shebang off a project link whose file lies outside the project" do
      outside = plant("#{home}/real-rails").tap { File.write(_1, "#!/usr/bin/env ruby\n") }
      FileUtils.mkdir_p("#{root}/bin")
      File.symlink(outside, "#{root}/bin/rails")

      stage = resolve(%w[bin/rails], path: "#{File.dirname(ruby)}:/usr/bin").sole

      expect(stage).to have_attributes(name: "bin/rails", realpath: outside, klass: :project, wrappers: [])
    end

    it "keeps today's resolution when env is handed an option or an assignment, even one a PATH file is named" do
      dir = "#{home}/odd"
      ["-S", "A=1"].each { plant(File.join(dir, _1)) }
      stages = ["#!/usr/bin/env -S", "#!/usr/bin/env A=1"].each_with_index.map do |line, at|
        script(line, path: "#{root}/bin/o#{at}")
        resolve(["bin/o#{at}"], path: "#{dir}:/usr/bin").sole
      end

      expect(stages.map { [_1.name, _1.klass, _1.wrappers] }).to eq((0..1).map { ["bin/o#{_1}", :project, []] })
    end

    it "keeps today's resolution for an interpreter path that is not UTF-8, so the stage still journals" do
      odd = File.join(home.b, "b\xFF".b, "ruby".b)
      FileUtils.mkdir_p(File.dirname(odd))
      File.binwrite(odd, "\x7FELF".b)
      File.chmod(0o755, odd)
      plant("#{root}/bin/rails").tap { File.binwrite(_1, "#!".b + odd + "\n".b) }

      stage = resolve(%w[bin/rails], path: "/usr/bin").sole

      expect(stage).to have_attributes(name: "bin/rails", klass: :project, wrappers: [])
      expect { JSON.generate(stage.to_journal) }.not_to raise_error
    end

    describe "a FIFO swapped in where a script stood" do
      let(:fifo_as_file) { Class.new(Lain::Shell::Executable::Stat) { def executable?(path) = File.exist?(path) } }
      let(:resolver) { described_class.new(root:, fresh:, host_env:, stat: fifo_as_file.new) }
      let(:fifo) { "#{root}/bin/s".tap { FileUtils.mkdir_p(File.dirname(_1)) }.tap { File.mkfifo(_1) } }

      it "keeps today's resolution, reading nothing, with no writer" do
        fifo

        stage = Timeout.timeout(5) { resolve(%w[bin/s], path: "/usr/bin").sole }

        expect(stage).to have_attributes(name: "bin/s", klass: :project, wrappers: [])
      end

      # A writer opens only beside a reader, so one is held just long enough to open it.
      it "keeps today's resolution, never waiting, while a writer holds it open in silence" do
        writer = File.open(fifo, File::RDONLY | File::NONBLOCK) { File.open(fifo, File::WRONLY | File::NONBLOCK) }

        stage = Timeout.timeout(5) { resolve(%w[bin/s], path: "/usr/bin").sole }

        expect(stage).to have_attributes(name: "bin/s", klass: :project, wrappers: [])
      ensure
        writer&.close
      end
    end

    it "keeps today's resolution for a binary file" do
      File.binwrite(plant("#{root}/bin/tool"), "\x7FELF\x02\x01\x01".b)

      expect(resolve(%w[bin/tool], path: "/usr/bin").sole).to have_attributes(name: "bin/tool", klass: :project)
    end

    it "reads no shebang off a program outside the project" do
      tool = plant("#{home}/bin/tool")
      File.write(tool, "#!/usr/bin/env ruby\n")

      expect(resolve(%w[tool], path: "#{home}/bin:#{File.dirname(ruby)}:/usr/bin").sole)
        .to have_attributes(name: "tool", resolved: tool, wrappers: [])
    end
  end

  describe "a command runner it does not model" do
    it "leaves the program nohup runs :unresolved, with nohup resolved as its wrapper" do
      evil = plant("#{root}/bin/x")

      stage = resolve(["nohup", evil], path: "/usr/bin").sole

      expect(stage).to have_attributes(name: "nohup", klass: :unresolved)
      expect(stage.wrappers.sole).to have_attributes(name: "nohup", resolved: "/usr/bin/nohup", klass: :system)
    end

    it "leaves what sudo runs :unresolved" do
      plant("#{home}/bin/sudo")

      stage = resolve(%w[sudo cat x], path: "#{home}/bin:/usr/bin").sole

      expect(stage).to have_attributes(name: "sudo", klass: :unresolved)
      expect(stage.wrappers.sole.resolved).to eq("#{home}/bin/sudo")
    end

    it "leaves a runner under a modelled wrapper :unresolved too" do
      stage = resolve(["nice", "nohup", plant("#{root}/bin/x")], path: "/usr/bin").sole

      expect(stage.klass).to eq(:unresolved)
      expect(stage.wrappers.map(&:name)).to eq(%w[nice nohup])
    end

    it "resolves find as itself unless it executes something" do
      plain, executing = resolve(%w[find . -name x], %w[find . -execdir cat {} ;], path: "/usr/bin")

      expect(plain).to have_attributes(name: "find", resolved: "/usr/bin/find", klass: :system, wrappers: [])
      expect(executing).to have_attributes(name: "find", klass: :unresolved)
    end
  end

  describe "what cannot be resolved" do
    it "classes eval, an expansion as the program, and a name not on PATH as :unresolved" do
      plant("#{home}/bin/$x")
      plant("#{home}/bin/`cmd`")

      stages = resolve(%w[eval x], %w[$x a], ["`cmd`"], %w[no-such-program-here], path: "#{home}/bin:/usr/bin")

      expect(stages.map(&:klass)).to all(eq(:unresolved))
      expect(stages.map(&:name)).to eq(["eval", "$x", "`cmd`", "no-such-program-here"])
    end

    it "does not resolve a file named by path that is not executable" do
      FileUtils.mkdir_p("#{root}/bin")
      File.write("#{root}/bin/x", "x")

      expect(resolve(["#{root}/bin/x"], path: "/usr/bin").sole).to have_attributes(resolved: nil, klass: :unresolved)
    end

    it "does not resolve a file that is not executable" do
      FileUtils.mkdir_p("#{root}/bin")
      File.write("#{root}/bin/cat", "x")

      expect(resolve(%w[cat], path: "#{root}/bin:/usr/bin").sole.resolved).to eq("/usr/bin/cat")
    end
  end

  describe "anomalies" do
    it "flags an exported function before any scrub" do
      stage = resolve(%w[ls], path: "/usr/bin", env: { "BASH_FUNC_ls%%" => "() { id; }" }).sole

      expect(stage.anomalies).to include(:exported_function)
    end

    it "flags LD_PRELOAD" do
      expect(resolve(%w[ls], path: "/usr/bin", env: { "LD_PRELOAD" => "/x.so" }).sole.anomalies).to include(:ld_preload)
    end

    it "resolves an empty PATH entry from the cwd and flags it" do
      cwd = File.dirname(plant("#{root}/work/cat"))

      stage = resolve(%w[cat], path: "::/usr/bin", cwd:).sole

      expect(stage.resolved).to eq("#{cwd}/cat")
      expect(stage.anomalies).to include(:empty_path_entry)
    end

    it "flags a relative PATH entry" do
      plant("#{root}/bin/cat")

      expect(resolve(%w[cat], path: "bin:/usr/bin").sole.anomalies).to include(:relative_path_entry)
    end

    it "resolves a ./ program to a path with no ./ segment" do
      plant("#{root}/bin/x")

      expect(resolve(%w[./bin/x], path: "/usr/bin").sole.resolved).to eq("#{root}/bin/x")
    end

    it "resolves a ./ PATH entry to a path with no ./ segment" do
      plant("#{root}/bin/x")

      expect(resolve(%w[x], path: "./bin:/usr/bin").sole.resolved).to eq("#{root}/bin/x")
    end

    it "reads an empty PATH as one empty entry, searching the cwd" do
      plant("#{root}/cat")

      expect(resolve(%w[cat], path: "").sole).to have_attributes(resolved: "#{root}/cat",
                                                                 anomalies: include(:empty_path_entry))
    end

    it "flags a PATH entry that is a symlink into the project" do
      plant("#{root}/bin/cat")
      File.symlink("#{root}/bin", "#{home}/pbin")

      expect(resolve(%w[cat], path: "#{home}/pbin:/usr/bin").sole.anomalies).to include(:project_path_entry)
    end

    it "flags no PATH entry after the one that resolved" do
      expect(resolve(%w[cat], path: "/usr/bin::bin").sole.anomalies).to eq([])
    end
  end

  describe "the environment" do
    let(:host_env) { { "PATH" => "#{home}/bin", "BASH_FUNC_x%%" => "() { :; }" } }

    before { plant("#{home}/bin/cat") }

    it "reads the host's PATH and env where the worker's env names none" do
      worker_env = Lain::WorkerEnv.new(cwd: root, env: {})

      stage = resolver.for(worker_env).call(Lain::Shell::Term.of(%w[cat])).sole

      expect(stage.resolved).to eq("#{home}/bin/cat")
      expect(stage.anomalies).to include(:exported_function)
    end

    it "lays the worker's env over the host's, a nil value scrubbing" do
      worker_env = Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "/usr/bin", "BASH_FUNC_x%%" => nil })

      stage = resolver.for(worker_env).call(Lain::Shell::Term.of(%w[cat])).sole

      expect(stage).to have_attributes(resolved: "/usr/bin/cat", anomalies: [])
    end
  end

  describe "fresh" do
    let(:fresh_paths) { ["#{root}/bin/cat"] }

    it "is true when any link of the chain is fresh" do
      plant("#{root}/bin/cat")

      expect(resolve(%w[cat], path: "#{root}/bin").sole.fresh).to be(true)
    end

    it "is false when no link is" do
      expect(resolve(%w[cat], path: "/usr/bin").sole.fresh).to be(false)
    end
  end

  it "resolves one Executable per stage of every pipeline, in order, each Ractor-shareable" do
    stages = resolve(%w[cat a], %w[wc -l], path: "/usr/bin")

    expect(stages.map(&:resolved)).to eq(["/usr/bin/cat", "/usr/bin/wc"])
    expect(stages).to all(satisfy { |stage| Ractor.shareable?(stage) })
  end

  it "resolves with the default filesystem port and the host env when neither is injected" do
    worker_env = Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "/usr/bin" })

    stage = described_class.new(root:, fresh: described_class::NeverFresh).for(worker_env)
                           .call(Lain::Shell::Term.of(%w[cat]))

    expect(stage.sole).to have_attributes(klass: :system, fresh: false)
  end

  describe "#run_file" do
    def run_file(path) = resolver.for(Lain::WorkerEnv.new(cwd: root, env: {})).run_file(path)

    it "classes a file under the root :project, one the user can replace :user, and one nobody can :system" do
      inside = File.join(root, "config").tap { File.write(_1, "") }
      mine = File.join(home, "config").tap { File.write(_1, "") }

      expect([inside, mine, "/etc/hostname"].map { run_file(_1).klass }).to eq(%i[project user system])
    end

    context "with the file written this lineage" do
      let(:fresh_paths) { [File.join(home, "config")] }

      it "says it is fresh" do
        File.write(File.join(home, "config"), "")

        expect(run_file(File.join(home, "config"))).to have_attributes(klass: :user, fresh: true)
      end
    end

    it "classes a file that does not resolve, a dangling link among them, :unresolved" do
      File.symlink(File.join(home, "gone"), File.join(home, "dangling"))

      expect([File.join(home, "missing"), File.join(home, "dangling")].map { run_file(_1).klass })
        .to eq(%i[unresolved unresolved])
    end
  end

  describe "NULL" do
    it "classes every file :unresolved and not fresh" do
      entry = described_class::NULL.for(Lain::WorkerEnv.new(cwd: root, env: {})).run_file("/etc/hostname")

      expect(entry).to have_attributes(path: "/etc/hostname", klass: :unresolved, fresh: false)
    end

    it "resolves every stage :unresolved, by the name written" do
      worker_env = Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "/usr/bin" })

      stages = described_class::NULL.for(worker_env).call(Lain::Shell::Term.of(%w[cat a], %w[wc]))

      expect(stages.map(&:name)).to eq(%w[cat wc])
      expect(stages.map(&:klass)).to all(eq(:unresolved))
    end
  end

  describe "CONTAINER" do
    let(:stages) do
      worker_env = Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "/usr/bin" })
      described_class::CONTAINER.for(worker_env).call(Lain::Shell::Term.of(%w[cat README.md], %w[wc]))
    end

    it "resolves every stage :unresolved with the container_backend anomaly, naming no host file" do
      expect(stages.map(&:to_journal)).to all(include("klass" => "unresolved", "resolved" => nil, "realpath" => nil,
                                                      "anomalies" => ["container_backend"]))
      expect(stages.map(&:name)).to eq(%w[cat wc])
    end

    it "says why no machine may approve the call" do
      expect(Lain::Shell::Executable.bar(stages)).to include(include("container"))
    end
  end
end
