# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# What an issue's plan declares about where its failing tests go: the one source
# file they are written for, and optionally the level root they sit under. Read
# from a plan's text, over a project declaring the rspec layout on `app`.
RSpec.describe Lain::CLI::EpicDriver::PlanSubject do
  let(:layout_mini) { File.expand_path("../../../fixtures/projects/layout_mini", __dir__) }
  let(:layout) { Lain::Config.test_layout(root: @root) }

  around do |example|
    Dir.mktmpdir("lain-plan-subject") do |dir|
      FileUtils.cp_r(File.join(layout_mini, "."), dir)
      trust_project(dir)
      @root = dir
      example.run
    end
  end

  # The in-memory stand-in {Arm::PlanOnly} passes: its text and a name to cite.
  def plan(text)
    Class.new do
      attr_reader :path

      def initialize(text, path)
        @text = text
        @path = path
      end

      def read = @text
    end.new(text, "plan a")
  end

  def declared(text) = described_class.read(plan(text), layout:)

  describe ".of" do
    def carried(**fields) = Lain::Epic::Issue.new(id: "a", title: "A", **fields)

    it "answers the subject and level the issue carries" do
      result = described_class.of(carried(subject: "app/models/order.rb", level: "seam"), layout:)

      expect([result.subject, result.level]).to eq(["app/models/order.rb", "seam"])
    end

    it "carries Tested acceptance at the issue's level" do
      result = described_class.of(carried(subject: "app/models/order.rb", level: "seam"), layout:)

      expect(result.acceptance).to eq(Lain::CLI::EpicDriver::Acceptance::Tested.new(level: "seam"))
    end

    it "refuses an issue that carries no subject, naming the issue and the line to add" do
      expect { described_class.of(carried, layout:) }
        .to raise_error(described_class::Undeclared, /issue "a" declares no test subject.*Subject:/m)
    end

    it "refuses a subject that is not a plain relative path" do
      expect { described_class.of(carried(subject: "app/../etc/passwd.rb"), layout:) }
        .to raise_error(described_class::NotCanonical, /issue "a".*not a plain relative path/m)
    end

    it "refuses a subject under none of the declared source roots" do
      expect { described_class.of(carried(subject: "vendor/x.rb"), layout:) }
        .to raise_error(described_class::OutsideSourceRoots, /issue "a"/)
    end

    it "refuses a level the project does not declare" do
      expect { described_class.of(carried(subject: "app/models/order.rb", level: "nope"), layout:) }
        .to raise_error(described_class::Refusal, /issue "a".*level "nope"/m)
    end

    context "with the manual level, which no layout declares" do
      it "admits a script, a manifest or a spike outside every source root" do
        subjects = %w[scripts/fetch-models.sh Cargo.toml spike/src/main.rs]

        expect(subjects.map { |path| described_class.of(carried(subject: path, level: "manual"), layout:).subject })
          .to eq(subjects)
      end

      it "carries Manual acceptance with the commands its scenarios name, and compares no level itself" do
        criteria = "```gherkin\nScenario: it fetches\n  Then `scripts/fetch-models.sh --check` exits 0\n```"
        issue = carried(subject: "scripts/fetch-models.sh", level: "manual", criteria:)

        expect(described_class.of(issue, layout:).acceptance)
          .to eq(Lain::CLI::EpicDriver::Acceptance::Manual.new(commands: ["scripts/fetch-models.sh --check"]))
      end

      it "admits it when the project declares no layout at all" do
        result = described_class.of(carried(subject: "Cargo.toml", level: "manual"), layout: Lain::TestLayout::None)

        expect(result.level).to eq("manual")
      end

      it "still refuses a subject that is not a plain relative path" do
        expect { described_class.of(carried(subject: "../outside.sh", level: "manual"), layout:) }
          .to raise_error(described_class::NotCanonical, /issue "a"/)
      end
    end
  end

  it "reads the subject a plan declares, leaving the level to the layout's own default" do
    result = declared(<<~MD)
      # the a issue

      Subject: app/models/order.rb

      Then do the work.
    MD

    expect(result.subject).to eq("app/models/order.rb")
    expect(result.level).to be_nil
    expect([result.subject, result.level]).to eq(["app/models/order.rb", nil])
  end

  it "reads a level the plan declares beside its subject, backticks and emphasis aside" do
    result = declared("**Subject:** `app/models/order.rb`\nLevel: seam\n")

    expect([result.subject, result.level]).to eq(["app/models/order.rb", "seam"])
  end

  it "refuses a plan that declares no subject, naming the file and the line it must carry" do
    expect { declared("# the a issue\n\nDo the work.\n") }
      .to raise_error(described_class::Undeclared, /plan a.*Subject:/m)
  end

  it "refuses a plan declaring more than one subject, naming them" do
    expect { declared("Subject: app/models/order.rb\nSubject: app/cli/backend.rb\n") }
      .to raise_error(Lain::Error, /order\.rb.*backend\.rb/m)
  end

  it "refuses a subject under none of the declared source roots, naming the roots" do
    expect { declared("Subject: lib/order.rb\n") }
      .to raise_error(described_class::OutsideSourceRoots, %r{lib/order\.rb.*app}m)
  end

  it "refuses a level the [tests] table does not declare, naming the ones it does" do
    expect { declared("Subject: app/models/order.rb\nLevel: smoke\n") }
      .to raise_error(Lain::Error, /smoke.*unit.*seam/m)
  end

  # A subject names one file INSIDE the project. A path that walks out of its
  # source root places the generated test file outside the checkout entirely,
  # and the write-time guard lets a test written before its class through by
  # design, so nothing downstream would catch it.
  it "refuses a subject that walks out of its source root, naming it" do
    expect { declared("Subject: app/../../../../etc/passwd.rb\n") }
      .to raise_error(described_class::NotCanonical, %r{app/\.\./\.\.})
  end

  it "refuses every other non-canonical subject, before placement is asked at all" do
    ["./app/models/order.rb", "app//models/order.rb", "app/models/order.rb/", "/etc/passwd.rb",
     "~/order.rb", "-order.rb"].each do |subject|
      expect { declared("Subject: #{subject}\n") }
        .to raise_error(described_class::NotCanonical, /#{Regexp.escape(subject)}/)
    end
  end

  # A plan that SHOWS what a Subject line looks like has not declared one.
  it "reads no declaration from a line inside a fenced code block" do
    expect { declared("```\nSubject: app/models/order.rb\n```\n") }
      .to raise_error(described_class::Undeclared)
  end

  it "reads the declaration outside the fence, ignoring the example inside it" do
    result = declared("```\nSubject: app/models/example.rb\n```\n\nSubject: app/models/order.rb\n")

    expect(result.subject).to eq("app/models/order.rb")
  end

  # Tests are written before the code they describe, so the file the layout
  # mirrors from routinely does not exist yet.
  it "accepts a subject whose file does not exist yet, checking placement and never existence" do
    expect(declared("Subject: app/models/refund.rb\n").subject).to eq("app/models/refund.rb")
    expect(File.exist?(File.join(@root, "app/models/refund.rb"))).to be(false)
  end

  # A project with no [tests] table is refused by the test step, naming
  # [tests]; refusing here would name an empty list of roots instead.
  it "leaves placement to the test step when the project declares no layout at all" do
    result = described_class.read(plan("Subject: lib/order.rb\nLevel: smoke\n"), layout: Lain::TestLayout::None)

    expect([result.subject, result.level]).to eq(["lib/order.rb", "smoke"])
  end

  it "reads a manual plan's subject outside every source root" do
    expect(declared("Subject: scripts/fetch-models.sh\nLevel: manual\n").subject).to eq("scripts/fetch-models.sh")
  end

  it "is deeply frozen, as a value read from an approved plan" do
    expect(declared("Subject: app/models/order.rb\n")).to be_deeply_frozen
  end
end
