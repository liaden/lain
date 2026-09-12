# frozen_string_literal: true

module Lain
  module Isolation
    WorkerId = Data.define(:lane, :role, :ordinal)

    # The name a backend keys a worker's resources on, and the ONE place the two
    # LANES such a name is minted in are spelled.
    #
    # Two allocators mint worker ids in a run and neither can see the other:
    # {Lain::Supervisor} numbers the actors an operator ADOPTS off its own
    # sequence, and {Tools::Subagent::Leases} numbers the children a model
    # SPAWNS off its own. A backend keys a resource on the id -- {Worktree} a
    # checkout path -- so two ids that collide are two workers sharing one
    # working tree, or a refusal that kills a healthy spawn.
    #
    # DISJOINTNESS IS A PROPERTY OF THIS OBJECT, not a convention two call sites
    # happen to share. An adopted id always ends in a hyphen and its ordinal; a
    # spawned id puts {SPAWNED_INFIX} in front of the ordinal, so the character
    # before its digit run is never a hyphen and no role name can forge the
    # other lane. That is what the two hand-spelled conventions could not
    # promise: an adopted `"reviewer-spawn"` at ordinal 1 and a spawned
    # `"reviewer"` at ordinal 1 read identically. `Role::Catalog` is closed, but
    # `Tools::Subagent.new(name:)` is public, so a role name is not something
    # either allocator may assume anything about.
    #
    # Reopened rather than written as one `Data.define ... do` block: a constant
    # inside that block lands in the ENCLOSING module rather than on the Data
    # class, and both lane names belong to this object.
    class WorkerId
      ADOPTED = :adopted
      SPAWNED = :spawned

      # A worker name its caller chose that git would refuse in a ref. Refused
      # rather than escaped, so the name an operator reads is the name on the
      # ref.
      class Refused < Lain::Error; end

      # Closed and loud: a lane outside this set raises at construction, so a
      # third lane is a deliberate edit here rather than a silently unspellable
      # id.
      LANES = [ADOPTED, SPAWNED].freeze

      # Ends in a character that is not a hyphen, which is the whole of why an
      # adopted id can never read as a spawned one.
      SPAWNED_INFIX = "-spawn."

      # The first ordinal an allocator hands out. Both count up from it, and
      # nothing below it may be spelled -- see {#initialize}.
      FIRST = 1

      # @param role [#to_s] what the worker is for, so a resource left behind by
      #   a crash names the work it belonged to
      # @param ordinal [Integer] the allocator's own sequence number
      # @return [WorkerId]
      def self.adopted(role:, ordinal:) = new(lane: ADOPTED, role:, ordinal:)

      # @param (see .adopted)
      # @return [WorkerId]
      def self.spawned(role:, ordinal:) = new(lane: SPAWNED, role:, ordinal:)

      # A worker name a caller chose rather than minted here -- an adopted
      # actor's, a spawn lane's -- becomes the ref its anchor lives under, so
      # git judges it as that ref. One check for every such name, so no second
      # reading of the refname rules can drift from the one that writes them.
      #
      # @param name [#to_s] e.g. `issue.<slug>.<id>`
      # @param shell_out_factory [#call] builds the subprocess git judges it in
      # @return [String] the name, frozen
      # @raise [Refused]
      def self.checked(name, shell_out_factory: ::Lain::Shell::Out.public_method(:new))
        ref = "#{Worktree::Handback::Naming::REF_NAMESPACE}/#{name}"
        shell = shell_out_factory.call("git", "check-ref-format", ref, environment: Worktree::GIT_CONTEXT_SCRUB)
        shell.run_command
        raise Refused, "#{name.to_s.inspect} cannot name a ref: #{ref} is not a legal refname" unless
          shell.exitstatus.zero?

        -name.to_s
      end

      # The ordinal is refused below {FIRST} rather than merely never asked for.
      # A negative one is the ONE input that breaks the disjointness this class
      # claims -- `spawned(role: "r", ordinal: -1)` reads `"r-spawn.-1"`, which
      # is exactly `adopted(role: "r-spawn.", ordinal: 1)` -- and an object that
      # accepts what its own stated property cannot survive is claiming more
      # than it enforces. Unreachable from either allocator, both of which count
      # up, so this closes the claim rather than a live defect.
      def initialize(lane:, role:, ordinal:)
        raise ArgumentError, "lane must be one of #{LANES.inspect}, got #{lane.inspect}" unless LANES.include?(lane)

        ordinal = Integer(ordinal)
        raise ArgumentError, "ordinal must be #{FIRST} or more, got #{ordinal}" if ordinal < FIRST

        super(lane:, role: role.to_s.dup.freeze, ordinal:)
      end

      # The string a backend actually keys on.
      # @return [String]
      def to_s = lane == ADOPTED ? "#{role}-#{ordinal}" : "#{role}#{SPAWNED_INFIX}#{ordinal}"
    end
  end
end
