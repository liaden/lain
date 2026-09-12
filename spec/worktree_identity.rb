# frozen_string_literal: true

# Refuses to let the suite run against a repository that is not this tree's own.
#
# A linked worktree's `.git` is a one-line `gitdir:` pointer FILE, so a `cp -a`
# of one produces a directory whose git admin data still belongs to the
# ORIGINAL. Every spec that drives real git then drives it against the original
# -- and one full-suite run from such a copy deleted the copy. Nothing warns
# you, because the pointer file looks inert; `docs/toolchain-traps.md` carries
# the account, and the copied-submodule entry beside it.
#
# Working IN a linked worktree is normal and correct, so the question is never
# whether `.git` is a pointer -- it is whether the admin directory it names
# points back here.
#
# Reading the files directly, rather than asking `git`, is deliberate: this runs
# at boot in every spec process including all twelve parallel workers, and a
# `git` call would also have to scrub `GIT_INDEX_FILE` back out of pre-commit's
# environment to answer about this tree rather than about lain's staged index.
#
# It raises rather than calling `abort`, because a `SystemExit` is the one shape
# this suite cannot read: a run truncated by one still reports zero failures.
class WorktreeIdentity
  # This tree cannot be shown to own the git admin directory its `.git` names.
  class Foreign < RuntimeError; end

  REMEDY = "Delete the `.git` pointer file -- see the `rm .git` trap in docs/toolchain-traps.md -- or run " \
           "the suite from a checkout of its own."
  private_constant :REMEDY

  # @param tree [String] the checkout the suite is running from
  # @return [String] that checkout, when it owns the admin directory it names
  # @raise [Foreign] when it does not
  def self.verify!(tree = File.expand_path("..", __dir__)) = new(tree).verify!

  # @param tree [String]
  def initialize(tree)
    @tree = File.expand_path(tree)
  end

  # @return [String]
  # @raise [Foreign]
  def verify! = own? ? @tree : refuse

  private

  def own? = !pointer_file? || claimed_here?

  def pointer_file? = File.file?(pointer)

  def pointer = File.join(@tree, ".git")

  def admin
    @admin ||= begin
      target = contents(pointer).to_s[/\Agitdir: (.+)$/, 1]
      target ? File.expand_path(target.chomp, @tree) : ""
    end
  end

  # A linked worktree's admin stub registers its checkout in `gitdir`, and keeps
  # no `config`; a submodule's keeps a `config` naming it in `core.worktree`,
  # and no `gitdir`. Both answer "whose am I?" -- and for a copy of either, both
  # answer with somebody else.
  def claimed = @claimed ||= (registered_checkout || configured_checkout).to_s

  def registered_checkout = admin_claim("gitdir") { |text| File.dirname(text) }

  def configured_checkout = admin_claim("config") { |text| core_section(text)[/^\s*worktree\s*=\s*(.+)$/i, 1] }

  # A `worktree =` key names this admin's checkout only under `[core]`. An
  # `[alias]` section may spell the word too, and a claim misparsed out of one
  # would put a real path in a refusal that advises deleting a `.git`.
  def core_section(text) = text[/^\s*\[core\][^\[]*/i].to_s

  # The claim lines are the only thing respelled here: `chomp` takes the newline
  # git writes, a CRLF's carriage return with it, and `strip` the whitespace a
  # config key leaves around its value.
  def admin_claim(name)
    text = admin.empty? ? nil : contents(File.join(admin, name))
    claim = text && yield(text.chomp)
    claim && File.expand_path(claim.strip, admin)
  end

  # `Lain::Project::Resolver.spellings` resolves both sides, which absorbs a
  # symlinked spelling and the relative paths `worktree.useRelativePaths`
  # writes. Reused rather than reimplemented, because a second spelling
  # comparison is the drift this guard exists to catch -- and it accepts a
  # `.git` reached through a symlink, rightly: a symlink is not the `cp -a`
  # shape.
  def claimed_here? = !claimed.empty? && spellings(claimed).intersect?(spellings(@tree))

  def spellings(path) = Lain::Project::Resolver.spellings(path, File)

  # `scrub`, because a half-written file is as likely to hold junk bytes as to
  # be short, and an `ArgumentError` from a regex over invalid UTF-8 would say
  # none of what the sentences below say.
  def contents(path)
    File.read(path).scrub
  rescue SystemCallError
    nil
  end

  def refuse = raise(Foreign, refusal)

  def refusal
    return unreadable_pointer if admin.empty?
    return missing_admin unless File.directory?(admin)
    return unregistered_admin if claimed.empty?

    foreign_admin
  end

  def unreadable_pointer
    "#{pointer} holds no readable `gitdir:` line, so what repository this tree belongs to cannot be " \
      "established -- an interrupted copy leaves the pointer file truncated. #{REMEDY}"
  end

  def missing_admin
    "#{pointer} names the git admin directory #{admin}, which does not exist. #{REMEDY}"
  end

  # Not the copied-worktree shape: that one always leaves a `gitdir` behind.
  def unregistered_admin
    "#{pointer} names #{admin}, which registers no checkout of its own -- neither a linked worktree's " \
      "`gitdir` nor a submodule's `core.worktree`. `git init --separate-git-dir` leaves exactly this " \
      "shape, and so does a directory that is not git's at all. Look at both paths before running the " \
      "suite here; nothing should be deleted on this evidence."
  end

  def foreign_admin
    "#{pointer} names the git admin directory #{admin}, which belongs to #{claimed}. Running the suite " \
      "here would drive git against that tree, and one such run deleted the copy it ran from. #{REMEDY}"
  end
end
