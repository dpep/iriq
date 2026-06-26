require "debug"
require "rspec"
require "rspec/debugging"
require "simplecov"
require "tempfile"

# Specs run with auto-corpus disabled so no test ever touches the user's
# real default corpus. Tests that exercise corpus behavior pass an
# explicit --corpus PATH against a Tempfile.
ENV["IRIQ_NO_CORPUS"] ||= "1"

SimpleCov.start do
  add_filter "/spec/"
end

if ENV["CI"] == "true" || ENV["CODECOV_TOKEN"]
  require "simplecov_json_formatter"
  SimpleCov.formatter = SimpleCov::Formatter::JSONFormatter
end

# load this gem
gem_name = Dir.glob("*.gemspec")[0].split(".")[0]
require gem_name

RSpec.configure do |config|
  # allow "fit" examples
  config.filter_run_when_matching :focus

  config.mock_with :rspec do |mocks|
    # verify existence of stubbed methods
    mocks.verify_partial_doubles = true
  end
end

Dir["./spec/support/**/*.rb"].sort.each { |f| require f }
