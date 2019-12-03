# encoding: utf-8
require "concurrent"
require "logstash/inputs/base"
require "logstash/inputs/file"
require "logstash/namespace"
require "stud/interval"
require "net/sftp"
require "rufus/scheduler"
require "date"
require 'stringio'

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
    @regsaved = @processed
end # def register



def run(queue)
    newreg   = Hash.new
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
       #sftp.dir.foreach(remote_path) do |entry|
         @logger.info("files seen: #{entry.name}")
	 @logger.info("files seen: #{entry.attributes.owner} and #{entry.attributes.size}")
	 # are attributes also accessible directly? or only through 'name' 
	 # https://github.com/net-ssh/net-sftp/blob/master/lib/net/sftp/protocol/06/attributes.rb
	 # https://github.com/net-ssh/net-sftp/blob/master/lib/net/sftp/protocol/04/name.rb
         off = 0
         begin
             off = @registry[name][:offset]
         rescue
             off = 0
         end
	 newreg.store(entry.name, { :offset => off, :length => entry.attributes.size, :mtime => entry.attributes.mtime })
	 #newreg.store(entry.name, { :offset => off })
       end
      end        
      # Worklist is the subset of files where the already read offset is smaller than the file size
      worklist.clear
      worklist = newreg.select {|name,file| file[:offset] < file[:length]}
      #worklist = newreg

      counter = 0
      content = StringIO.new
      worklist.each do |name,entry|
      @logger.info("Prepare to download #{remote_host}:#{name}")
      if @password.nil?
        Net::SFTP.start(@remote_host, @username, :keys => @keyfile_path) do |sftp|
          io = StringIO.new
         #sftp.download!("#{@sftp_details['server_folder_path']}/#{entry.name}", io.puts, :read_size => 16000))
	  sftp.download!(@remote_path+"/"+name, io.puts)
	  @logger.info("#{io.closed?} #{io.closed_read?} #{io.closed_write?}")
          counter = process(queue, io)
        end
      else
        Net::SFTP.start(@remote_host, @username, :password => @password) do |sftp|
          sftp.download!(@remote_path+"/"+name, content)
          counter = process(queue, content)
        end
      end
      # strio / reopen
      # rewind / seek / rewind / size
      #content.reopen(content,'r')
#      @logger.info("#{content.closed?} #{content.closed_read?} #{content.closed_write?}")
#      content.each_line() do |value|
#        counter += 1
#        event = LogStash::Event.new("message" => value)
#        queue << event
#      end
      @logger.info("#{local_path} has processed #{counter} events, now waiting #{interval}, until it will download and process again")

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
=begin
    if @schedule
      @scheduler = Rufus::Scheduler.new(:max_work_threads => 1)
      @scheduler.cron @schedule do
        process(queue)
      end
      @scheduler.join
    else
      process(queue)
    end
    save_registry(@registry)
=end
end # def run



def stop
  @scheduler.shutdown(:wait) if @scheduler
  save_registry(@registry)
end # def stop
def close
  stop
end


def process(queue, content)
      counter = 0
      content.each_line() do |value|
        counter += 1
        event = LogStash::Event.new("message" => value)
        queue << event
      end
      return counter
end

def xxxxprocess(queue)
=begin
    unless @replaceStr.nil?
      if @remote_path.include?(@replaceStr)
        d = DateTime.now
        temp=d.strftime("%Y%m%d")
        @remote_path.gsub!(@replaceStr, temp)
        @replaceStr=temp
        @logger.info(@replaceStr)
      end
    end
=end
    @logger.info("Prepare to download #{remote_host}:#{entry.name}")
    if @password.nil?
        Net::SFTP.start(@remote_host, @username, :keys => @keyfile_path) do |sftp|
          content = sftp.download!(@remote_path)
        end
      else 
        Net::SFTP.start(@remote_host, @username, :password => @password) do |sftp|
          content = sftp.download!(@remote_path)
        end
      end
      values=content.split(@delimiter)
      counter = 0
      values.each do |value|
        counter = 0
        counter += 1
        event = LogStash::Event.new("message" => value)
        queue << event
      end
      @logger.info("#{local_path} has processed #{counter} events, now waiting #{interval}, until it will download and process again")
end


def save_registry(filelist)
    unless @processed == @regsaved
        @regsaved = @processed
        @logger.info(@pipe_id+" processed #{@processed} events, saving #{filelist.size} files and offsets to registry #{registry_path}")
        Thread.new {
            begin
                @blob_client.create_block_blob(container, registry_path, Marshal.dump(filelist))
            rescue
                @logger.error(@pipe_id+" Oh my, registry write failed, do you have write access?")
            end
        }
    end
end

end # class class LogStash::Inputs::Sftp
