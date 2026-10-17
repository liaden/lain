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

  def plant(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
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

  describe "NULL" do
    it "resolves every stage :unresolved, by the name written" do
      worker_env = Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "/usr/bin" })

      stages = described_class::NULL.for(worker_env).call(Lain::Shell::Term.of(%w[cat a], %w[wc]))

      expect(stages.map(&:name)).to eq(%w[cat wc])
      expect(stages.map(&:klass)).to all(eq(:unresolved))
    end
  end
end
