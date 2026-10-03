# frozen_string_literal: true

require "concurrent/array"
require "fileutils"
require "tmpdir"

module E2E
  # A directory a journey's real `exe/lain` lives in: its project, its HOME and its XDG state, so
  # nothing the child does can reach the developer's own.
  class Sandbox
    BUNDLER_VARIABLES = %w[BUNDLE_GEMFILE RUBYOPT BUNDLE_BIN_PATH].freeze
    LIVE = Concurrent::Array.new
    private_constant :LIVE

    class << self
      # Short, because a tmux socket path inside it must fit the 108 bytes sockaddr_un allows.
      def create(files: {}, share_state_with: nil)
        root = share_state_with&.dir || Dir.mktmpdir("e2e", ENV.fetch("TMPDIR", nil))
        sandbox = new(root, files:, owner: share_state_with.nil?)
        LIVE << sandbox
        sandbox
      end

      def reap_all!
        sandboxes = LIVE.slice!(0..)
        leaked = sandboxes.flat_map(&:reap)
        raise "a process outlived its journey: #{leaked.join("; ")}" unless leaked.empty?
      end
    end

    attr_reader :dir, :project

    def initialize(root, files:, owner:)
      @dir = Pathname.new(File.realpath(root))
      @owner = owner
      @pids = []
      FileUtils.mkdir_p(%w[state config cache home].map { |name| @dir.join(name) })
      FileUtils.mkdir_p(@dir.join("run"), mode: 0o700)
      @project = @dir.join("proj")
      build_project(files) if owner
    end

    def env
      inherited = ENV.to_h.slice(*BUNDLER_VARIABLES)
      inherited.merge(
        "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8", "TERM" => "xterm", "HOME" => home,
        "TMPDIR" => dir.to_s, "XDG_STATE_HOME" => dir.join("state").to_s, "XDG_CONFIG_HOME" => dir.join("config").to_s,
        "XDG_CACHE_HOME" => dir.join("cache").to_s, "XDG_RUNTIME_DIR" => dir.join("run").to_s
      )
    end

    def state_home = dir.join("state")

    def track(pid) = @pids << pid

    # A tracked pid is checked by reaping it, because a zombie still answers signal 0.
    def reap
      found = stragglers
      found.each_key { |pid| kill(pid) }
      FileUtils.rm_rf(dir) if @owner
      found.map { |pid, command| "#{pid} #{command}" }
    end

    private

    def home = dir.join("home").to_s

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
      command = File.read(file).tr("\0", " ")
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
