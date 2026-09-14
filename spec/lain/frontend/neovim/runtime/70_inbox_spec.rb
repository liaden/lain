# frozen_string_literal: true

require "async"

# `runtime/70_inbox.lua` -- the inbox's open gesture. The group below carries the
# reason it is driven end to end rather than in halves.
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
end
