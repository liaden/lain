# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# What an issue's plan declares about where its failing tests go: the one source
# file they are written for, and optionally the level root they sit under. Read
# from `plans/<id>.md`, over a project declaring the rspec layout on `app`.
RSpec.describe Lain::CLI::EpicDriver::PlanSubject do
  let(:layout_mini) { File.expand_path("../../../fixtures/projects/layout_mini", __dir__) }
  let(:layout) { Lain::Config.test_layout(root: @root) }

  around do |example|
    Dir.mktmpdir("lain-plan-subject") do |dir|
      FileUtils.cp_r(File.join(layout_mini, "."), dir)
      @root = dir
      example.run
    end
  end

  # The artifact duck {Epic::Home#plan} answers: its bytes and where they live.
  def plan(text)
    Class.new do
      attr_reader :path

      def initialize(text, path)
        @text = text
        @path = path
      end

      def read = @text
    end.new(text, "/state/epics/demo/plans/a.md")
  end

  def declared(text) = described_class.read(plan(text), layout:)

  it "reads the subject a plan declares, leaving the level to the layout's own default" do
    result = declared(<<~MD)
      # the a issue

      Subject: app/models/order.rb

      Then do the work.
    MD

    expect(result.subject).to eq("app/models/order.rb")
    expect(result.level).to be_nil
    expect(result.to_h).to eq({ subject: "app/models/order.rb", level: nil })
  end

  it "reads a level the plan declares beside its subject, backticks and emphasis aside" do
    result = declared("**Subject:** `app/models/order.rb`\nLevel: seam\n")

    expect([result.subject, result.level]).to eq(["app/models/order.rb", "seam"])
  end

  it "refuses a plan that declares no subject, naming the file and the line it must carry" do
    expect { declared("# the a issue\n\nDo the work.\n") }
      .to raise_error(described_class::Undeclared, %r{plans/a\.md.*Subject:}m)
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

  it "is deeply frozen, as a value read from an approved plan" do
    expect(declared("Subject: app/models/order.rb\n")).to be_deeply_frozen
  end
end
