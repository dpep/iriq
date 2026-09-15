require "debug"
require "rspec"
require "rspec/debugging"
require "simplecov"
require "tempfile"
require "tmpdir"

# No spec may touch the developer's real corpus. Force (not ||=) the opt-out,
# drop any exported IRIQ_CORPUS, and point the default location at a throwaway
# dir so even paths that ignore --no-corpus (bare --reset) stay sandboxed.
# Subprocesses (cli_e2e_spec) inherit this ENV.
ENV["IRIQ_NO_CORPUS"] = "1"
ENV.delete("IRIQ_CORPUS")
ENV["XDG_DATA_HOME"] = Dir.mktmpdir("iriq-spec-data")
at_exit { FileUtils.remove_entry(ENV["XDG_DATA_HOME"], true) }

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
