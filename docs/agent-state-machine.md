# Agent state machine

<!--
  GENERATED from `Lain::Agent`'s `state_machines` definition by
  spec/lain/agent_state_machine_diagram_spec.rb. Do not edit by hand.
  Regenerate:  LAIN_REGENERATE=1 bundle exec rspec spec/lain/agent_state_machine_diagram_spec.rb
  The same spec fails the build if this file drifts from the code.
-->

```mermaid
stateDiagram-v2
  awaiting_user : awaiting_user
  awaiting_model : awaiting_model
  awaiting_tools : awaiting_tools
  done : done
  failed : failed
  awaiting_approval : awaiting_approval
  awaiting_user --> awaiting_model : dispatch
  awaiting_model --> awaiting_model : dispatch
  awaiting_tools --> awaiting_model : dispatch
  awaiting_user --> awaiting_user : reopen
  awaiting_model --> awaiting_user : reopen
  awaiting_tools --> awaiting_user : reopen
  done --> awaiting_user : reopen
  failed --> awaiting_user : reopen
  awaiting_approval --> awaiting_user : reopen
  awaiting_model --> awaiting_tools : tool_use
  awaiting_model --> awaiting_model : pause_turn
  awaiting_model --> done : end_turn
  awaiting_model --> done : stop_sequence
  awaiting_model --> failed : max_tokens
  awaiting_model --> failed : refusal
  awaiting_model --> failed : unknown
```
