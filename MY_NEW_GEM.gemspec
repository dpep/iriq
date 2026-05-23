require_relative "lib/MY_NEW_GEM/version"

Gem::Specification.new do |s|
  s.name        = "MY_NEW_GEM"
  s.version     = MY_NEW_MODULE::VERSION
  s.authors     = ["Daniel Pepper"]
  s.description = "..."
  s.files       = `git ls-files * ':!:spec'`.split("\n")
  s.homepage    = "https://github.com/dpep/MY_NEW_REPO"
  s.license     = "MIT"
  s.summary     = "MY_NEW_MODULE"

  s.required_ruby_version = ">= 3.2"

  s.add_development_dependency 'debug', '>= 1'
  s.add_development_dependency 'rspec', '>= 3.10'
  s.add_development_dependency 'rspec-debugging'
  s.add_development_dependency 'simplecov', '>= 0.22'
end
