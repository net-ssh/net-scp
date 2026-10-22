require 'net/scp/errors'

module Net; class SCP

  # This module implements the state machine for downloading information from
  # a remote server. It exposes no public methods. See Net::SCP#download for
  # a discussion of how to use Net::SCP to download data.
  module Download
    private

    # This is the starting state for the download state machine. The
    # #start_command method puts the state machine into this state the first
    # time the channel is processed. This state does some basic error checking
    # and scaffolding and then sends a 0-byte to the remote server, indicating
    # readiness to proceed. Then, the state machine is placed into the
    # "read directive" state (see #read_directive_state).
    def download_start_state(channel)
      if channel[:local].respond_to?(:write) && channel[:options][:recursive]
        raise Net::SCP::Error, "cannot recursively download to an in-memory location"
      elsif channel[:local].respond_to?(:write) && channel[:options][:preserve]
        lwarn { ":preserve option is ignored when downloading to an in-memory buffer" }
        channel[:options].delete(:preserve)
      elsif channel[:options][:recursive] && !File.exist?(channel[:local])
        Dir.mkdir(channel[:local])
      end

      channel.send_data("\0")
      channel[:state] = :read_directive
    end

    # This state parses the next full line (up to a new-line) for the next
    # directive. (See the SCP protocol documentation in Net::SCP for the
    # possible directives).
    def read_directive_state(channel)
      return unless line = channel[:buffer].read_to("\n")
      channel[:buffer].consume!

      directive = parse_directive(line)
      case directive[:type]
      when :OK
        return
      when :warning
        channel[:error_string] << directive[:message]
      when :error
        channel[:error_string] << directive[:message]
      when :times
        channel[:times] = directive
      when :directory
        read_directory(channel, directive)
      when :file
        read_file(channel, directive)
      when :end
        directory = channel[:stack].pop
        if channel[:options][:preserve] && directory && directory[:times]
          File.utime(directory[:times][:atime], directory[:times][:mtime], channel[:local])
        end
        channel[:local] = File.dirname(channel[:local])
        channel[:state] = :finish if channel[:stack].empty?
      end

      channel.send_data("\0")
    end

    # Reads data from the channel for as long as there is data remaining to
    # be read. As soon as there is no more data to read for the current file,
    # the state machine switches to #finish_read_state.
    def read_data_state(channel)
      return if channel[:buffer].empty?
      data = channel[:buffer].read!(channel[:remaining])
      channel[:io].write(data)
      channel[:remaining] -= data.length
      progress_callback(channel, channel[:file][:name], channel[:file][:size] - channel[:remaining], channel[:file][:size])
      await_response(channel, :finish_read) if channel[:remaining] <= 0
    end

    # Finishes off the read, sets the times for the file (if any), and then
    # jumps to either #finish_state (for single-file downloads) or
    # #read_directive_state (for recursive downloads). A 0-byte is sent to the
    # server to indicate that the file was received successfully.
    def finish_read_state(channel)
      channel[:io].close unless channel[:io] == channel[:local]

      if channel[:options][:preserve] && channel[:file][:times]
        File.utime(channel[:file][:times][:atime],
          channel[:file][:times][:mtime], channel[:file][:name])
      end

      channel[:file] = nil
      channel[:state] = channel[:stack].empty? ? :finish : :read_directive
      channel.send_data("\0")
    end

    # Parses the given +text+ to extract which SCP directive it contains. It
    # then returns a hash with at least one key, :type, which describes what
    # type of directive it is. The hash may also contain other, directive-specific
    # data.
    def parse_directive(text)
      case type = text[0]
      when "\x00"
        # Success
        { :type => :OK }
      when "\x01"
        { :type => :warning,
          :message => text[1..-1] }
      when "\x02"
        { :type => :error,
          :message => text[1..-1] }
      when ?T
        parts = text[1..-1].split(/ /, 4).map { |i| i.to_i }
        { :type  => :times,
          :mtime => Time.at(parts[0], parts[1]),
          :atime => Time.at(parts[2], parts[3]) }
      when ?C, ?D
        parts = text[1..-1].split(/ /, 3)
        { :type => (type == ?C ? :file : :directory),
          :mode => parts[0].to_i(8),
          :size => parts[1].to_i,
          :name => parts[2].chomp }
      when ?E
        { :type => :end }
      else raise ArgumentError, "unknown directive: #{text.inspect}"
      end
    end

    # Sets the new directory as the current directory, creates the directory
    # if it does not exist, and then falls back into #read_directive_state.
    def read_directory(channel, directive)
      if !channel[:options][:recursive]
        raise Net::SCP::Error, ":recursive not specified for directory download"
      end

      channel[:local] = local_path_for(channel, directive[:name])

      if File.symlink?(channel[:local])
        raise Net::SCP::Error, "#{channel[:local]} is a symlink, refusing to follow it"
      elsif File.exist?(channel[:local]) && !File.directory?(channel[:local])
        raise Net::SCP::Error, "#{channel[:local]} already exists and is not a directory"
      elsif !File.exist?(channel[:local])
        Dir.mkdir(channel[:local], (directive[:mode] & 0777) | 0700)
      end

      channel[:stack] << directive.merge(:times => channel[:times])
      channel[:times] = nil
    end

    # Opens the given file locally, and switches to #read_data_state to do the
    # actual read.
    def read_file(channel, directive)
      if !channel[:local].respond_to?(:write)
        server_named = channel[:options][:recursive] || File.directory?(channel[:local])
        directive[:name] = server_named ? local_path_for(channel, directive[:name]) : channel[:local]
      end

      channel[:file] = directive.merge(:times => channel[:times])
      # Setuid/setgid/sticky bits are never taken from the server, even with :preserve.
      channel[:io] = channel[:local].respond_to?(:write) ? channel[:local] :
        open_local_file(directive[:name], (directive[:mode] & 0777) | 0600, server_named)
      channel[:times] = nil
      channel[:remaining] = channel[:file][:size]
      channel[:state] = :read_data

      progress_callback(channel, channel[:file][:name], 0, channel[:file][:size])
    end

    # The name comes from the server, so anything but a single path component
    # would let a malicious server write outside the target (CVE-2019-6111).
    def local_path_for(channel, name)
      if name.empty? || name == "." || name == ".." || name.include?("/") || name.include?("\0") ||
         (File::ALT_SEPARATOR && name.include?(File::ALT_SEPARATOR))
        raise Net::SCP::Error, "invalid file name from server: #{name.inspect}"
      end

      if channel[:stack].empty? && !requested_name?(channel[:remote], name)
        raise Net::SCP::Error, "file name from server does not match request: #{name.inspect}"
      end

      File.join(channel[:local], name)
    end

    # OpenSSH's CVE-2019-6111 check: the flags mirror its brace expansion plus fnmatch(3) with flags 0.
    def requested_name?(remote, name)
      pattern = File.basename(remote.to_s)
      name == pattern || File.fnmatch(pattern, name, File::FNM_DOTMATCH | File::FNM_EXTGLOB)
    end

    # A symlink planted at a server-named path must not redirect the write;
    # the caller's own target may be a symlink on purpose (net-sftp#162).
    def open_local_file(path, perm, nofollow)
      return File.new(path, "wb", perm) unless nofollow && defined?(File::NOFOLLOW)

      begin
        File.new(path, "wb", perm, :flags => File::NOFOLLOW)
      rescue SystemCallError
        raise unless File.symlink?(path)
        raise Net::SCP::Error, "#{path} is a symlink, refusing to follow it"
      end
    end
  end

end; end
