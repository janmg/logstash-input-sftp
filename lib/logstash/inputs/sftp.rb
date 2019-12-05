# encoding: utf-8
require "concurrent"
require "logstash/inputs/base"
require "logstash/inputs/file"
require "logstash/namespace"
require "stud/interval"
require "net/sftp"
require "rufus/scheduler"
require "date"
require "stringio"

# This is a plugin for logstash to sftp download file and parse
# Orginally from nabilbendafi
# Improved by yuxuanh
# Modified by janmg
#
# The config should look like this:
#
# ----------------------------------
# input {
#   sftp {
#     username => "username"
#     password => "password"
#     remote_host => "localhost"
#     port => 22
#     remote_path => "/var/log/*.log"
#   }
# }
# ----------------------------------

class LogStash::Inputs::SFTP < LogStash::Inputs::Base
  config_name "sftp"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

 # Login credentials on SFTP server.
  #obsolete
  config :replaceStr, :default => "{today}"
  config :username, :validate => :string, :default => "username"
  config :password, :validate => :password, :required => false
  config :keyfile_path
  config :delimiter, :default => "\n"

  # SFTP server hostname (or ip address)
  config :remote_host, :validate => :string, :required => true
  # and port number.
  config :port, :validate => :number, :default => 22

  # Remote SFTP path and local path
  config :remote_path, :validate => :path, :required => true
  config :globformat, :validate => :string, :default => "**/*.log" 
  # obsolete
  config :local_path, :validate => :path, :required => false

  # the original nabil version tracks offset position through the file plugins sincedb.
  # johnny's version tracks offset through {time}
  # I like to use a registry file instead to keep track of offsets per file 
  config :registry_path, :validate => :string, :required => false, :default => '/tmp/registry.dat'

  # Interval to pull remote data (in seconds).
  config :interval, :validate => :number, :default => 60
  config :schedule, :validate => :string



public
def register
    @logger.info("Registering SFTP Input", :username => @username, :remote_host => @remote_host, :port => @port, :remote_path => @remote_path, :schedule => @schedule)
    @registry = Hash.new
    begin
      @registry = Marshal.load(@registry_path)
    rescue Exception => e
      @logger.error(" caught: #{e.message}")
      @registry.clear
    end

    @processed = 0
    @regsaved = 0
end # def register



def run(queue)
    filelist = Hash.new
    worklist = Hash.new

    # remove non-supported ecdsa and ecdh (jruby-openssl) keyexchanges and by now insecure sha2
    Net::SSH::Transport::Algorithms::ALGORITHMS.values.each { |algs| algs.reject! { |a| a =~ /^ecd(sa|h)-sha2/ } }
    Net::SSH::KnownHosts::SUPPORTED_TYPE.reject! { |t| t =~ /^ecd(sa|h)-sha2/ }

    while !stop?
      chrono = Time.now.to_i
      # filelist = sftp.dir.glob("/remote/path", "**/*.rb") do |entry|
      #Net::SFTP.start('host', 'username', :password => 'password') do |sftp|
      Net::SFTP.start(@remote_host, @username, :keys => @keyfile_path) do |sftp|
       sftp.dir.glob(remote_path, globformat) do |entry|
         @logger.info("files seen: #{entry.name} #{entry.attributes.owner} and #{entry.attributes.size} #{entry.attributes.mtime}")
	 # https://github.com/net-ssh/net-sftp/blob/master/lib/net/sftp/protocol/06/attributes.rb
	 # https://github.com/net-ssh/net-sftp/blob/master/lib/net/sftp/protocol/04/name.rb
         off = 0
         begin
             off = @registry[entry.name][:offset]
         rescue
             off = 0
         end
	 filelist.store(entry.name, { :offset => off, :length => entry.attributes.size, :mtime => entry.attributes.mtime })
	 @logger.info("#{filelist[entry.name]}")
	 #newreg.store(entry.name, { :offset => off })
       end
      end        
      # Worklist is the subset of files where the already read offset is smaller than the file size
      worklist.clear
      worklist = filelist.select {|name,file| file[:offset] < file[:length]}
      worklist.each do |name,entry|
      @logger.info("Prepare to download #{remote_host}:#{name}")
        counter = 0
	length = 0
        if @password.nil?
          Net::SFTP.start(@remote_host, @username, :keys => @keyfile_path) do |sftp|
            io = StringIO.new
            sftp.download!(@remote_path+"/"+name, io)
	    @logger.info("#{io.string} #{io.size}")
	    length = io.size
	    counter = process(queue, io.string)
          end
        else
          Net::SFTP.start(@remote_host, @username, :password => @password) do |sftp|
            io = StringIO.new
            sftp.download!(@remote_path+"/"+name, io)
            @logger.info("#{io.string} #{io.size}")
            length = io.size
            counter = process(queue, io.string)
	  end
        end
	@registry.store(name, { :offset => length, :length => length, :mtime => entry[:mtime] })
        @logger.info("#{remote_path} has processed #{counter} events, now waiting #{interval}, until it will download and process again")

        # save the registry past the regular intervals
        now = Time.now.to_i
        if ((now - chrono) > interval)
           save_registry(@registry)
           chrono += interval
        end
      end
      # Save the registry and sleep until the remaining polling interval is over
      save_registry(@registry)
      sleeptime = interval - (Time.now.to_i - chrono)
      Stud.stoppable_sleep(sleeptime) { stop? }
    end
end



def stop
  @scheduler.shutdown(:wait) if @scheduler
  save_registry(@registry)
end
def close
  stop
end


private
def process(queue, content)
      counter = 0
      content.each_line() do |value|
        @logger.debug(">> #{value}")
        counter += 1
	event = LogStash::Event.new("message" => value.chomp)
        queue << event
      end
      @processed += counter
      return counter
end


def save_registry(filelist)
    unless @processed == @regsaved
        @regsaved = @processed
        @logger.info("processed #{@processed} events, saving #{filelist.size} files and offsets to registry #{registry_path}")
        Thread.new {
            begin
                File.open(@registry_path, 'wb') {|f| f.write(Marshal.dump(filelist))}
            rescue
                @logger.error(@pipe_id+" Oh my, registry write failed, do you have write access?")
            end
        }
    end
end

end # class class LogStash::Inputs::Sftp
