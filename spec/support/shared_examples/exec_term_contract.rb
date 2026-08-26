# frozen_string_literal: true

# The exec seam's term contract, made executable instead of aspirational.
#
# `lib/lain/exec.rb` states that every backend answers `#takes_term?(term)` and
# that a caller holding a term asks before it offers one. Nothing enforced it:
# the seam has no base class -- deliberately, three duck-typed classes -- so a
# fourth backend could ship green, answer `#call` correctly, and die as a
# `NoMethodError` out of `Tools::Bash`'s arm chooser on its first pipeline. A
# contract a whole suite cannot see is a comment, and this file is the same
# answer `tier_one_read_contract.rb` gives for tier-1 readers, which likewise
# have no base class to hang it on.
#
# == What is DECLARED here and what is DERIVED
#
# The host declares only its own row of the truth table -- which terms it takes
# and which it refuses. It never restates the RULE behind that row: `Docker`'s
# `term.size == 1` lives in `Docker`, once. What this group derives, and the
# reason it is worth including on a backend whose answers are obvious, is that
# `#call` raises {Lain::Exec::Unsupported} for exactly the terms the backend
# itself refuses and for no others. A backend whose refusal and whose answer
# disagree is what the derivation in `lib/` makes unrepresentable; this is what
# notices if a later hand separates them again.
#
# == What the host supplies
#
#   #backend         the backend under test
#   #run_term(term)  calls `#call` on it with that term, in whatever cwd, env
#                    and collaborators that backend needs. Its return value is
#                    ignored -- only whether it raised is read -- so a host is
#                    free to hand it a recording double for the transport.
#   #terms_taken     the terms this backend claims, possibly empty
#   #terms_refused   the terms it refuses, possibly empty
RSpec.shared_examples "an exec backend answering for a term" do
  # NOT A TAUTOLOGY, AND NOT DELETABLE. A host declaring NEITHER row makes every
  # loop below a no-op, so all three examples pass while asserting nothing --
  # the exact defect this group exists to keep a backend from shipping, wearing
  # a green suite's clothes. Every example reads its terms through here so the
  # guard cannot be half-applied to some of them.
  def declared_terms
    terms = terms_taken + terms_refused
    expect(terms).not_to be_empty
    terms
  end

  # Whether `#call` refused, which is the only thing the derivation below reads
  # from it. Every other outcome -- a Capture, a Timeout, a transport's own
  # error -- is somebody else's example.
  def unsupported?(term)
    run_term(term)
    false
  rescue Lain::Exec::Unsupported
    true
  end

  # The row that reddens for a backend which never learned the message at all.
  it "answers #takes_term? with a Boolean for every shape it is asked about" do
    declared_terms.each do |term|
      expect([true, false]).to include(backend.takes_term?(term)), term.inspect
    end
  end

  it "answers its own row of the truth table" do
    declared_terms.each do |term|
      expect(backend.takes_term?(term)).to be(terms_taken.include?(term)), term.inspect
    end
  end

  # Derived, never declared per row: a term the backend claims must not come
  # back as Unsupported, and one it refuses must.
  it "raises Unsupported at #call for exactly the terms it refuses" do
    declared_terms.each do |term|
      expect(unsupported?(term)).to be(!backend.takes_term?(term)), term.inspect
    end
  end
end
