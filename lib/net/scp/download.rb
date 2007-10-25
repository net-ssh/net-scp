require 'net/scp/errors'

module Net; class SCP

  module Download
    private

    def download_start_state(channel)
      if channel[:local].respond_to?(:write) && channel[:options][:recursive]
        raise Net::SCP::Error, "cannot recursively download to an in-memory location"
      elsif channel[:local].respond_to?(:write) && channel[:options][:preserve]
        log { ":preserve option is ignored when downloading to an in-memory buffer" }
        channel[:options].delete(:preserve)
      elsif channel[:options][:recursive] && !File.exists?(channel[:local])
        Dir.mkdir(channel[:local])
      end

      channel.send_data("\0")
      channel[:state] = :read_directive
    end

    def read_directive_state(channel)
      return unless line = channel[:buffer].read_to("\n")
      channel[:buffer].consume!

      directive = parse_directive(line)
      case directive[:type]
      when :times then
        channel[:times] = directive
      when :directory
        read_directory(channel, directive)
      when :file
        read_file(channel, directive)
      when :end
        channel[:local] = File.dirname(channel[:local])
        channel[:stack].pop
        channel[:state] = :finish if channel[:stack].empty?
      end

      channel.send_data("\0")
    end

    def read_data_state(channel)
      return if channel[:buffer].empty?
      data = channel[:buffer].read!(channel[:remaining])
      channel[:io].write(data)
      channel[:remaining] -= data.length
      progress_callback(channel, channel[:file][:name], channel[:file][:size] - channel[:remaining], channel[:file][:size])
      await_response(channel, :finish_read) if channel[:remaining] <= 0
    end

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

    def parse_directive(text)
      case type = text[0]
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

    def read_directory(channel, directive)
      if !channel[:options][:recursive]
        raise Net::SCP::Error, ":recursive not specified for directory download"
      end

      channel[:local] = File.join(channel[:local], directive[:name])

      if File.exists?(channel[:local]) && !File.directory?(channel[:local])
        raise "#{channel[:local]} already exists and is not a directory"
      elsif !File.exists?(channel[:local])
        Dir.mkdir(channel[:local], directive[:mode] | 0700)
      end

      if channel[:options][:preserve] && channel[:times]
        File.utime(channel[:times][:atime], channel[:times][:mtime], channel[:local])
      end

      channel[:stack] << directive
      channel[:times] = nil
    end

    def read_file(channel, directive)
      if !channel[:local].respond_to?(:write)
        directive[:name] = (channel[:options][:recursive] || File.directory?(channel[:local])) ?
          File.join(channel[:local], directive[:name]) :
          channel[:local]
      end

      channel[:file] = directive.merge(:times => channel[:times])
      channel[:io] = channel[:local].respond_to?(:write) ? channel[:local] :
        File.new(directive[:name], File::CREAT|File::TRUNC|File::RDWR, directive[:mode] | 0600)
      channel[:times] = nil
      channel[:remaining] = channel[:file][:size]
      channel[:state] = :read_data

      progress_callback(channel, channel[:file][:name], 0, channel[:file][:size])
    end
  end

end; end