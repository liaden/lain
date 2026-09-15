# frozen_string_literal: true

require "async"

# `runtime/70_inbox.lua` -- the inbox's open gesture, and the editor's stop for a
# standing goal. Each group carries the reason it is driven end to end.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-inbox-spec") { example.run } }

  # The reason this coverage exists: `<CR>` on an inbox row must put that
  # set's document in lain://question. Every piece of that path shipped before
  # this -- the keys, the :LainOpen command, the view that resolves the line,
  # the surface that renders the set -- with NOTHING popping the verb in
  # between, so pressing enter did nothing whatsoever in a live session and
  # both halves had green specs. This drives the REAL consumer
  # ({Lain::CLI::HumanReplies}, bound exactly as `Repl#run` binds it) against a
  # REAL editor, because the seam between them is the only place the hole was
  # ever visible -- and it is the same seam that hid production's inbox being
  # built with no question surface at all.
  describe "the inbox's open gesture, end to end" do
    let(:store) { Lain::Store.new }
    let(:set) do
      Lain::Question::Set.new(questions: [Lain::Question.new(id: "db", body: "which db?")])
    end

    it "opens the set under the cursor in lain://question when the human presses enter" do
      parent = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
      asker = Lain::Tools::AskHuman.new(parent:)
      Sync { asker.ask(Lain::Tools::AskHuman::Announcement.new(set)) }
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do
        channel.push(Lain::Telemetry::Message.from_event(asker.last_question))
        wait_until_editor { buffer_lines("lain://inbox").join.include?("which db?") }

        with_consumer(frontend) do
          press("lain://inbox", "<CR>", cursor: [1, 0])
          wait_until_editor { buffer_lines("lain://question").join.include?("which db?") }
        end

        expect(buffer_lines("lain://question").join("\n")).to include("which db?").and include("`db`")
        expect(question_state["digest"]).to eq(asker.last_question.digest)
      end
    end
  end

  # A standing goal re-prompts the agent between turns, so a human watching it
  # from the editor needs a way to stop it that does not wait for the chat pane
  # to read a line. Driven through the real consumer the chat binds, with the
  # driver it is handed, against a real editor.
  describe ":LainGoalOff, end to end", :seam do
    let(:journal_io) { StringIO.new }
    let(:driver) { Lain::CLI::GoalDriver.new(journal: Lain::Journal.new(io: journal_io)) }
    let(:session) { Lain::Session.new }

    def records(type) = Lain::Journal.records(journal_io.string.lines, type:).to_a

    def iterations = records("goal_iteration").count

    # The driven prompt committed with a reply, as the iteration's ask commits it.
    def driven(prompt)
      Lain::Timeline.empty.commit(role: :user, content: [{ "type" => "text", "text" => prompt }])
                    .commit(role: :assistant, content: [{ "type" => "text", "text" => "still working" }])
    end

    # {NeovimRuntime#with_consumer}'s shape, over a consumer that holds the driver.
    def consuming(frontend)
      stop = Thread::Queue.new
      worker = Thread.new { Sync { |task| serve_goal(frontend, task, stop) } }
      yield
    ensure
      stop.close
      raise "the editor consumer thread never stopped" unless worker.join(5)
    end

    def serve_goal(frontend, task, stop)
      replies = Lain::CLI::HumanReplies.new(tty: null_tty, conductor: instance_double(Lain::CLI::Conductor),
                                            ask_human: Lain::Tools::AskHuman::Directory.new,
                                            questions: Async::Queue.new, goal: driver)
      replies.bind_editor(frontend.command_inbox, views: frontend.buffers)
      surfaces = replies.session_surfaces(task)
      pumped_until(task, reason: "the stop channel closing") { stop.closed? }
      surfaces.each(&:stop)
    end

    it "stops a standing goal before its next iteration, and its objective stays pinned" do
      driver.start("make the specs green", session:)
      timeline = driven(driver.poll(Lain::Timeline.empty))
      frontend = described_class.new(channel:, socket_path: @socket, store: Lain::Store.new)

      frontend.run do
        consuming(frontend) do
          inspector.command("LainGoalOff")
          wait_until_editor { !driver.active? }
        end
      end

      expect(driver.poll(timeline)).to be_nil
      expect(iterations).to eq(1)
      expect(session.pins.size).to eq(1)
      expect(records("goal_pin_missed")).to be_empty
    end
  end
end
