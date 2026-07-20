Gem::Specification.new do |s|
  s.name        = "detest"
  s.version     = "0.2.0"
  s.summary     = "Distribute a list of tests."
  s.description = "Distribute a list of tests until there aren't any left."
  s.homepage    = 'https://github.com/TreyE/detests'
  s.authors     = ["Trey Evans"]
  s.email       = "lewis.r.evans@gmail.com"
  s.files       = Dir['lib/**/*.rb']
  s.license     = "CC-BY-NC-ND-4.0"

  s.add_dependency "redis"
end
