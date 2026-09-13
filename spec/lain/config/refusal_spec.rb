# frozen_string_literal: true

RSpec.describe Lain::Config::Refusal do
  let(:path) { "/project/.lain/config.toml" }

  # The refusal each of the seven readers raises for a table it will not read,
  # so the one rescue below can be written without naming seven classes.
  def refusal_from(&read)
    yield
    nil
  rescue described_class => e
    e
  end

  describe "the message it composes" do
    it "names the file, then the table, then the detail" do
      expect(described_class.new("must be a table", path:, table: "[sensitivity]").message)
        .to eq("/project/.lain/config.toml: [sensitivity] must be a table")
    end

    # A value built in memory rather than loaded has no file to open, so the
    # message must not invent one -- the posture the five families that already
    # had a base wrote five times over.
    it "names no file for a refusal built by hand" do
      refusal = described_class.new("must be a table", table: "[sensitivity]")

      expect(refusal.message).to eq("[sensitivity] must be a table")
      expect(refusal.path).to be_nil
    end

    # `epics_home` is the one detail that names a Ruby reader rather than a TOML
    # table, so the table segment has to be genuinely optional.
    it "omits the table segment when the refusal names no table" do
      expect(described_class.new("epics_home 3 is not one of xdg, repo", path:).message)
        .to eq("/project/.lain/config.toml: epics_home 3 is not one of xdg, repo")
    end
  end

  describe "what it carries" do
    it "carries the table, the key and the value it refused" do
      refusal = described_class.new("has no keys", path:, table: "[epics]", key: %w[hoem], value: 3)

      expect(refusal).to have_attributes(path:, table: "[epics]", key: %w[hoem], value: 3)
    end
  end

  describe "one rescue for every config table" do
    it "catches a malformed epics table and a malformed isolation table alike" do
      caught = [-> { Lain::Config::Epics.from("repo", path:) },
                -> { Lain::Config::Isolation.from("fast", path:) }].map { |read| refusal_from(&read) }

      expect(caught.map(&:message))
        .to contain_exactly(a_string_including("[epics] must be a table"),
                            a_string_including("[isolation] must be a table"))
    end

    it "catches every one of the seven tables' refusals" do
      reads = [-> { Lain::Config::Epics.from("repo", path:) },
               -> { Lain::Config::Epics::Gates.from("deferred", path:) },
               -> { Lain::Config::Answers.from("yes", path:) },
               -> { Lain::Config::Isolation.from("fast", path:) },
               -> { Lain::Shell::Exclusions.from("off", path:) },
               -> { Lain::TestLayout.from("rspec", path:) },
               -> { Lain::Sensitivity::Rules.from("strict", path:) }]

      expect(reads.map { |read| refusal_from(&read)&.message })
        .to all(include("must be a table"))
    end
  end
end
