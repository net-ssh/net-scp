require 'net/ssh'
require 'stringio'

module Net
  class SCP
    include Net::SSH::Loggable

    attr_reader :session

    def initialize(session)
      @session = session
      self.logger = session.logger
    end

    def upload(local, remote, options={}, &progress)
      start_command(:upload, local, remote, options, &progress)
    end

    def download(remote, local, options={}, &progress)
      start_command(:download, local, remote, options, &progress)
    end

    private

      DEFAULT_CHUNK_SIZE = 2048

      def start_command(mode, local, remote, options={}, &callback)
        session.open_channel do |channel|
          command = "#{scp_command(mode, options)} #{remote}"
          channel.exec(command) do |ch, success|
            if success
              channel[:local   ] = local
              channel[:remote  ] = remote
              channel[:options ] = options
              channel[:callback] = callback
              channel[:buffer  ] = Net::SSH::Buffer.new
              channel[:state   ] = :"#{mode}_start"
              channel[:stack   ] = []

              channel.on_close                  { |ch| raise "SCP did not finish successfully (#{ch[:exit]})" if ch[:exit] != 0 }
              channel.on_data                   { |ch, data| channel[:buffer].append(data) }
              channel.on_extended_data          { |ch, type, data| debug { data.chomp } }
              channel.on_request("exit-status") { |ch, data| channel[:exit] = data.read_long; true }
              channel.on_process                { send("#{channel[:state]}_state", channel) }
            else
              channel.close
              raise "could not exec scp on the remote host"
            end
          end
        end
      end

      def scp_command(mode, options)
        command = "scp "
        command << (mode == :upload ? "-t" : "-f")
        command << " -v" if options[:verbose]
        command << " -r" if options[:recursive]
        command << " -p" if options[:preserve]
        command
      end

      def upload_start_state(channel)
        channel[:chunk_size] = channel[:options][:chunk_size] || DEFAULT_CHUNK_SIZE
        set_current(channel, channel[:local])
        await_response(channel, :upload_current)
      end

      def download_start_state(channel)
        if channel[:options][:recursive] && !File.exists?(channel[:local])
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
        when :file
          directive[:name] = (channel[:options][:recursive] || File.directory?(channel[:local])) ?
            File.join(channel[:local], directive[:name]) :
            channel[:local]

          channel[:file] = directive.merge(:times => channel[:times])
          channel[:io] = File.new(directive[:name], File::CREAT|File::TRUNC|File::RDWR, directive[:mode] | 0600)
          channel[:times] = nil
          channel[:remaining] = channel[:file][:size]
          channel[:state] = :read_data

          progress_callback(channel, channel[:file][:name], 0, channel[:file][:size])
        when :end
          channel[:local] = File.dirname(channel[:local])
          channel[:state] = :finish if channel[:stack].empty?
        end

        channel.send_data("\0")
      end

      def finish_state(channel)
        channel.close
      end

      def read_data_state(channel)
        return if channel[:buffer].empty?
        data = channel[:buffer].read!(channel[:remaining])
        channel[:io].write(data)
        channel[:remaining] -= data.length
        progress_callback(channel, channel[:file][:name], channel[:file][:size] - channel[:remaining], channel[:file][:size])
        await_response(channel, :finish_read) if channel[:remaining] == 0
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

      def finish_read_state(channel)
        channel[:io].close

        if channel[:options][:preserve] && channel[:file][:times]
          File.utime(channel[:file][:times][:atime],
            channel[:file][:times][:mtime], channel[:file][:name])
        end

        channel[:file] = nil
        channel[:state] = channel[:stack].empty? ? :finish : :read_directive
        channel.send_data("\0")
      end

      def set_current(channel, path)
        path = channel[:cwd] ? File.join(channel[:cwd], path) : path
        channel[:current] = path
        channel[:stat] = File.stat(path)
      end

      def next_item_state(channel)
        if channel[:stack].empty?
          finish_state(channel)
        else
          next_item = channel[:stack].last.shift
          if next_item.nil?
            channel[:stack].pop
            channel[:cwd] = File.dirname(channel[:cwd])
            channel.send_data("E\n")
            await_response(channel, channel[:stack].empty? ? :finish : :next_item)
          else
            set_current(channel, next_item)
            upload_current_state(channel)
          end
        end
      end
  
      def upload_current_state(channel)
        if File.directory?(channel[:current])
          raise ArgumentError, "can't upload directories unless :recursive" unless channel[:options][:recursive]
          upload_directory_state(channel)
        elsif File.file?(channel[:current])
          upload_file_state(channel)
        else
          raise ArgumentError, "not a directory or a regular file: #{channel[:current].inspect}"
        end
      end

      def upload_directory_state(channel)
        if preserve_attributes_if_requested(channel)
          mode = channel[:stat].mode & 07777
          directive = "D%04o %d %s\n" % [mode, 0, File.basename(channel[:current])]
          channel.send_data(directive)
          channel[:cwd] = channel[:current]
          channel[:stack] << Dir.entries(channel[:current]).reject { |i| i == "." || i == ".." }
          await_response(channel, :next_item)
        end
      end

      def upload_file_state(channel)
        if preserve_attributes_if_requested(channel)
          mode = channel[:stat].mode & 07777
          directive = "C%04o %d %s\n" % [mode, channel[:stat].size, File.basename(channel[:current])]
          channel.send_data(directive)
          channel[:io] = File.open(channel[:current], "rb")
          channel[:sent] = 0
          progress_callback(channel, channel[:current], channel[:sent], channel[:stat].size)
          await_response(channel, :send_data)
        end
      end

      def preserve_attributes_if_requested(channel)
        if channel[:options][:preserve] && !channel[:preserved]
          channel[:preserved] = true
          stat = channel[:stat]
          directive = "T%d %d %d %d\n" % [stat.mtime.to_i, stat.mtime.usec, stat.atime.to_i, stat.atime.usec]
          channel.send_data(directive)
          type = stat.directory? ? :directory : :file
          await_response(channel, :"upload_#{type}")
          return false
        else
          channel[:preserved] = false
          return true
        end
      end

      def send_data_state(channel)
        data = channel[:io].read(channel[:chunk_size])
        if data.nil?
          channel[:io].close
          channel.send_data("\0")
          await_response(channel, :next_item)
        else
          channel[:sent] += data.length
          progress_callback(channel, channel[:current], channel[:sent], channel[:stat].size)
          channel.send_data(data)
        end
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