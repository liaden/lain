# frozen_string_literal: true

# Symlinks in a project that lead to a home's credentials, the escapes a mask
# and a judge must agree on. Called fully qualified, never included.
module CredentialLinks
  # @param home [String] absolute; where the credentials live
  # @param relative [Boolean] spell the links into `.ssh`, `.aws` as `../` paths, not absolute ones
  # @return [Hash{String => String}] link name to target
  def self.targets(home, relative: false)
    up = ->(inside, absolute) { relative ? "../#{inside}" : absolute }
    { "key_link" => up.call(".ssh/id_rsa", File.join(home, ".ssh", "id_rsa")), "envlink" => ".env",
      "linkdir" => up.call(".ssh", File.join(home, ".ssh")),
      "aws" => up.call(".aws/credentials", File.join(home, ".aws", "credentials")), "shadow" => "/etc/shadow",
      "tokdir" => File.join(home, "tokens"), "readme.key" => "README.md", "kubedir" => File.join(home, ".kube") }
  end

  # @param root [String] absolute; the project the links are planted in
  # @param home [String] absolute; where the credentials live
  # @param relative [Boolean] as in {.targets}
  # @return [void]
  def self.plant(root, home:, relative: false)
    targets(home, relative:).each { |name, target| File.symlink(target, File.join(root, name)) }
  end
end
