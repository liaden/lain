# frozen_string_literal: true

require "pathname"

# examples/ is what a new user copies, so each file is loaded the way lain
# would load it from the place its name says it belongs.
RSpec.describe "examples/" do
  root = Pathname.new(File.expand_path("../examples", __dir__))

  it "evaluates the project config as a project's config.rb" do
    path = root.join("project/config.rb")
    expect { Lain::Config::Builder.evaluate(path.read, path: path.to_s) }.not_to raise_error
  end

  it "evaluates the middleware config as a project's config.rb" do
    path = root.join("project/middleware.rb")
    expect { Lain::Config::Builder.evaluate(path.read, path: path.to_s) }.not_to raise_error
  end

  it "evaluates the user config as the user's config.rb" do
    path = root.join("user/config.rb")
    expect { Lain::Config::Builder.evaluate(path.read, path: path.to_s, verbs: Lain::Config::Builder::USER_VERBS) }
      .not_to raise_error
  end

  it "builds the summarizers as a project's summarizers.rb" do
    path = root.join("project/summarizers.rb")
    expect { Lain::Summarizer::Builder.build(path.read, path.to_s) }.not_to raise_error
  end
end
