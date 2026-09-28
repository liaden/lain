### The tiers this project runs

By default a pass runs **one** rung, on the session's own model, and that rung's voice settles
nothing: every criterion comes back unsettled with a manual pass owed. That is deliberate. Nothing
here has measured the model you are chatting with, and a ladder that declared it fit would be
guessing on the one rung no check can inspect.

This is the hole where a project states its own binding — which model each rung runs on, how many
samples the cheap rung takes, and any standing rule such as "every card touching billing is high
risk". Override it at `.lain/slots/skill/qa/tiers.md`. This text tells the reader what the assignment
is; the process that drives the ladder is what actually binds each rung, and it refuses two rungs
bound to the same model, because a rung that stopped mid-answer has to climb to a **different** model
rather than to the same one with more room.

Before binding one, read the measurements recorded against the default binding in lain's own
`qa/session_tiers.rb`: which models answered every acceptance item, which is the strongest reviewer
and at what cost, and the two that must not hold a verdict because they wave real violations through.
