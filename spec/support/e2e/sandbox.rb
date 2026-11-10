# frozen_string_literal: true

require "bundler"
require "concurrent/array"
require "fileutils"
require "tmpdir"

module E2E
  # A directory a journey's real `exe/lain` lives in: its project, its HOME and its XDG state, so
  # nothing the child does can reach the developer's own.
  class Sandbox
    BUNDLER_VARIABLES = %w[BUNDLE_GEMFILE RUBYOPT BUNDLE_BIN_PATH LAIN_BOOTSNAP_CACHE].freeze
    DEFAULT_PROJECT = "proj"
    LEASE = /\A\h{12}\z/
    SEEN_LEASES = Concurrent::Array.new
    LIVE = Concurrent::Array.new
    private_constant :LIVE

    class << self
      # Short, because a tmux socket path inside it must fit the 108 bytes sockaddr_un allows.
      def create(files: {}, share_state_with: nil, project: DEFAULT_PROJECT)
        root = share_state_with&.dir || Dir.mktmpdir("e2e", ENV.fetch("TMPDIR", nil))
        sandbox = new(root, files:, owner: share_state_with.nil?, project:)
        LIVE << sandbox
        sandbox
      end

      def live = LIVE.to_a

      # What the live sandboxes' random roots make different in every run, each with the placeholder a
      # cassette keeps in its place: a root, numbered in creation order, and the per-project key hashed
      # from each project, named by its root and its directory. Sandboxes sharing a root share its number.
      # One made before `since` was taken is left out, so an earlier example's leftover cannot shift a number.
      def volatile(since: [])
        counted = live - since
        roots = counted.map(&:dir).uniq
        named = counted.map { |sandbox| sandbox.volatile("SANDBOX#{roots.index(sandbox.dir) + 1}") }.reduce({}, :merge)
        named.merge(leases(roots))
      end

      # A lease checkout's directory is a hash of its worker id that moves from run to run, so each is
      # named by the order fingerprints first saw it in. The filesystem here keeps no birth time.
      def leases(roots)
        found = roots.flat_map { |root| Dir.glob(root.join("state", "lain", "worktrees", "*", "*").to_s).sort }
                     .select { |path| File.basename(path).match?(LEASE) }
        (found - SEEN_LEASES).each { |path| SEEN_LEASES << path }
        (SEEN_LEASES & found).each_with_index.to_h { |path, index| [path, "<LEASE#{index + 1}>"] }
      end

      def reap_all!
        sandboxes = LIVE.slice!(0..)
        leaked = sandboxes.flat_map(&:reap)
        raise "a process outlived its journey: #{leaked.join("; ")}" unless leaked.empty?
      end
    end

    attr_reader :dir, :project

    def initialize(root, files:, owner:, project: DEFAULT_PROJECT)
      @dir = Pathname.new(File.realpath(root))
      @owner = owner
      @pids = []
      FileUtils.mkdir_p(%w[state config cache home tmp].map { |name| @dir.join(name) })
      FileUtils.mkdir_p(@dir.join("run"), mode: 0o700)
      @project = @dir.join(project)
      build_project(files) unless @project.exist?
    end

    def env
      inherited = ENV.to_h.slice(*BUNDLER_VARIABLES).merge("BUNDLER_VERSION" => Bundler::VERSION)
      inherited.merge(
        "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8", "TERM" => "xterm", "HOME" => home,
        "TMPDIR" => tmp, "XDG_STATE_HOME" => dir.join("state").to_s, "XDG_CONFIG_HOME" => dir.join("config").to_s,
        "XDG_CACHE_HOME" => dir.join("cache").to_s, "XDG_RUNTIME_DIR" => dir.join("run").to_s
      )
    end

    def state_home = dir.join("state")

    def volatile(name)
      { dir.to_s => "<#{name}>", Lain::Paths.new.project_hash(project.to_s) => "<PROJECT:#{name}/#{project.basename}>" }
    end

    def track(pid) = @pids << pid

    # A tracked pid is checked by reaping it, because a zombie still answers signal 0.
    def reap
      LIVE.delete(self)
      found = stragglers
      found.each_key { |pid| kill(pid) }
      FileUtils.rm_rf(dir) if @owner
      found.map { |pid, command| "#{pid} #{command}" }
    end

    private

    def home = dir.join("home").to_s

    # Beside home rather than above it: a workspace call refuses a TMPDIR that holds home. Short, because a
    # tmux socket path inside it must fit sockaddr_un.
    def tmp = dir.join("tmp").to_s

    def build_project(files)
      FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", project.tap(&:mkpath))
      files.each do |path, content|
        FileUtils.mkdir_p(project.join(path).dirname)
        File.write(project.join(path), content)
      end
    end

    def stragglers
      named = Dir.glob("/proc/[0-9]*/cmdline").filter_map { |file| straggler_in(file) }.to_h
      @pids.reject { |pid| gone?(pid) }.each { |pid| named[pid] ||= "tracked child" }
      named.except(Process.pid)
    end

    def straggler_in(file)
      # Every process on the box is scanned, and a cmdline is whatever bytes its argv held.
      command = File.binread(file).force_encoding(Encoding::UTF_8).scrub.tr("\0", " ")
      [file[/\d+/].to_i, command.strip] if command.include?(dir.to_s)
    rescue SystemCallError
      nil
    end

    def gone?(pid)
      !Process.wait(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end

    def kill(pid)
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
