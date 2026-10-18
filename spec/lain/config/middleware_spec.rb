# frozen_string_literal: true

RSpec.describe Lain::Config::Middleware do
  let(:stamp) do
    Class.new(Lain::Middleware::Base) do
      attr_reader :tag, :tags

      def initialize(tag: nil, tags: [])
        super()
        @tag = tag
        @tags = tags
      end
    end
  end
  let(:call_class) { Struct.new(:verb, :args, :kwargs, :block, :line, keyword_init: true) }

  def calls_for(area, *args, line: 3, block: nil, **kwargs)
    [call_class.new(verb: area, args:, kwargs:, block:, line:)]
  end

  def refusal_for(&)
    raise_error(Lain::Config::Refusal, &)
  end

  it "builds a fresh instance on each members call" do
    registry = described_class.from(calls_for(:model, stamp, tag: "a"), path: "/p")

    first, second = Array.new(2) { registry.members(:model) }

    expect([first.map(&:tag), second.map(&:tag), first.first.equal?(second.first)])
      .to eq([["a"], ["a"], false])
  end

  it "hands each instance frozen argument collections" do
    registry = described_class.from(calls_for(:model, stamp, tags: ["a"]), path: "/p")

    expect(registry.members(:model).first.tags).to be_frozen
  end

  it "leaves the caller's own argument unfrozen" do
    mine = ["a"]
    described_class.from(calls_for(:model, stamp, tags: mine), path: "/p")

    expect(mine).not_to be_frozen
  end

  it "refuses an argument that cannot be made shareable, at its line" do
    local = 1
    calls = calls_for(:model, stamp, line: 8, callback: proc { local })

    expect { described_class.from(calls, path: "/p") }.to(refusal_for { |e| expect(e.message).to include("/p:8") })
  end

  it "builds an Inline from a block registration" do
    block = proc { |env, &downstream| downstream.call(env.merge(seen: true)) }
    registry = described_class.from(calls_for(:tool, block:), path: "/p")

    member = registry.members(:tool).first
    expect([member, member.call({}) { |env| env }]).to match([be_a(Lain::Middleware::Inline), { seen: true }])
  end

  it "puts earlier registrations first when added" do
    one = described_class.from(calls_for(:tool, stamp, tag: "A") + calls_for(:tool, stamp, tag: "B"), path: "/p")
    two = described_class.from(calls_for(:tool, stamp, tag: "C"), path: "/q")

    expect((one + two).members(:tool).map(&:tag)).to eq(%w[A B C])
  end

  it "refuses a registration that is neither a Class nor a block, at its line" do
    expect { described_class.from(calls_for(:tool, "Stamp", line: 4), path: "/p") }
      .to(refusal_for { |e| expect(e.message).to include("/p:4").and include("Class or a block") })
  end

  it "refuses a class with no instance call" do
    expect { described_class.from(calls_for(:tool, Class.new, line: 4), path: "/p") }
      .to(refusal_for { |e| expect(e.message).to include("/p:4").and include("call") })
  end

  it "refuses a turn class without settle, at its line" do
    bare = Class.new { def call(env) = env }

    expect { described_class.from(calls_for(:turn, bare, line: 5), path: "/p") }
      .to(refusal_for { |e| expect(e.message).to include("/p:5").and include("settle") })
  end

  it "names an anonymous turn class and both missing methods in one refusal" do
    expect { described_class.from(calls_for(:turn, Class.new, line: 5), path: "/p") }
      .to(refusal_for do |e|
        expect(e.message).to include("/p:5").and include("an anonymous class").and include("#call")
                                            .and include("#settle")
      end)
  end

  it "says a middleware is a Class when given a Module" do
    expect { described_class.from(calls_for(:tool, Module.new, line: 4), path: "/p") }
      .to(refusal_for do |e|
            expect(e.message).to include("/p:4").and include("is a Class").and include("not a Module")
          end)
  end

  it "refuses an http block" do
    expect { described_class.from(calls_for(:http, block: proc {}, line: 6), path: "/p") }
      .to(refusal_for { |e| expect(e.message).to include("/p:6").and include("Faraday middleware class") })
  end

  it "refuses an unknown area, at its line" do
    expect { described_class.from(calls_for(:nope, stamp, line: 2), path: "/p") }
      .to(refusal_for { |e| expect(e.message).to include("/p:2").and include("nope") })
  end

  it "re-raises wrong constructor arguments at the registering line" do
    needy = Class.new(Lain::Middleware::Base) { def initialize(tag:) = super() && tag }
    registry = described_class.from(calls_for(:model, needy, line: 7), path: "/p")

    expect { registry.members(:model) }
      .to(refusal_for { |e| expect(e.message).to include("/p:7").and include("tag") })
  end

  it "builds nothing when empty" do
    empty = described_class.empty

    expect(%i[model tool turn repl].map { |area| empty.members(area) } + [empty.http_entries])
      .to eq([[], [], [], [], []])
  end

  it "lists http entries as class, args and kwargs" do
    registry = described_class.from(calls_for(:http, stamp, 1, header: "x"), path: "/p")

    expect(registry.http_entries).to eq([[stamp, 1, { header: "x" }]])
  end

  it "accepts an http class whose instances do not answer call" do
    plain = Class.new
    registry = described_class.from(calls_for(:http, plain), path: "/p")

    expect(registry.http_entries.first.first).to eq(plain)
  end

  describe "#to_header" do
    it "names whose trust digest admitted the registrations" do
      registry = described_class.from(calls_for(:tool, stamp), path: "/p").trusted_by("project", "d1")

      expect(registry.to_header).to eq("project" => "d1")
    end

    it "is empty when nothing is registered, whoever trusted the file" do
      expect(described_class.empty.trusted_by("project", "d1").to_header).to eq({})
    end

    it "keeps each side's digest across a merge, and drops a side that registered nothing" do
      user = described_class.from(calls_for(:model, stamp), path: "/u").trusted_by("user", "u1")
      project = described_class.empty.trusted_by("project", "p1")

      expect([(user + project).to_header, (user + user.trusted_by("project", "p1")).to_header])
        .to eq([{ "user" => "u1" }, { "user" => "u1", "project" => "p1" }])
    end

    it "records a trusted project's digest through Config.middleware" do
      Dir.mktmpdir do |root|
        write_config(root, "class Stamp < Lain::Middleware::Base; end\nmiddleware { tool Stamp }\n")
        digest = Lain::Project::Trust.for(project_dir: Lain::ProjectDir.new(root:), paths: Lain::Paths.new).digest

        expect(Lain::Config.middleware(root:).to_header).to eq("project" => digest)
      end
    end

    it "records the user's digest beside the project's when both configs register middleware" do
      Dir.mktmpdir do |home|
        paths = Lain::Paths.new(env: { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, "config"),
                                       "XDG_STATE_HOME" => File.join(home, "state") })
        root = File.join(home, "project")
        FileUtils.mkdir_p(File.dirname(paths.user_config))
        File.write(paths.user_config, "class UserStamp < Lain::Middleware::Base; end\nmiddleware { tool UserStamp }\n")
        user = Lain::Project::Trust.for_user(paths:).tap(&:grant!).digest
        write_config(root, "class ProjectStamp < Lain::Middleware::Base; end\nmiddleware { tool ProjectStamp }\n",
                     paths:)
        project = Lain::Project::Trust.for(project_dir: Lain::ProjectDir.new(root:, paths:), paths:).digest

        expect(Lain::Config.middleware(root:, paths:).to_header).to eq("user" => user, "project" => project)
      end
    end

    it "is empty through Config.middleware when a trusted file registers nothing" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[curl]\n")

        expect(Lain::Config.middleware(root:).to_header).to eq({})
      end
    end
  end

  it "freezes its per-area arrays apart from the caller's input" do
    input = [described_class::Registration.new(factory: stamp, args: [], kwargs: {}, block: nil, at: "/p:1")]
    registry = described_class.new(model: input)
    input.clear

    expect([registry.members(:model).size, registry.__send__(:registrations, :model)])
      .to match([1, be_frozen])
  end
end
