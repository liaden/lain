# frozen_string_literal: true

# The audit behind Tool#side_effects?: one row per shipped tool, with the reason
# it answers as it does. A tool that is not a row fails by name, so a new tool
# must choose deliberately instead of inheriting an answer unseen.
module SideEffectsSpecSupport
  NONE = "changes nothing outside lain's own memory"

  AUDIT = {
    "read_file" => [false, "reads a file and records the read in the session"],
    "list_files" => [false, "lists a directory"],
    "glob" => [false, "matches paths without opening them"],
    "grep" => [false, "reads files for a pattern"],
    "memory_read" => [false, "reads the in-memory index"],
    "file_symbols" => [false, "parses a file it only reads"],
    "ast_search" => [false, "parses files it only reads"],
    "ast_dump" => [false, "parses a file it only reads"],
    "test_pattern" => [false, "answers from the layout and writes nothing"],
    "session_usage" => [false, "reports the session's own counters"],
    "ask_human" => [false, "parks a question and changes no file"],
    "bash" => [true, "runs a command string of the model's choosing"],
    "edit_file" => [true, "rewrites a file"],
    "write_file" => [true, "writes a file"],
    "todo_write" => [true, "writes the todo list the session keeps"],
    "memory_write" => [true, "writes durable project memory"],
    "improvement_write" => [true, "appends to a cross-process sink"],
    "run_skill" => [true, "runs a skill that may call anything"],
    "subagent" => [true, "spawns a child that may call anything"],
    "send_message" => [true, "appends to another actor's mailbox"],
    "request_review" => [true, "files a review request"],
    "epic_write" => [true, "replaces a file in the epic home"],
    "epic_graph" => [true, "rewrites the epic file"],
    "epic_submit" => [true, "decides a gate and journals it"],
    "epic_review" => [true, "starts a critique and writes its record"],
    "epic_status" => [true, "unaudited: folds the journal and reads files the epic tools rewrite"],
    "epic_show" => [true, "unaudited: reads files the epic tools rewrite"],
    "web_fetch" => [true, "unaudited: reaches the network"],
    "web_search" => [true, "unaudited: reaches the network"],
    "tool_search" => [true, "unaudited: moves which tools the model holds"]
  }.freeze
end

RSpec.describe "Tool#side_effects? across the shipped toolset" do
  it "is true for a tool that makes no claim" do
    silent = Class.new(Lain::Tool) do
      def name = "silent"
      def description = "says nothing about side effects"
      def input_schema = { type: :object, properties: {} }
    end

    expect(silent.new.side_effects?).to be(true)
  end

  it "audits exactly the tools the toolset ships" do
    expect(SideEffectsSpecSupport::AUDIT.keys).to match_array(ToolRegistry.shipped_names)
  end

  SideEffectsSpecSupport::AUDIT.each do |name, (answer, reason)|
    it "answers #{answer} for #{name}: #{reason}" do
      expect(ToolRegistry.build(name).side_effects?).to be(answer)
    end
  end

  it "answers false for the stand-in a name the set does not hold resolves to" do
    expect(Lain::Toolset::Unheld.new("nope").side_effects?).to be(false)
  end
end
