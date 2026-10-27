# frozen_string_literal: true

approval do
  deny "write_file", path: "/home/user/notes.md", content: "x"
end
