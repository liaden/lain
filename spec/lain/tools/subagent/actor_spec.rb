# frozen_string_literal: true

require "async"
require "json"
require "stringio"

# An actor's lifecycle is a chain of :message events, and the session record gets
# each one through the seam's observer, which is the scribe. The seam's journal is
# that same session file, so a second write of the event onto the journal would
# put every transition in the record twice.
RSpec.describe Lain::Tools::Subagent::Actor do
  let(:session_io) { StringIO.new }
  let(:session_file) { Lain::Journal.new(io: session_io) }
  let(:scribe) { CoreGraph.scribe(journal: session_file) }
  let(:store) { CoreGraph.store }
  let(:parent) do
    CoreGraph.timeline(store:)
             .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
             .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:tool) do
    CoreGraph.subagent(provider: CoreGraph.provider(text_response("actor ready")), parent:,
                       journal: session_file, observer: scribe, mode: :actor)
  end

  def records = session_io.string.each_line.map { |line| JSON.parse(line) }

  def stops
    records.select { |record| record["type"] == "message" && record.dig("payload", "lifecycle") == "stopped" }
  end

  describe "#stop" do
    it "leaves exactly one message record carrying the stop in the session file" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        actor = supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("go", worker_env:) }
        actor.settle
        supervisor.stop
      ensure
        supervisor&.stop
      end

      expect(stops.size).to eq(1)
    end
  end

  # The actor keeps its adoption ordinal for twins on the same work, and names
  # the work beside it, so its address is derived from what it was given as a
  # one-shot's is.
  describe "#launch" do
    it "records the digest of the prompt it was launched with in its :spawn" do
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal: session_file).run(task)
        supervisor.adopt(role: "researcher") { |worker_env| tool.launch_actor("watch the build", worker_env:) }
        supervisor.stop
      ensure
        supervisor&.stop
      end

      spawn = records.find { |record| record["type"] == "message" && record["kind"] == "spawn" }
      expect(spawn.fetch("payload")).to include("task" => Lain::Canonical.digest("watch the build"), "adoption" => 1)
    end
  end
end
