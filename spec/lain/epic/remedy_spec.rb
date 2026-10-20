# frozen_string_literal: true

require "shellwords"

RSpec.describe Lain::Epic::Remedy do
  let(:slug) { "demo" }

  it "spells a land, with the resume flag only when asked" do
    expect(described_class.land("a", slug)).to eq("lain epic land a demo")
    expect(described_class.land("a", slug, resume: true)).to eq("lain epic land a demo --resume")
  end

  it "spells a submit, adding the issue and the digest only when given" do
    expect(described_class.submit("research", slug)).to eq("lain epic submit research demo")
    expect(described_class.submit("implementation", slug, issue: "a", digest: "abc"))
      .to eq("lain epic submit implementation demo --issue a --digest abc")
  end

  it "spells a finish, local or not" do
    expect(described_class.finish(slug)).to eq("lain epic finish demo")
    expect(described_class.finish(slug, local: true)).to eq("lain epic finish demo --local")
  end

  it "spells a queue and a chat" do
    expect(described_class.queue(slug)).to eq("lain epic queue demo")
    expect(described_class.chat(slug)).to eq("lain chat --epic demo")
  end

  it "parses every spelling as a lain command line naming the slug" do
    lines = [described_class.land("a", slug, resume: true), described_class.submit("issue_plan", slug, issue: "a"),
             described_class.finish(slug, local: true), described_class.queue(slug), described_class.chat(slug)]

    expect(lines.map { |line| Shellwords.split(line) }).to all(start_with("lain").and(include(slug)))
  end
end
