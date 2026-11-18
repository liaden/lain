# Examples

Config files to copy. Each one is loaded by `spec/examples_spec.rb`, so it stays valid as lain
changes. [docs/users/configuration.md](../docs/users/configuration.md) documents every verb and key.

| File | Copy it to | What it shows |
|---|---|---|
| [project/config.rb](project/config.rb) | `.lain/config.rb` | Approval rules, secret paths, test layout and the verify command for a Ruby project. |
| [project/middleware.rb](project/middleware.rb) | Into your `.lain/config.rb` | Your own middleware, as a class and as a block. Add its lines to the config you have; do not replace the file. |
| [project/summarizers.rb](project/summarizers.rb) | `.lain/summarizers.rb` | A summarizer that shrinks RSpec output without a model call. |
| [user/config.rb](user/config.rb) | `~/.config/lain/config.rb` | Theme, notice delay and the phone relay. |

lain runs a config file only after you trust it. After copying a project file, run `lain trust` in
the project. After copying the user file, run `lain trust --user`.
