# frozen_string_literal: true

require "tmpdir"

# A commit written with 1 `git fast-import`, where `add` + `commit` + `rev-parse`
# + `update-ref` is 4 spawns and a spawn costs ~5ms whatever it does. It touches
# neither index nor worktree, so a spec that wants a worker's commit anchored
# under a ref no longer has to switch to a detached HEAD and back.
module CommitBuilder
  IDENT = "Test <test@example.com>"

  class << self
    # @param repo [String] the repository to write into
    # @param parent [String] the commit the new one is built on; its other files carry over
    # @param files [Hash{String=>String}] path => contents, over the parent's tree
    # @param message [String]
    # @param ref [String] the full ref name to point at the new commit
    # @return [String] the new commit's sha
    def call(repo, parent:, files:, message:, ref:)
      Dir.mktmpdir("lain-commit-marks") do |dir|
        marks = File.join(dir, "marks")
        # --force: update-ref moved a ref anywhere, and an amended worker re-anchors off its old tip
        SeedRepo.git(repo, "fast-import", "--quiet", "--force", "--export-marks=#{marks}",
                     input: stream(parent:, files:, message:, ref:))
        File.read(marks)[/\A:1 (\h+)$/, 1]
      end
    end

    private

    # The wall clock, not parent + 1: reading the parent's time is a second spawn, and a parent is
    # never newer than now.
    def stream(parent:, files:, message:, ref:)
      header = "commit #{ref}\nmark :1\ncommitter #{IDENT} #{Time.now.to_i} +0000\n#{data(message)}from #{parent}\n"
      files.reduce(header) { |out, (path, body)| "#{out}M 100644 inline #{path}\n#{data(body)}" }
    end

    def data(body) = "data #{body.bytesize}\n#{body}\n"
  end
end
