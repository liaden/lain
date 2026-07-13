# frozen_string_literal: true

RSpec.describe Lain::Session do
  subject(:session) { described_class.new }

  describe "the read-set" do
    it "records a read and answers read? true for it, false for paths never read" do
      session.record_read("/tmp/app.rb")

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.read?("/tmp/other.rb")).to be(false)
    end

    # Path identity is pinned: two spellings of the same file must not defeat
    # the read-set, or an edit-before-read contract would be trivially bypassed.
    it "matches across spellings of the same path (expand_path normalizes both ends)" do
      Dir.chdir("/tmp") do
        session.record_read("./app.rb")

        expect(session.read?("app.rb")).to be(true)
        expect(session.read?("/tmp/app.rb")).to be(true)
      end
    end

    it "matches when the recorded spelling is bare and the query is dotted" do
      Dir.chdir("/tmp") do
        session.record_read("app.rb")

        expect(session.read?("./app.rb")).to be(true)
      end
    end
  end

  describe "#reminders" do
    it "is empty before any todo_write lands" do
      expect(session.reminders).to eq([])
    end
  end

  describe "#write_todos" do
    def todo(content, status) = Struct.new(:content, :status).new(content, status)

    it "renders the whole list as ONE reminder string (Manifest#to_reminder's precedent)" do
      session.write_todos([todo("write the spec", "in_progress"), todo("ship it", "pending")])

      expect(session.reminders).to eq(["Current todo list:\n- [in_progress] write the spec\n- [pending] ship it"])
    end

    it "replaces the whole list on a later call rather than merging" do
      session.write_todos([todo("a", "pending")])
      session.write_todos([todo("b", "completed")])

      expect(session.reminders).to eq(["Current todo list:\n- [completed] b"])
    end

    it "goes back to no reminder when the new list is empty" do
      session.write_todos([todo("a", "pending")])
      session.write_todos([])

      expect(session.reminders).to eq([])
    end
  end

  describe Lain::Session::Null do
    subject(:null) { described_class.instance }

    it "satisfies the Session duck without raising: record_read is a no-op, read? is false" do
      expect { null.record_read("/tmp/app.rb") }.not_to raise_error
      expect(null.read?("/tmp/app.rb")).to be(false)
    end

    it "keeps write_todos a no-op that never raises" do
      expect { null.write_todos([Struct.new(:content, :status).new("a", "pending")]) }.not_to raise_error
      expect(null.reminders).to eq([])
    end

    it "has no reminders" do
      expect(null.reminders).to eq([])
    end

    it "is a shared, frozen instance" do
      expect(null).to be_frozen
      expect(described_class.instance).to be(null)
    end
  end
end
