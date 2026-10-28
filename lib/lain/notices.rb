# frozen_string_literal: true

module Lain
  # Notes for a human who is not at the terminal, handed to the `notify-feed` program.
  module Notices
    PROGRAM = "notify-feed"

    # @param env [#[]] the process environment, searched for {PROGRAM} on PATH
    # @param program [String, nil] a program the user named, used without a PATH search
    # @return [Feed, Null]
    def self.for(env: ENV, program: nil)
      found = program || on_path(env["PATH"].to_s)
      found ? Feed.new(program: found) : Null.new
    end

    def self.on_path(path)
      path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, PROGRAM) }.find { |file| executable?(file) }
    end

    def self.executable?(file) = File.file?(file) && File.executable?(file)
    private_class_method :on_path, :executable?
  end
end
