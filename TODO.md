Ideas/Todos:

* Need to be able to resume a session if we have crashed.
* If the session is idle for too long we should consider an autocompact or
  summarization to manage costs proactively, or the ability to summarize/compact
  after the cache is cold with minimal cost?
* Use tmux/neovim for UI:
  * Launching the subagents and being able to switch to them?
  * Have a different prompting area versus the irb/debug/pry console for running
    ruby so that we segragate the two areas?
  * Neovim has a nvim-dap for debugging view, and I wonder if that would be
    helpful with interactive ruby session?
  * Being able to generate macros or even search and replace across files
    without having to use sed/awk as a mess and thus we can consider that to be
    an "allowlist" type of command?
  * How does the tmux/iterm2 interaction possibly playout?
* Pulling context out of neovim:
  * From quickfix list, open buffers, or marks
  * We have our jump history, both forwards and backwards, and we could introspect
    that a bit to select some context.
  * The different registers?
* Pulling context out of `git blame`, and commit messages or commit bodies for
  specific files based a sub-agent that handles code archeology? This could be
  useful context for the research, planner, or even a debugger. Being able to
  generate the summaries of the commit message with the commit SHA so that the
  implementer or planner can get the full context later could prove useful.
* Adapting a more elixir style concurrency for the agents since they are passing
  messages between each other to coordinate.
  * Consider the user an agent and have them send messages and receive messages
    from agents too, therefore they have an inbox/outbox.
* Use of ollama for local LLM for augmenting autocomplete or interactive prompting?
  * Maybe we could use it for determining if we want to save a memory for a
    given user interaction?
* Given a plan from the LLM, how do we iterate on the plan?
  * I think we could allow the edit of the plan via neovim, and we take the
    before/after diff and prompt to review the changes and adjust the plan based
    on that?
  * Given we could have a plan template that we are using, we could add in some
    default "COMMENT" sections that the user then types into to attach a comment
    about a given milestone/phase/task/etc.
  * Using neovim to render the markdown and does the neovim markdown plugins
    have a way of annotating a comment that we could leverage instead?
* Ruby usage:
  * Allow for creating new middlewares that they inject into the stack
  * Defining tool call hooks in ruby and having the ability to test these hooks.
  * The tool call hooks are basically middleware anyways and middleware gets
    tested right?
  * Leverage the neovim <-> ruby to have ruby script or automate some things
    within neovim?
* What ruby DSL would we like for interacting with the agents, orchestration,
  plans, and similar?
  * Add something like `wtf?` for an initial 'what is the state of things?
  * If we are using ruby-debug, what ease of life breakpoints do we want to
    build into our architecture?
* Could we prompt/build our bash based tool use where we encourage that there is
  no `|` by default and instead we get back a formatted list of commands that
  specifies how they weave together a bit more so that we have better experience
  with the allow list and avoid having the `\` result in commands needing manual
  approval.
* Researching/Brainstorming:
  *
* Planning:
  * Logical commits
  * Attempt to design the plan for concurrent building.
  * Order items to de-risk the plan, and run experiments/spikes to gather
    information.
* Orchestration:
  * Have a smarter top level orchestrator who coordinates as needed and
    identifies where things can be fanned out to multiple agents. It also
    determines which model to use for the work based on the nature of the work.
  * The agents should be in their own git worktree for their work and should be
    able to run their tests independently of other agents in some fashion, be it
    docker or separate DB schemas or similar.
  * Escalate issues and surprises where things deviate from the plan to our
    human partner. This should go through the orchestrator though so they keep
    context of what has changed from the plan. They should keep in mind if
    things are significantly changed enough that we should halt and go back to
    planning. The agents should try to resolve small issues or surprises on
    their own, and include that communication of their status to the orchestrator
    as well.
  * Have 1+ dev to implement
  * Have a test engineer that does the TDD and implements the tests based on the
    accpetance criteria (Gherkin style) and the dev and the test engineer reviews
    the implementation to verify that it works relatve to their expectations of
    the acceptance criteria and the tests they made.
  * Have 1+ code reviewers that cover various considerations:
    * SRE/operations/performance
    * DBA for schema normalization, migrations, DB performance, data integrity,
      anti-patterns.
    * Security engineer, devops, etc?
  * Orchestrator handles merging the work from different agents and as a final
    review that the integration points across different agents are tested
    appropriately.
  * Having an agent that looks at the timeline for each completed sub-agent and
    uses that to record memories? Similar to the court clerk?
  * Similar to the court clerk sub-agent that records things for posterity, I
    think it would behoove us to have a secondary sub-agent that is also looking
    at the implementation process and areas where we could address friction and
    asking for input about adapting the harness and/or changing the
    configuration points that our harness provides.
  * Given the orchestrator is a smarter model than the sub-agents, the
    sub-agents should be able to escalate to the orchestrator to get guidance, and
    the orchestrator can determine if it is problematic enough to raise to the human.
  * Being able to review the ad-hoc scripts that are generated intermittently to
    be able to promote them to helper scripts in the app the harness is working
    on should be beneficial for the user and future agentic dev work
* Interview the user for their habits and personality to get a better feel of
  how they want to approach and do stuff and then we can start with some solid
  foundation

Frustration points for LLM dev at work:

* When wanting to access files that are not tracked by git
*
