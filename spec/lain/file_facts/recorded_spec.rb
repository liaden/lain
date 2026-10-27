# frozen_string_literal: true

RSpec.describe Lain::FileFacts::Recorded do
  subject(:facts) do
    described_class.new(places: %w[/home/user/project /home/user],
                        landings: { "/home/user/project/bin/run" => "/home/user/project/tools/run" })
  end

  let(:live_calls) do
    { File => %i[realpath symlink? exist? file? directory? readlink lstat stat],
      Dir => %i[glob each_child children pwd] }
  end

  # The guarantee is that an answer never comes off today's disk.
  before do
    live_calls.each do |owner, names|
      names.each { |name| allow(owner).to receive(name).and_raise("live #{owner}.#{name}") }
    end
  end

  it "answers a recorded place as itself, a directory, and no guess" do
    guessed = facts.observing do
      expect(facts.realpath("/home/user/project")).to eq("/home/user/project")
      expect(facts.directory?("/home/user/project")).to be(true)
      expect(facts.exist?("/home/user")).to be(true)
      expect(facts.symlink?("/home/user")).to be(false)
    end

    expect(guessed).to be(false)
  end

  it "answers a recorded landing where the record put it" do
    guessed = facts.observing do
      expect(facts.realpath("/home/user/project/bin/run")).to eq("/home/user/project/tools/run")
    end

    expect(guessed).to be(false)
  end

  it "takes the call's own landings for the length of the call" do
    landed = facts.observing({ "/home/user/project/x" => "/opt/x" }) { facts.realpath("/home/user/project/x") }

    expect(landed).to be(false)
    expect(facts.observing { facts.realpath("/home/user/project/x") }).to be(true)
  end

  it "guesses an unrecorded path lands on itself, cleaned, and says it guessed" do
    answer = nil
    guessed = facts.observing { answer = facts.realpath("/home/user/project/src/../a.rb") }

    expect(answer).to eq("/home/user/project/a.rb")
    expect(guessed).to be(true)
  end

  it "guesses a listing or a match is empty, and says so" do
    found = []
    guessed = facts.observing do
      found += facts.glob("*.rb", base: "/home/user/project")
      facts.each_child("/home/user/project") { found << _1 }
    end

    expect(found).to be_empty
    expect(guessed).to be(true)
  end

  it "drops a call's own landings once the call is over" do
    facts.observing({ "/home/user/project/x" => "/opt/x" }) { nil }

    expect(facts.realpath("/home/user/project/x")).to eq("/home/user/project/x")
  end

  it "guesses an unrecorded path exists, as it guesses it lands on itself" do
    exists = nil

    expect(facts.observing { exists = facts.exist?("/home/user/project/new.rb") }).to be(true)
    expect(exists).to be(true)
  end

  it "starts each call with no guess on it" do
    facts.observing { facts.file?("/home/user/project/a.rb") }

    expect(facts.observing { facts.directory?("/home/user") }).to be(false)
  end
end
