# frozen_string_literal: true

# Reline asks a terminal where its cursor is and waits half a second for the
# answer; a PTY harness with no human behind it gives that wait away on every
# prompt it draws.
module CursorReport
  QUERY = "\e[6n"
  REPLY = "\e[1;1R"

  # Answers once per query in `bytes`, and hands `bytes` back untouched.
  def answered(master, bytes)
    master.write(REPLY * bytes.scan(QUERY).size) if bytes.include?(QUERY)
    bytes
  end
end

RSpec.configure { |config| config.include(CursorReport) }
