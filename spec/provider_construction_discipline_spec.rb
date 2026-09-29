# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of the rule that a provider which reaches a real model
# endpoint may only be built where somebody has written down why, and may not be
# built somewhere its round trips reach no journal.
#
# The defect this exists to end is not a bug, it is a SHAPE: a capability built,
# spec'd, and then never constructed on the production path. A whole QA round
# was measured whose journals held zero records for oracle traffic the run
# really paid for, because {Lain::Oracle::Model} calls `#complete` directly and
# no middleware sits anywhere near it. Fixing the three instances is one thing;
# this file is what makes the FOURTH one fail the build instead of shipping
# green. A grep for a constant cannot do it -- `provider/admission.rb` mentions
# `Provider::Ollama.new` in a comment, and a comment is not a construction.
#
# Robustness comes from the same place `output_discipline_spec.rb` gets it: the
# source is parsed with Ripper and the SYNTAX TREE is inspected, so the names
# are never matched inside comments or string literals, and a receiver that
# merely reads a constant (`Provider::Ollama::DEFAULT_MODEL`, which is
# `oracle/secret_read.rb`'s default argument) is not mistaken for a
# construction. Which selectors ARE a construction is {FACTORY_SELECTORS}.
#
# == Why the scope is a class list and not an allowlist
#
# Only providers that reach a real endpoint are in scope. The other two are
# excluded BY CLASS, with reasons, rather than by allowlist entries -- which is
# what keeps the list below at two files instead of four:
#
#   * {Lain::Provider::Mock} never touches HTTP, so a mock-backed bench or spec
#     cannot leave an unjournaled round trip. It is constructed freely and
#     legitimately, and a rule it had to be excused from every time would be a
#     rule nobody trusts.
#   * `Provider::Recorded` does not exist in `lib/`.
#
# == The two journals, which are not the same journal
#
# `journal:` on {Lain::Provider::Ollama} and {Lain::Provider::Anthropic} is where
# a {Lain::Telemetry::ProviderWait} lands -- endpoint contention, reached through
# {Lain::Provider::Admitted#admitted}, which both include. The
# {Lain::Provider::Journaled} decorator is where a
# {Lain::Telemetry::RequestSent} lands -- the round trip itself.
#
# The journal rule below accepts EITHER, and it is worth being exact about how
# weak that makes it. At `cli/backend.rb` a `journal:` proves only that a WAIT
# journal is reachable; the `RequestSent` for an agent turn comes from
# {Lain::Middleware::JournalRequests}, which is a per-experiment wiring decision
# living outside this walk entirely. So the rule reads "this construction
# reaches a journal at all", never "this construction is fully recorded".
#
# For the same reason `Provider::Ollama.new(journal: nil)` satisfies the rule.
# That is consistent rather than sloppy -- it is the endpoint arm of the same
# position the decorator rule takes below, that a STATED Null is a decision a
# reader can see and a DEFAULTED one is not -- but it does mean the rule checks
# that somebody answered the question, not that they answered it well.
#
# == What this does NOT check, said out loud
#
#   * **WHICH provider an oracle tier is handed.** The tier rule below is
#     file-level: it asks that a file building an {Lain::Oracle::Model}
#     construct a provider somewhere in the same file. It does NOT follow the
#     local variable from the construction to the keyword, so a file that builds
#     one journaled provider and hands a DIFFERENT, unjournaled one to its
#     `Oracle::Model` would pass. Closing that needs local-variable resolution
#     inside a method body, which is the genuinely expensive part; the
#     file-level rule was measured to close the case that matters -- a tier
#     constructing no provider at all -- for nothing.
#   * **A double-splatted argument list.** `Provider::Ollama.new(**opts)` parses
#     to an `assoc_splat` with no label, so the journal keyword reads as absent
#     and the site is flagged. There is no such site today; if one appears, the
#     flag is a fair question rather than a false positive, because a forwarded
#     hash is exactly where a `journal:` goes missing unnoticed.
#   * **A bare constant outside `lain/provider/`.** See {Scanner#provider_constant}.
#   * **A factory this file has not heard of.** {FACTORY_SELECTORS} is a
#     hand-maintained list of NAMES, with no link to the singleton methods a
#     provider actually defines. A factory under an unknown name produces no
#     {Site} at all, so its file needs no allowlist entry and every rule here
#     passes by ABSENCE -- green, and failed open. The tree-level example
#     "classifies every singleton method an endpoint provider defines" is what
#     makes that drift loud. It reads the singleton methods DEFINED ON an
#     {ENDPOINT_PROVIDERS} class or on the {Lain::Provider} base all three
#     inherit from -- however they were defined, `def self.` and
#     `define_singleton_method` alike. What still escapes it is a method the
#     class did not define but can answer: one reached through an `extend`ed
#     module, or inherited from further up the ancestry than that base. Either
#     would be a live factory this guard cannot see.
# The READING half: source text in, {Site} values out. It knows Ripper and
# the shape of a construction, and nothing whatever about which ones are
# allowed -- that is {ProviderConstructionDiscipline}'s job below. The split
# is what lets the policy be exercised against literal fixtures without a
# parser in the way, and it follows `bin/spec-census`, which carries five
# cooperating modules for the same reason.
module ProviderConstruction
  ENDPOINT_PROVIDERS = %w[Anthropic Ollama].freeze

  # The decorator that records a round trip. Constructing THIS is the fix, never
  # the defect -- so it needs no approval, only its own rule below.
  JOURNALING_DECORATOR = "Journaled"

  # Every class name this scan reacts to at all.
  PROVIDER_CLASSES = (ENDPOINT_PROVIDERS + [JOURNALING_DECORATOR]).freeze

  # Every spelling of a construction: `.new`, plus the intention-revealing
  # factories a provider offers for its deployments. A factory is invisible to a
  # rule that matches `.new` alone, so the file holding one would silently stop
  # being covered by the allowlist -- a guard that fails open and looks green.
  #
  # `local` and `cloud` are singleton methods on the PROVIDER class, and are not
  # the `Deployment.local` / `Deployment.cloud` value constructors that share the
  # words -- those are a different thing, constructed nowhere this guard looks.
  #
  # Named one at a time rather than "any method on a provider constant", which
  # is shorter and wrong: the broad rule reads a class-level reader or a
  # predicate as a construction, and this guard is worth exactly as much as the
  # next person's lack of a reason to excuse it.
  FACTORY_SELECTORS = %w[new local cloud].freeze

  # The oracle round trip nothing else records. {Lain::Oracle::Model} calls
  # `#complete` directly, with no middleware stack anywhere near it, which is
  # exactly why the decorator had to exist.
  ORACLE_MODEL = "Model"

  # Files under here may name the oracle model without its `Oracle::` qualifier.
  # The narrowness is load-bearing rather than tidy: `cli/command/model.rb`
  # declares a SECOND class called `Model` and `cli/command/surface.rb`
  # constructs it bare, so a rule matching `Model.new` everywhere would flag a
  # command registry as an unprovisioned oracle tier.
  ORACLE_NAMESPACE = "lain/oracle/"

  JOURNAL_KEYWORD = "journal:"
  PROVIDER_KEYWORD = "provider:"

  # Files under here may name a provider constant without the `Provider::`
  # qualifier, because they are lexically inside it.
  PROVIDER_NAMESPACE = "lain/provider/"

  # One construction on a provider constant, with everything the rules ask
  # about it. `position` is the selector token's own `[line, column]`, which is
  # both how a construction is deduplicated across the nested Ripper nodes that
  # describe it and how a wrapped provider is matched to the decorator wrapping
  # it.
  Site = Struct.new(:path, :constant, :position, :journal_keyword, :wrapped, keyword_init: true) do
    def line = position.first
    def provider? = constant.start_with?("Provider::")
    def decorator? = constant == "Provider::#{JOURNALING_DECORATOR}"
    def oracle? = constant == "Oracle::#{ORACLE_MODEL}"
    def endpoint? = provider? && !decorator?
    def journaled? = journal_keyword || wrapped
  end

  # A single detected violation, with enough context to fix it. `line` is nil
  # for a stale allowlist entry, which is a claim about the list rather than
  # about a line of code.
  Violation = Struct.new(:path, :line, :message) do
    def to_s
      where = line.nil? ? path : "#{path}:#{line}"
      "#{where} -> #{message}"
    end
  end

  # Walks one file's Ripper s-expression collecting provider constructions.
  class Scanner
    def initialize(path)
      @path = path
      @in_provider_namespace = path.start_with?(PROVIDER_NAMESPACE)
      @in_oracle_namespace = path.start_with?(ORACLE_NAMESPACE)
      @sites = []
      @wrapped_positions = []
      @seen_positions = []
    end

    # @return [Array<Site>] every provider construction in this file
    def scan(source)
      sexp = Ripper.sexp(source)
      raise "could not parse #{@path}" if sexp.nil?

      walk(sexp)
      @sites.each { |site| site.wrapped = @wrapped_positions.include?(site.position) }
      @sites
    end

    private

    def walk(node)
      return unless node.is_a?(Array)

      inspect_node(node)
      node.each { |child| walk(child) }
    end

    # Pre-order matters here. A parenthesised call is `[:method_add_arg, [:call,
    # ...], args]`, so the wrapper -- the only node that can see the argument
    # list -- is visited before the `[:call, ...]` it contains, and the bare
    # `:call` arm below then skips a position already recorded. Without that,
    # every construction with arguments is counted twice.
    def inspect_node(node)
      case node[0]
      when :method_add_arg then record(node[1], node[2])
      when :command_call then record([:call, node[1], node[2], node[3]], node[4])
      when :call then record(node, nil)
      end
    end

    def record(call, args)
      position = construction_token_position(call)
      return if position.nil? || @seen_positions.include?(position)

      @seen_positions << position
      constant = tracked_constant(call[1])
      return if constant.nil?

      @sites << Site.new(path: @path, constant:, position:, wrapped: false,
                         journal_keyword: keyword?(args, JOURNAL_KEYWORD))
      note_wrapped_provider(args) if constant == "Provider::#{JOURNALING_DECORATOR}"
    end

    # Either kind of construction this file reasons about, or nil.
    def tracked_constant(receiver) = provider_constant(receiver) || oracle_constant(receiver)

    # `Oracle::Model`, however it was spelled. Bare only inside `lain/oracle/`,
    # for the reason {ORACLE_NAMESPACE} records: a second, unrelated `Model` is
    # constructed bare in `cli/command/surface.rb`.
    def oracle_constant(receiver)
      path = const_path(receiver)
      return nil unless path.is_a?(Array) && path.last == ORACLE_MODEL
      return nil unless (path.size >= 2 && path[-2] == "Oracle") ||
                        (path.size == 1 && @in_oracle_namespace)

      "Oracle::#{ORACLE_MODEL}"
    end

    # The `[line, column]` of the selector in a construction, or nil for any
    # other call. Doubles as the identity a construction is deduplicated by.
    def construction_token_position(call)
      return nil unless call.is_a?(Array) && call[0] == :call

      ident = call[3]
      return nil unless ident.is_a?(Array) && ident[0] == :@ident &&
                        FACTORY_SELECTORS.include?(ident[1])

      ident[2]
    end

    # The provider this receiver names, normalized to `Provider::Ollama` however
    # it was spelled (`Provider::Ollama`, `Lain::Provider::Ollama`, or
    # `::Lain::Provider::Ollama`).
    #
    # A one-segment path is accepted only inside `lain/provider/`, and the
    # narrowness is load-bearing rather than lazy: `core/transport/vsock.rb`
    # raises `Unreachable.new(far_end, e)`, which is that transport's own error
    # and not the provider. The same qualifier rule is what keeps
    # `Forge::Journaled` and `Epic::Home::Journaled` -- two unrelated classes
    # sharing a name -- out of the decorator rule. The
    # cost is that a bare `Ollama.new` written outside `lain/provider/` would be
    # missed, which no file does and which the require manifest makes unlikely.
    def provider_constant(receiver)
      path = const_path(receiver)
      return nil unless provider_name?(path) && qualified_here?(path)

      "Provider::#{path.last}"
    end

    def provider_name?(path) = path.is_a?(Array) && PROVIDER_CLASSES.include?(path.last)

    def qualified_here?(path)
      (path.size >= 2 && path[-2] == "Provider") || (path.size == 1 && @in_provider_namespace)
    end

    def const_path(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :@const then [node[1]]
      when :var_ref, :const_ref, :top_const_ref then const_path(node[1])
      when :const_path_ref then const_path_ref_path(node)
      end
    end

    def const_path_ref_path(node)
      prefix = const_path(node[1])
      suffix = const_path(node[2])
      prefix && suffix && (prefix + suffix)
    end

    # A provider constructed as the `provider:` argument of a decorator is
    # journaled by the decorator, so its position is remembered and read back
    # once the walk is done -- the two nodes are visited in whichever order the
    # source happens to nest them.
    def note_wrapped_provider(args)
      wrapped = keyword_value(args, PROVIDER_KEYWORD)
      position = construction_token_position(call_node(wrapped))
      @wrapped_positions << position unless position.nil?
    end

    # A construction may arrive bare, parenthesised, or with a block; all three
    # carry the same `[:call, ...]` somewhere obvious.
    def call_node(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :call then node
      when :method_add_arg, :method_add_block then call_node(node[1])
      end
    end

    def keyword?(args, label) = keyword_labels(args).include?(label)

    def keyword_value(args, label)
      found = top_level_assocs(args).find { |assoc| assoc_label(assoc) == label }
      found && found[2]
    end

    def keyword_labels(args) = top_level_assocs(args).filter_map { |assoc| assoc_label(assoc) }

    def assoc_label(assoc)
      return nil unless assoc.is_a?(Array) && assoc[0] == :assoc_new

      label = assoc[1]
      label[1] if label.is_a?(Array) && label[0] == :@label
    end

    # Only THIS call's own keywords. A nested construction carries its own
    # `bare_assoc_hash`, and a walk deep enough to find it would read the inner
    # call's `journal:` as the outer call's.
    def top_level_assocs(args)
      argument_list(args)
        .select { |argument| argument.is_a?(Array) && argument[0] == :bare_assoc_hash }
        .flat_map { |hash| hash[1] }
    end

    def argument_list(args)
      node = args
      node = node[1] if node.is_a?(Array) && node[0] == :arg_paren
      node = node[1] if node.is_a?(Array) && node[0] == :args_add_block
      node.is_a?(Array) ? node : []
    end
  end

  module_function

  def lib_root = Pathname(__dir__).join("..", "lib").expand_path

  # `{ path relative to lib/ => source }`. Taking the tree as data rather than
  # globbing inside the scanner is what lets the rules below be exercised
  # against literal fixtures, which is the only way to prove this guard can
  # still fail.
  def lib_sources(root = lib_root)
    root.glob("**/*.rb").to_h { |file| [file.relative_path_from(root).to_s, file.read] }
  end

  def sites(sources) = sources.flat_map { |path, source| Scanner.new(path).scan(source) }
end

# The POLICY half: {Site} values in, {ProviderConstruction::Violation} values
# out. Every judgment this file makes lives here, next to the allowlist it
# reads, and none of it can see a syntax tree.
module ProviderConstructionDiscipline
  # The reading half's vocabulary, named here so a rule below reads as a rule
  # rather than as a reach across the boundary on every line.
  Violation = ProviderConstruction::Violation
  ORACLE_MODEL = ProviderConstruction::ORACLE_MODEL
  JOURNALING_DECORATOR = ProviderConstruction::JOURNALING_DECORATOR
  JOURNAL_KEYWORD = ProviderConstruction::JOURNAL_KEYWORD

  # Every place in `lib/` allowed to construct an endpoint-reaching provider,
  # and which one, and why. Keyed by class as well as by file because the CLASS
  # is the property worth pinning at the second site: a hosted provider
  # appearing in the secret-read arm is a security defect, not a wiring choice.
  #
  # Paths are relative to `lib/`. If this grows past a handful of entries the
  # seam is wrong and wants an object, not another line.
  APPROVED = {
    "lain/cli/backend.rb" => {
      "Provider::Anthropic" =>
        "the run's hosted arm. #anthropic_provider is its only builder and hands it the run's journal."
    }.freeze,
    "lain/cli/backend/ollama_tier.rb" => {
      "Provider::Ollama" =>
        "BOTH ollama arms, local and cloud, and one entry because the allowlist normalizes a " \
        "class to one constant however it is spelled. The tier is where --provider ollama / " \
        "ollama-cloud is turned into a deployment, so it is also where the run's journal is " \
        "attached to either. It moved OUT of cli/backend.rb rather than being added beside it: " \
        "two files allowed to build the same provider is the drift this list exists to refuse."
    }.freeze,
    "lain/oracle/secret_read.rb" => {
      "Provider::Ollama" =>
        "the secret-read judge is a LOCAL model and must never be anything else. Naming the class " \
        "is the point of this entry: it is what refuses a hosted provider at the one site in lib/ " \
        "that could introduce one, at any decorator depth, without running anything."
    }.freeze
  }.freeze

  # Approved constructions that reach no journal, and why that is tolerable
  # today. An entry here is a stated hole, which is the difference between a
  # gap somebody decided to live with and a gap nobody noticed. Empty because
  # every endpoint-reaching construction in `lib/` now names a journal, which
  # is the state this rule is for -- an empty list is the rule biting, not the
  # rule switched off. The cost of the emptiness is that `#excused?`'s true
  # branch has no live case, so the first entry added here is also the first
  # exercise of it.
  UNJOURNALED = {}.freeze

  # Singleton methods on an endpoint-reaching provider that build no provider,
  # and why each is not a construction. Shape:
  #
  #   "Provider::Ollama" => { "probe" => "asks /api/tags what exists; builds nothing" }
  #
  # Empty because neither the two classes nor the base they inherit from
  # defines a singleton method at all today. The emptiness is a pin rather than
  # a gap -- see the tree-level example that reads this, which is what stops a
  # factory landing under a name {ProviderConstruction::FACTORY_SELECTORS} has
  # never heard of. A value here must be a non-empty String: the reason IS the
  # entry, and a key with nothing written against it excuses nothing.
  NON_CONSTRUCTING_SINGLETONS = {}.freeze

  module_function

  def violations(sources = ProviderConstruction.lib_sources)
    found = ProviderConstruction.sites(sources)
    construction_violations(found) + decorator_violations(found) +
      tier_violations(found) + stale_entry_violations(found)
  end

  def construction_violations(found)
    found.select(&:endpoint?).filter_map { |site| construction_violation(site) }
  end

  def construction_violation(site)
    return unapproved(site) unless approved?(site)
    return nil if site.journaled? || excused?(site)

    Violation.new(site.path, site.line, "constructs #{site.constant} with no journal")
  end

  # Two different refusals, because they send a reader to two different places.
  # A file nobody approved is a question about the wiring; an approved file
  # naming an unapproved CLASS is a question about that class, and the reasons
  # already written down are the fastest way to answer it -- so they are
  # printed here rather than left as data nothing ever reads.
  def unapproved(site)
    permitted = APPROVED[site.path]
    return nowhere_approved(site) if permitted.nil?

    listing = permitted.map { |constant, reason| "#{constant} -- #{reason}" }.join("; ")
    Violation.new(site.path, site.line,
                  "constructs #{site.constant}, which is not approved in this file " \
                  "(approved here: #{listing})")
  end

  def nowhere_approved(site)
    Violation.new(site.path, site.line,
                  "constructs #{site.constant}, and no provider construction is approved in this file")
  end

  def approved?(site) = !APPROVED.dig(site.path, site.constant).nil?

  def excused?(site) = !UNJOURNALED.dig(site.path, site.constant).nil?

  # An oracle tier's round trip is the one nothing else records, so a file that
  # builds an {Lain::Oracle::Model} must build the provider it hands over, where
  # the rules above can see it. A tier that took a ready-made provider from a
  # collaborator would construct nothing and slip past every other rule here --
  # which is exactly how the gap this whole file answers came to exist.
  #
  # File-level on purpose. Following the local variable from the construction to
  # the keyword needs resolution inside a method body; measured against the
  # tree, all three files that build an Oracle::Model construct a provider
  # themselves, so the cheap rule costs nothing and catches the case that
  # matters. What it does not catch is named in the header.
  def tier_violations(found)
    builds_provider = found.select(&:provider?).map(&:path).uniq
    found.select(&:oracle?).reject { |site| builds_provider.include?(site.path) }.map do |site|
      Violation.new(site.path, site.line,
                    "builds an Oracle::#{ORACLE_MODEL} but constructs no provider in this file, " \
                    "so nothing here can show its round trip reaches a journal")
    end
  end

  # The decorator's own `journal:` defaults to the Null channel, so
  # `Provider::Journaled.new(provider: x)` is a fully built recorder that records
  # nothing -- the same silence one object deeper, which is the shape this whole
  # file exists to catch. An EXPLICIT Null stays legal: a stated Null is a
  # decision a reader can see, and that is the entire difference from a default.
  def decorator_violations(found)
    found.select(&:decorator?).reject(&:journal_keyword).map do |site|
      Violation.new(site.path, site.line,
                    "builds Provider::#{JOURNALING_DECORATOR} without naming #{JOURNAL_KEYWORD}")
    end
  end

  # An allowlist entry that no longer matches a construction has outlived the
  # decision it recorded, and a stale exemption reads to the next person as
  # "this was considered and is fine".
  def stale_entry_violations(found)
    live = found.map { |site| [site.path, site.constant] }
    [["APPROVED", APPROVED], ["UNJOURNALED", UNJOURNALED]].flat_map do |name, list|
      list.flat_map do |path, constants|
        constants.keys.reject { |constant| live.include?([path, constant]) }
                 .map do |constant|
          Violation.new(path, nil,
                        "#{name} names #{constant}, which is constructed nowhere")
        end
      end
    end
  end
end

RSpec.describe "provider construction discipline" do
  # Every class whose singleton methods could be a construction: the endpoint
  # providers, and the base they inherit from.
  def reflected_providers
    ProviderConstruction::ENDPOINT_PROVIDERS
      .map { |name| ["Provider::#{name}", Lain::Provider.const_get(name, false)] }
      .unshift(["Provider", Lain::Provider])
  end

  def unclassified_singletons(constant, klass)
    klass.singleton_class.public_instance_methods(false).map(&:to_s).sort
         .reject { |method| ProviderConstruction::FACTORY_SELECTORS.include?(method) }
         .reject { |method| non_constructing?(constant, method) }
         .map { |method| "#{constant}.#{method}" }
  end

  # A WRITTEN reason, not merely a key. Presence alone would let `=> false` or
  # `=> ""` excuse a real factory with no justification, and read as green --
  # the entry has to say something for the exemption to count.
  def non_constructing?(constant, method)
    reason = ProviderConstructionDiscipline::NON_CONSTRUCTING_SINGLETONS.dig(constant, method)

    reason.is_a?(String) && !reason.strip.empty?
  end

  describe "the tree as it stands" do
    it "constructs an endpoint-reaching provider only where the allowlist says, and only with a journal" do
      violations = ProviderConstructionDiscipline.violations

      expect(violations).to be_empty, lambda {
        listing = violations.map { |violation| "  #{violation}" }.join("\n")
        "A provider that reaches a real model endpoint may only be built at an approved site, " \
          "and only where its round trips reach a journal. Found:\n#{listing}\n" \
          "Pass journal:, or wrap the provider in Provider::Journaled, or -- if the construction " \
          "is right and the gap is deliberate -- add a reasoned entry to " \
          "ProviderConstructionDiscipline::APPROVED / ::UNJOURNALED."
      }
    end

    it "keeps the allowlist small enough that it is still a list of exceptions" do
      # Not style, and not a counter for its own sake. This is an escalation
      # trigger with a threshold: a list that grows past a handful is evidence
      # the SEAM is in the wrong place, and the answer is an object, not another
      # entry. The ceilings sit one file and two sites above today's 2 and 4, so
      # a genuinely new arm lands without ceremony and a third one has to argue.
      approved = ProviderConstructionDiscipline::APPROVED
      escalate = "The allowlist has outgrown being a list of exceptions. Adding another entry is " \
                 "the wrong move: an allowlist this size says the seam is in the wrong place, and " \
                 "the fix is a collaborator that owns provider construction, not one more line " \
                 "here. Raise these ceilings only alongside that argument."

      expect(approved.keys.size).to(be <= 3, escalate)
      expect(approved.values.sum(&:size)).to(be <= 6, escalate)
    end

    it "keeps the non-constructing exemptions small enough to stay exceptions" do
      # The same escalation trigger APPROVED carries, for the same reason. This
      # list is the one place a factory can be excused from the guard, so it is
      # also the one place the guard can be hollowed out an entry at a time.
      # The ceilings sit above an empty list rather than a populated one: a
      # provider or two growing a class-level method that builds nothing is
      # unremarkable, but a guard needing exemptions on every class is a guard
      # asking the wrong question.
      exemptions = ProviderConstructionDiscipline::NON_CONSTRUCTING_SINGLETONS
      escalate = "The non-constructing exemptions have outgrown being exceptions. Each one is a " \
                 "class method the construction guard agrees not to look at, so a list this size " \
                 "says the guard is asking the wrong question -- the fix is a narrower rule, not " \
                 "one more excused name. Raise these ceilings only alongside that argument."

      expect(exemptions.keys.size).to(be <= 2, escalate)
      expect(exemptions.values.sum(&:size)).to(be <= 3, escalate)
    end

    it "counts an exemption only when it carries a written reason" do
      # Without this the reason field is decorative: `=> false` or `=> ""`
      # would excuse a real factory, and nothing would ever say so.
      stub_const("ProviderConstructionDiscipline::NON_CONSTRUCTING_SINGLETONS",
                 { "Provider::Ollama" => { "hollow" => "", "probe" => "reads /api/tags; builds nothing" } })

      expect(non_constructing?("Provider::Ollama", "hollow")).to be(false)
      expect(non_constructing?("Provider::Ollama", "probe")).to be(true)
    end

    it "classifies every singleton method an endpoint provider defines" do
      # The link FACTORY_SELECTORS does not have. That list is hand-maintained
      # NAMES, so a factory added under a name it does not carry builds a
      # provider that produces no Site -- its file then needs no allowlist
      # entry and every rule above passes by absence. This refuses to let such
      # a method exist unclassified: a construction is added to
      # FACTORY_SELECTORS, and anything else to NON_CONSTRUCTING_SINGLETONS
      # with the reason it is not one. Vacuously true today, which is the only
      # honest state for it while none of these classes defines one.
      #
      # The BASE is in the set for a measured reason: all three providers
      # subclass Lain::Provider, and an inherited singleton is not visible to
      # `public_instance_methods(false)` on the subclass. A `def self.hosted`
      # written once on the base makes Provider::Ollama.hosted a live factory
      # while every subclass still reflects as empty -- which is this pin's own
      # fail-open shape, relocated one class up, and the likeliest place a
      # shared factory would really be written.
      unclassified = reflected_providers.flat_map do |constant, klass|
        unclassified_singletons(constant, klass)
      end

      expect(unclassified).to be_empty, lambda {
        "A provider gained a singleton method this guard cannot classify: " \
          "#{unclassified.join(", ")}. If it builds a provider, add its name to " \
          "ProviderConstruction::FACTORY_SELECTORS -- otherwise every file calling it becomes " \
          "invisible to the allowlist. If it builds nothing, say so in " \
          "ProviderConstructionDiscipline::NON_CONSTRUCTING_SINGLETONS with the reason."
      }
    end

    it "still sees the constructions the allowlist was written for" do
      # The pin under the selector list. Every rule above is stated as an
      # ABSENCE of violations, so a detector that stopped recognizing a
      # construction would pass all of them by vacuum. Spelled out here rather
      # than derived from APPROVED, so that deleting a row cannot quietly
      # delete the assertion that the row was ever matched.
      live = ProviderConstruction.sites(ProviderConstruction.lib_sources)
                                 .select(&:endpoint?).map { |site| [site.path, site.constant] }

      expect(live).to include(
        %w[lain/cli/backend.rb Provider::Anthropic],
        %w[lain/cli/backend/ollama_tier.rb Provider::Ollama],
        %w[lain/oracle/secret_read.rb Provider::Ollama]
      )

      # BOTH ollama doors, not one. The tier picks between `.local` and
      # `.cloud` on a `--provider` name, and a detector that saw only the
      # branch it happened to visit first would leave the other one
      # unallowlisted and invisible -- which is the vacuum this example exists
      # to refuse. They collapse to one APPROVED entry (the list normalizes a
      # class to one constant); they must not collapse to one SITE.
      expect(live.count(%w[lain/cli/backend/ollama_tier.rb Provider::Ollama])).to eq(2)
    end
  end

  describe ProviderConstruction::Scanner do
    def scan(source, path: "lain/wiring.rb") = described_class.new(path).scan(source)

    # Each rule is exercised on its own, against a literal fixture tree. Going
    # through the whole-tree entry point instead would mix in a stale-entry
    # violation for every real allowlist row, since a one-file fixture
    # constructs none of them.
    def sites_for(source, path) = ProviderConstruction.sites(path => source)

    def construction_violations_for(source, path: "lain/wiring.rb")
      ProviderConstructionDiscipline.construction_violations(sites_for(source, path))
    end

    def decorator_violations_for(source, path: "lain/wiring.rb")
      ProviderConstructionDiscipline.decorator_violations(sites_for(source, path))
    end

    def tier_violations_for(source, path: "lain/wiring.rb")
      ProviderConstructionDiscipline.tier_violations(sites_for(source, path))
    end

    it "finds a qualified construction and reads its keywords" do
      site = scan("Provider::Ollama.new(api_base: base, journal: run_journal)\n").first

      expect(site.constant).to eq("Provider::Ollama")
      expect(site.line).to eq(1)
      expect(site.journal_keyword).to be(true)
    end

    it "reads a construction spelled without parentheses" do
      expect(scan("Provider::Ollama.new api_base: base\n").first.journal_keyword).to be(false)
    end

    it "reads a construction with no arguments at all" do
      expect(scan("Provider::Ollama.new\n").first.journal_keyword).to be(false)
    end

    it "counts a parenthesised construction once, not once per Ripper node" do
      expect(scan("Provider::Ollama.new(journal: j)\n").size).to eq(1)
    end

    it "reads a factory construction and its keywords" do
      site = scan("Provider::Ollama.cloud(api_base: base, journal: run_journal)\n").first

      expect(site.constant).to eq("Provider::Ollama")
      expect(site.line).to eq(1)
      expect(site.journal_keyword).to be(true)
    end

    it "reads every named factory selector, and no other method on a provider constant" do
      # A NAMED list rather than "any method on a provider constant". The broad
      # match would read a predicate and a class-level reader as constructions,
      # and a guard with false positives is a guard that gets excused -- which
      # is the failure mode this file's header already worries about.
      expect(scan("Provider::Ollama.new\nProvider::Ollama.local\nProvider::Ollama.cloud\n").size).to eq(3)
      expect(scan("Provider::Ollama.default_model\nProvider::Ollama.local?\nProvider::Ollama.build(x)\n"))
        .to be_empty
    end

    it "ignores a factory named in a comment" do
      expect(scan("# the cloud arm is built by Provider::Ollama.cloud, one tier down\n")).to be_empty
    end

    it "normalizes a fully qualified and a root-qualified constant to the same name" do
      constants = scan("::Lain::Provider::Ollama.new\nLain::Provider::Anthropic.new\n").map(&:constant)

      expect(constants).to eq(%w[Provider::Ollama Provider::Anthropic])
    end

    it "sees a provider wrapped by the decorator as journaled" do
      sites = scan("Provider::Journaled.new(provider: Provider::Ollama.new, journal: j)\n")
      wrapped = sites.find { |site| site.constant == "Provider::Ollama" }

      expect(wrapped.journal_keyword).to be(false)
      expect(wrapped).to be_journaled
    end

    it "does not read a nested call's journal keyword as the outer call's" do
      sites = scan("Provider::Journaled.new(provider: Provider::Ollama.new(journal: inner))\n")

      expect(sites.find(&:decorator?).journal_keyword).to be(false)
    end

    it "ignores a constant that is read rather than constructed" do
      # Load-bearing twice over: widening `.new` into a list of selector NAMES
      # must not widen it into a constant read, and this is the only example
      # that says so. Weaken it and the factory rule loses its floor.
      expect(scan("model = Provider::Ollama::DEFAULT_MODEL\n")).to be_empty
    end

    it "ignores comments and string literals naming a construction" do
      source = <<~RUBY
        # the BARE `Provider::Ollama.new` this endpoint resolves
        advice = "call Provider::Anthropic.new(channel:) instead"
      RUBY

      expect(scan(source)).to be_empty
    end

    it "ignores the provider that cannot make a round trip" do
      expect(scan("Provider::Mock.new(responses:)\n")).to be_empty
    end

    it "ignores an unrelated class that merely shares a provider's name" do
      # `Vsock` raises its own `Unreachable`, and three separate classes in lib/
      # are called `Journaled`. Requiring the `Provider::` qualifier is what
      # keeps all four out of this scan.
      source = "raise Unreachable.new(far_end, e)\nForge::Journaled.new(github, journal:)\n"

      expect(scan(source)).to be_empty
    end

    it "reads a bare constant as a provider only inside the provider namespace" do
      expect(scan("Ollama.new(journal: j)\n", path: "lain/provider/pool.rb").first.constant)
        .to eq("Provider::Ollama")
      expect(scan("Ollama.new(journal: j)\n", path: "lain/cli/backend.rb")).to be_empty
    end

    it "reports a construction in a file where nothing is approved, by file and line" do
      found = construction_violations_for("class Wiring\n  def build = Provider::Anthropic.new(channel:)\nend\n")

      expect(found.map(&:to_s)).to eq(
        ["lain/wiring.rb:2 -> constructs Provider::Anthropic, and no provider construction " \
         "is approved in this file"]
      )
    end

    it "reports a factory construction in a file where nothing is approved, by file and line" do
      found = construction_violations_for("class Wiring\n  def build = Provider::Ollama.cloud(journal:)\nend\n")

      expect(found.map(&:to_s)).to eq(
        ["lain/wiring.rb:2 -> constructs Provider::Ollama, and no provider construction " \
         "is approved in this file"]
      )
    end

    it "reports a hosted provider introduced into the secret-read arm, quoting what IS approved" do
      # The security half of the class-level allowlist: this file may name
      # Provider::Ollama and nothing else, at any decorator depth, and a journal
      # keyword does not buy its way past that. The refusal has to read
      # differently from the one above -- the FILE is approved here, the class is
      # not -- and it carries the written reason to whoever tripped it.
      found = construction_violations_for("Provider::Anthropic.new(journal:)\n",
                                          path: "lain/oracle/secret_read.rb")

      expect(found.map(&:to_s).first).to start_with(
        "lain/oracle/secret_read.rb:1 -> constructs Provider::Anthropic, which is not approved " \
        "in this file (approved here: Provider::Ollama -- the secret-read judge is a LOCAL model"
      )
    end

    it "reports an oracle tier that constructs no provider of its own" do
      # The fourth-tier hole: a tier handed a ready-made provider constructs
      # nothing, so every other rule here sees an empty file.
      found = tier_violations_for("Oracle::Model.new(definition:, provider: backend.summarizer_provider)\n")

      expect(found.map(&:to_s)).to eq(
        ["lain/wiring.rb:1 -> builds an Oracle::Model but constructs no provider in this file, " \
         "so nothing here can show its round trip reaches a journal"]
      )
    end

    it "accepts an oracle tier that builds its own journaled provider" do
      source = "provider = Provider::Journaled.new(provider: inner, journal: j)\n" \
               "Oracle::Model.new(definition:, provider:)\n"

      expect(tier_violations_for(source)).to be_empty
    end

    it "reads a bare oracle model only inside the oracle namespace" do
      # `cli/command/model.rb` declares a second, unrelated Model and
      # `cli/command/surface.rb` constructs it bare. Matching Model.new
      # everywhere would report a command registry as an unprovisioned tier.
      expect(tier_violations_for("Model.new(definition:)\n", path: "lain/oracle/spend.rb").map(&:to_s))
        .to eq(["lain/oracle/spend.rb:1 -> builds an Oracle::Model but constructs no provider " \
                "in this file, so nothing here can show its round trip reaches a journal"])
      expect(tier_violations_for("registry.register(Model.new)\n", path: "lain/cli/command/surface.rb"))
        .to be_empty
    end

    it "reports an approved construction that reaches no journal" do
      found = construction_violations_for("Provider::Ollama.local(api_base: base)\n",
                                          path: "lain/cli/backend/ollama_tier.rb")

      expect(found.map(&:to_s))
        .to eq(["lain/cli/backend/ollama_tier.rb:1 -> constructs Provider::Ollama with no journal"])
    end

    it "accepts an approved construction wrapped by the decorator instead" do
      found = construction_violations_for("Provider::Journaled.new(provider: Provider::Ollama.new, journal: j)\n",
                                          path: "lain/oracle/secret_read.rb")

      expect(found).to be_empty
    end

    it "reports a decorator left on its Null journal default" do
      found = decorator_violations_for("Provider::Journaled.new(provider: build_provider)\n")

      expect(found.map(&:to_s))
        .to eq(["lain/wiring.rb:1 -> builds Provider::Journaled without naming journal:"])
    end

    it "accepts a decorator handed an explicitly stated Null journal" do
      found = decorator_violations_for("Provider::Journaled.new(provider: p, journal: Channel::Null.instance)\n")

      expect(found).to be_empty
    end

    it "reports an allowlist entry that matches no construction" do
      found = ProviderConstructionDiscipline.stale_entry_violations([])

      expect(found.map(&:to_s)).to include(
        "lain/cli/backend.rb -> APPROVED names Provider::Anthropic, which is constructed nowhere"
      )
    end
  end
end
