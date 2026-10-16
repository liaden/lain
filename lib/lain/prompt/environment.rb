# frozen_string_literal: true

module Lain
  module Prompt
    # The facts about where an agent is running, rendered into the system prompt
    # so a fresh agent never spends a turn asking. Built once per session: the
    # date is read at construction, which keeps the prompt prefix byte-stable
    # for the cache.
    Environment = Data.define(:home, :user, :os, :shell, :root, :cwd, :related, :git, :date) do
      def initialize(related:, **fields)
        super(related: related.map(&:-@).freeze, **fields.transform_values { _1.is_a?(String) ? -_1 : _1 })
      end

      # @param project [Project]
      # @param related [Array<String>] related directories as written in config
      # @param clock [#now]
      # @param env [#[]]
      # @param os_release [String] path of the os-release file
      # @return [Environment]
      def self.current(project:, related:, clock: Time, env: ENV, os_release: "/etc/os-release")
        home = env["HOME"].to_s
        new(home:, user: env["USER"].to_s, os: os_name(os_release), shell: env["SHELL"].to_s,
            root: project.root, cwd: project.cwd, related: related.map { expand(_1, home) },
            git: File.exist?(File.join(project.root, ".git")), date: clock.now.strftime("%F"))
      end

      # @return [Environment] constant values and no filesystem, for specs
      def self.fixed
        new(home: "/home/user", user: "user", os: "Linux 1.0", shell: "/bin/bash", root: "/work/project",
            cwd: "/work/project/src", related: ["/work/related"], git: true, date: "2026-01-02")
      end

      # @return [Environment] renders nothing, for callers with no project
      def self.none
        new(home: nil, user: nil, os: nil, shell: nil, root: nil, cwd: nil, related: [], git: nil, date: nil)
      end

      def self.os_name(path)
        fields = File.exist?(path) ? File.readlines(path, chomp: true).grep(/\A\w+=/).to_h { _1.split("=", 2) } : {}
        (fields["PRETTY_NAME"] || fields["NAME"] || RbConfig::CONFIG["host_os"]).delete('"')
      end

      def self.expand(directory, home) = directory.sub(%r{\A~(?=/|\z)}) { home }

      # The same facts for a child, whose working directory is its own and is
      # stated after the cache breakpoint, so every child's block is the same bytes.
      # @return [Environment]
      def for_child = with(cwd: "stated after your role instructions")

      def to_s
        return "" if root.nil?

        <<~TEXT
          Environment:
          - Date: #{date}
          - OS: #{os}
          - Shell: #{shell}
          - User: #{user}
          - Home directory: #{home}
          - Project root: #{root}#{git ? " (a git repository)" : " (not a git repository)"}
          - Working directory: #{cwd}
          - Related directories: #{related.empty? ? "none" : related.join(", ")}
        TEXT
      end
    end
  end
end
