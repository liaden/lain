# frozen_string_literal: true

# One wiring of the 12-reader Command::Env every `you>` command reads through,
# so a command spec builds one with `build_command_env(agent: real_agent)` and
# overrides ONLY the readers it exercises -- the rest are inert doubles. This is
# what lets the fail-loud placeholders die: there is no NullStatus/NullForkPoint/
# NullPolicySwitch/NullModelSwitch/NullRoleSpawn to name here, only a real double
# per reader, and YoloApprovals -- the one genuine Null Object -- for the queue a
# --yolo session never wires.
module CommandEnvHelper
  def build_command_env(**overrides)
    Lain::CLI::Command::Env.new(**command_env_readers, **overrides)
  end

  # The inert per-reader defaults, split out so #build_command_env stays under
  # the method-length cop -- a real double per reader, YoloApprovals for the
  # queue --yolo never wires.
  def command_env_readers
    { status: instance_double(Lain::StatusFeed), sessions: instance_double(Lain::CLI::Sessions),
      approvals: Lain::CLI::Command::Env::YoloApprovals, supervisor: Lain::Supervisor::Null,
      replies: double("replies"), fork_point: instance_double(Lain::CLI::ForkPoint),
      tmux_surface: instance_double(Lain::CLI::TmuxSurface), agent: double("agent"),
      policy_switch: instance_double(Lain::Approval::PolicySwitch),
      model_switch: instance_double(Lain::Context::ModelSwitch),
      chronicle: Lain::CLI::Chronicle::Null.new, role_spawn: instance_double(Lain::Skill::RoleSpawn) }
  end
end

RSpec.configure { |config| config.include CommandEnvHelper }
