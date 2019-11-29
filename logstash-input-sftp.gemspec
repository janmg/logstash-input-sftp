Gem::Specification.new do |s|
  s.name    = 'logstash-input-sftp'
  s.version = '0.0.3'
  s.licenses= ['Apache-2.0']
  s.summary = "This is for logstash to sftp download file and parse at a definable interval."
  s.description = "This gem is a Logstash plugin required to be installed on top of the Logstash core pipeline using $LS_HOME/bin/logstash-plugin install gemname. This gem is not a stand-alone program"
  s.authors = ["Nabil Bendafi", "Johnny Huang", "Jan Geertsma"]
  s.homepage = 'https://github.com/janmg/logstash-input-sftp'
  s.require_paths = ["lib"]

  # Files
  s.files = Dir['lib/**/*','spec/**/*','vendor/**/*','*.gemspec','*.md','CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT']
   # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "input" }

  # Gem dependencies
  s.add_runtime_dependency 'logstash-core-plugin-api', '~> 2.1'
  s.add_runtime_dependency 'logstash-codec-plain', '~> 3.0'
  s.add_runtime_dependency 'stud', '~> 0.0.23'
  s.add_development_dependency 'logstash-devutils', '~> 1.0', '>= 1.0.0'
  s.add_runtime_dependency 'net-sftp', '~> 2.1'
end
