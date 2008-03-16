require 'stringio'

require 'net/ssh'
require 'net/scp/errors'
require 'net/scp/upload'
require 'net/scp/download'

module Net

  # Net::SCP implements the SCP (Secure CoPy) client protocol, allowing Ruby
  # programs to securely and programmatically transfer individual files or
  # entire directory trees to and from remote servers. It provides support for
  # multiple simultaneous SCP copies working in parallel over the same
  # connection, as well as for synchronous, serial copies.
  #
  # Basic usage:
  #
  #   require 'net/scp'
  #
  #   Net::SCP.start("remote.host", "username", :password => "passwd") do |scp|
  #     # synchronous (blocking) upload; call blocks until upload completes
  #     scp.upload! "/local/path", "/remote/path"
  #
  #     # asynchronous upload; call returns immediately and requires SSH
  #     # event loop to run
  #     channel = scp.upload("/local/path", "/remote/path")
  #     channel.wait
  #   end
  #
  # Net::SCP also provides an open-uri tie-in, so you can use the Kernel#open
  # method to open and read a remote file:
  #
  #   # if you just want to parse SCP URL's:
  #   require 'uri/scp'
  #   url = URI.parse("scp://user@remote.host/path/to/file")
  #
  #   # if you want to read from a URL voa SCP:
  #   require 'uri/open-scp'
  #   puts open("scp://user@remote.host/path/to/file").read
  #
  # Lastly, Net::SCP adds a method to the Net::SSH::Connection::Session class,
  # allowing you to easily grab a Net::SCP reference from an existing Net::SSH
  # session:
  #
  #   require 'net/ssh'
  #   require 'net/scp'
  #
  #   Net::SSH.start("remote.host", "username", :password => "passwd") do |ssh|
  #     ssh.scp.download! "/remote/path", "/local/path"
  #   end
  #
  # == Progress Reporting
  #
  # By default, uploading and downloading proceed silently, without any
  # outword indication of their progress. For long running uploads or downloads
  # (and especially in interactive environments) it is desirable to report
  # to the user the progress of the current operation.
  #
  # To receive progress reports for the current operation, just pass a block
  # to #upload or #download (or one of their variants):
  #
  #   scp.upload!("/path/to/local", "/path/to/remote") do |name, sent, total|
  #     puts "#{name}: #{sent}/#{total}"
  #   end
  #
  # Whenever a new chunk of data is recieved for or sent to a file, the callback
  # will be invoked, indicating the name of the file (local for downloads,
  # remote for uploads), the number of bytes that have been sent or received
  # so far for the file, and the size of the file.
  class SCP
    include Net::SSH::Loggable
    include Upload, Download

    # Starts up a new SSH connection and instantiates a new SCP session on 
    # top of it. If a block is given, the SCP session is yielded, and the
    # SSH session is closed automatically when the block terminates. If no
    # block is given, the SCP session is returned.
    def self.start(host, username, options={})
      session = Net::SSH.start(host, username, options)
      scp = new(session)

      if block_given?
        begin
          yield scp
          session.loop
        ensure
          session.close
        end
      else
        return scp
      end
    end

    # Starts up a new SSH connection using the +host+ and +username+ parameters,
    # instantiates a new SCP session on top of it, and then begins an
    # upload from +local+ to +remote+. If the +options+ hash includes an
    # :ssh key, the value for that will be passed to the SSH connection as
    # options (e.g., to set the password, etc.). All other options are passed
    # to the #upload! method. If a block is given, it will be used to report
    # progress (see "Progress Reporting", under Net::SCP).
    def self.upload!(host, username, local, remote, options={}, &progress)
      options = options.dup
      start(host, username, options.delete(:ssh) || {}) do |scp|
        scp.upload!(local, remote, options, &progress)
      end
    end

    # Starts up a new SSH connection using the +host+ and +username+ parameters,
    # instantiates a new SCP session on top of it, and then begins a
    # download from +remote+ to +local+. If the +options+ hash includes an
    # :ssh key, the value for that will be passed to the SSH connection as
    # options (e.g., to set the password, etc.). All other options are passed
    # to the #download! method. If a block is given, it will be used to report
    # progress (see "Progress Reporting", under Net::SCP).
    def self.download!(host, username, remote, local=nil, options={}, &progress)
      options = options.dup
      start(host, username, options.delete(:ssh) || {}) do |scp|
        return scp.download!(remote, local, options, &progress)
      end
    end

    # The underlying Net::SSH session that acts as transport for the SCP
    # packets.
    attr_reader :session

    # Creates a new Net::SCP session on top of the given Net::SSH +session+
    # object.
    def initialize(session)
      @session = session
      self.logger = session.logger
    end

    # Inititiate a synchronous (non-blocking) upload from +local+ to +remote+.
    # The following options are recognized:
    #
    # * :recursive - the +local+ parameter refers to a local directory, which
    #   should be uploaded to a new directory named +remote+ on the remote
    #   server.
    # * :preserve - the atime and mtime of the file should be preserved.
    # * :verbose - the process should result in verbose output on the server
    #   end (useful for debugging).
    # 
    # This method will return immediately, returning the Net::SSH::Connection::Channel
    # object that will support the upload. To wait for the upload to finish,
    # you can either call the #wait method on the channel, or otherwise run
    # the Net::SSH event loop until the channel's #active? method returns false.
    #
    #   channel = scp.upload("/local/path", "/remote/path")
    #   channel.wait
    def upload(local, remote, options={}, &progress)
      start_command(:upload, local, remote, options, &progress)
    end

    # Same as #upload, but blocks until the upload finishes. Identical to
    # calling #upload and then calling the #wait method on the channel object
    # that is returned. The return value is not defined.
    def upload!(local, remote, options={}, &progress)
      upload(local, remote, options, &progress).wait
    end

    # Inititiate a synchronous (non-blocking) download from +remote+ to +local+.
    # The following options are recognized:
    #
    # * :recursive - the +remote+ parameter refers to a remote directory, which
    #   should be downloaded to a new directory named +local+ on the local
    #   machine.
    # * :preserve - the atime and mtime of the file should be preserved.
    # * :verbose - the process should result in verbose output on the server
    #   end (useful for debugging).
    # 
    # This method will return immediately, returning the Net::SSH::Connection::Channel
    # object that will support the download. To wait for the download to finish,
    # you can either call the #wait method on the channel, or otherwise run
    # the Net::SSH event loop until the channel's #active? method returns false.
    #
    #   channel = scp.download("/remote/path", "/local/path")
    #   channel.wait
    def download(remote, local, options={}, &progress)
      start_command(:download, local, remote, options, &progress)
    end

    # Same as #download, but blocks until the download finishes. Identical to
    # calling #download and then calling the #wait method on the channel
    # object that is returned.
    #
    #   scp.download!("/remote/path", "/local/path")
    #
    # If +local+ is nil, and the download is not recursive (e.g., it is downloading
    # only a single file), the file will be downloaded to an in-memory buffer
    # and the resulting string returned.
    #
    #   data = download!("/remote/path")
    def download!(remote, local=nil, options={}, &progress)
      destination = local ? local : StringIO.new
      download(remote, destination, options, &progress).wait
      local ? true : destination.string
    end

    private

      def scp_command(mode, options)
        command = "scp "
        command << (mode == :upload ? "-t" : "-f")
        command << " -v" if options[:verbose]
        command << " -r" if options[:recursive]
        command << " -p" if options[:preserve]
        command
      end

      def start_command(mode, local, remote, options={}, &callback)
        session.open_channel do |channel|
          command = "#{scp_command(mode, options)} #{remote}"
          channel.exec(command) do |ch, success|
            if success
              channel[:local   ] = local
              channel[:remote  ] = remote
              channel[:options ] = options.dup
              channel[:callback] = callback
              channel[:buffer  ] = Net::SSH::Buffer.new
              channel[:state   ] = :"#{mode}_start"
              channel[:stack   ] = []

              channel.on_close                  { |ch| raise Net::SCP::Error, "SCP did not finish successfully (#{ch[:exit]})" if ch[:exit] != 0 }
              channel.on_data                   { |ch, data| channel[:buffer].append(data) }
              channel.on_extended_data          { |ch, type, data| debug { data.chomp } }
              channel.on_request("exit-status") { |ch, data| channel[:exit] = data.read_long }
              channel.on_process                { send("#{channel[:state]}_state", channel) }
            else
              channel.close
              raise Net::SCP::Error, "could not exec scp on the remote host"
            end
          end
        end
      end

      def await_response(channel, next_state)
        channel[:state] = :await_response
        channel[:next ] = next_state
        # check right away, to see if the response is immediately available
        await_response_state(channel)
      end

      def await_response_state(channel)
        return if channel[:buffer].available == 0
        c = channel[:buffer].read_byte
        raise "#{c.chr}#{channel[:buffer].read}" if c != 0
        channel[:next], channel[:state] = nil, channel[:next]
        send(:"#{channel[:state]}_state", channel)
      end

      def finish_state(channel)
        channel.eof!
      end

      def progress_callback(channel, name, sent, total)
        channel[:callback].call(name, sent, total) if channel[:callback]
      end
  end
end

class Net::SSH::Connection::Session
  def scp
    @scp ||= Net::SCP.new(self)
  end
end