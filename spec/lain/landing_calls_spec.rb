# frozen_string_literal: true

require "prism"
require "pathname"

# Ratchet: a Landing call that omits facts: reads the live disk, so a replay
# or a test-layout run sees different symlinks than the Policy that judged it.
module LandingCalls
  ROOT = Pathname.new(File.expand_path("../..", __dir__))
  SOURCES = Dir[ROOT.join("lib/lain/**/*.rb")].map { Pathname.new(_1) }.freeze
  FACT_TAKING = %i[of eventual redirect].freeze
  OWN_FILE = "lib/lain/landing.rb"

  LIVE_BY_DESIGN = {
    "lib/lain/confine/profile.rb" => [1,
                                      "bounded? sizes a live sandbox build; the disk it reads is the one it confines"],
    "lib/lain/session.rb" => [1, "the checkout scope is built from the live project; the replay bench runs UNSCOPED"]
  }.freeze

  NOT_YET = {
    "lib/lain/approval/parked/path_gate.rb" => [1, "waits for the queue's file facts to reach the gate"],
    "lib/lain/frontend/approval_policy.rb" => [1, "waits for the queue's file facts to reach the display path"],
    "lib/lain/cli/wiring/board_build.rb" => [2, "waits for the policy's file facts to reach the board build"]
  }.freeze

  # path => [omitting call count, reason]; a count that moves either way fails
  ALLOWED = LIVE_BY_DESIGN.merge(NOT_YET).freeze

  Call = Data.define(:path, :line, :name, :facts)

  class Scanner < Prism::Visitor
    attr_reader :calls

    def initialize(path, source)
      @path = path
      @own_class = source.match?(/^\s*class Landing\b/)
      @calls = []
      super()
    end

    def visit_call_node(node)
      @calls << call(node) if FACT_TAKING.include?(node.name) && landing?(node.receiver)
      super
    end

    private

    # forge/ and epic_driver/factory.rb define their own Landing, which has no facts: keyword.
    def landing?(receiver)
      case receiver
      when Prism::ConstantReadNode then receiver.name == :Landing && !@own_class
      when Prism::ConstantPathNode then qualified?(receiver)
      else false
      end
    end

    def qualified?(path)
      path.name == :Landing && lain?(path.parent)
    end

    def lain?(node)
      case node
      when Prism::ConstantReadNode then node.name == :Lain
      when Prism::ConstantPathNode then node.name == :Lain && node.parent.nil?
      else false
      end
    end

    def call(node)
      keywords = (node.arguments&.arguments || []).grep(Prism::KeywordHashNode).flat_map(&:elements)
      names = keywords.filter_map { _1.key.unescaped.to_sym if _1.respond_to?(:key) && _1.key.is_a?(Prism::SymbolNode) }
      Call.new(@path, node.location.start_line, node.name, names.include?(:facts))
    end
  end

  def self.calls
    SOURCES.flat_map do |path|
      relative = path.relative_path_from(ROOT).to_s
      next [] if relative == OWN_FILE

      source = path.read
      scanner = Scanner.new(relative, source)
      Prism.parse(source).value.accept(scanner)
      scanner.calls
    end
  end
end

RSpec.describe "Landing calls in lib" do
  let(:calls) { LandingCalls.calls }
  let(:omitted) { calls.reject(&:facts).map(&:path).tally }

  it "finds the calls it polices" do
    expect(calls.map(&:name).uniq).to include(:of, :eventual, :redirect)
  end

  it "omits facts: in exactly the allowlisted number of calls per file" do
    expect(omitted).to eq(LandingCalls::ALLOWED.transform_values(&:first))
  end

  it "gives every allowlist entry a reason" do
    expect(LandingCalls::ALLOWED.values.map(&:last)).to all(be_a(String).and(satisfy { !_1.strip.empty? }))
  end
end
