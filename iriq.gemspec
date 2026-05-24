require_relative "lib/iriq/version"

Gem::Specification.new do |s|
  s.name        = "iriq"
  s.version     = Iriq::VERSION
  s.authors     = ["Daniel Pepper"]
  s.description = "IRI extraction, normalization, and clustering."
  s.files       = `git ls-files * ':!:spec' ':!:go' ':!:script'`.split("\n")
  s.bindir      = "exe"
  s.executables = ["iriq"]
  s.homepage    = "https://github.com/dpep/iriq"
  s.license     = "MIT"
  s.summary     = "IRI extraction, normalization, and clustering."

  s.required_ruby_version = ">= 3.2"

  s.add_development_dependency 'debug', '>= 1'
  s.add_development_dependency 'rspec', '>= 3.10'
  s.add_development_dependency 'rspec-debugging'
  s.add_development_dependency 'simplecov', '>= 0.22'
end
