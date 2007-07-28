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

    def local_to_remote(io, remote, options={}, &progress)
      io = StringIO.new(io) if String === io
      session.open_channel do |channel|
        channel.exec "scp -t #{remote}" do |ch, success|
          if success
            channel[:io      ] = io
            channel[:remote  ] = remote
            channel[:options ] = options
            channel[:progress] = progress
            begin_upload(channel)
          else
            channel.close
            raise "could not exec scp on the remote host"
          end
        end
      end
    end

    def mkdir(remote, options={})
      session.open_channel do |channel|
        channel.exec "scp -rt #{remote}" do |ch, success|
          if success
            channel[:remote ] = remote
            channel[:options] = options
            begin_mkdir(channel)
          else
            channel.close
            raise "could not exec scp on the remote host"
          end
        end
      end
    end

    def remote_to_local(remote, options={}, &callback)
      session.open_channel do |channel|
        channel.exec "scp -rf #{remote}" do |ch, success|
          if success
            channel[:remote  ] = remote
            channel[:options ] = options
            channel[:callback] = callback
            begin_download(channel)
          else
            channel.close
            raise "could not exec scp on the remote host"
          end
        end
      end
    end

    private

      def prepare_channel(channel)
        channel[:buffer] = Net::SSH::Buffer.new
        channel[:state ] = :start

        channel.on_close                  { |ch| raise "SCP did not finish successfully (#{ch[:exit]})" if ch[:exit] != 0 }
        channel.on_data                   { |ch, data| channel[:buffer].append(data) }
        channel.on_extended_data          { |ch, type, data| debug { data } }
        channel.on_request("exit-status") { |ch, data| channel[:exit] = data.read_long; true }
      end

      def begin_download(channel)
        prepare_channel(channel)
        channel[:stack] = []
        channel.on_process { download_state_machine(channel) }
      end

      def download_state_machine(channel)
        case channel[:state]
        when :start
          channel[:callback].call(:begin)
          channel.send_data("\0")
          channel[:state] = :directive
        when :directive
          process_directive(channel)
        when :read
          download_read(channel)
        when :finish_read
          download_finish_read(channel)
        when :finish
          channel[:callback].call(:end)
          channel.close
        end
      end

      def download_read(channel)
        return if channel[:buffer].empty?
        data = channel[:buffer].read!(channel[:remaining])
        channel[:callback].call(:read, channel[:file], data)
        channel[:remaining] -= data.length
        if channel[:remaining] == 0
          channel[:state] = :finish_read
          download_state_machine(channel)
        end
      end

      def download_finish_read(channel)
        if check_response(channel)
          channel[:callback].call(:finish, channel[:file])
          channel[:file] = nil
          channel[:state] = channel[:stack].empty? ? :finish : :directive
          channel.send_data("\0")
        end
      end

      def begin_mkdir(channel)
        prepare_channel(channel)
        channel.on_process { mkdir_state_machine(channel) }
      end

      def mkdir_state_machine(channel)
        case channel[:state]
        when :start
          mkdir_start_state(channel)
        when :close
          mkdir_close_state(channel)
        when :finish
          mkdir_finish_state(channel)
        end
      end

      def mkdir_start_state(channel)
        if check_response(channel)
          mode = channel[:options][:mode] || 0700
          directive = "D%04o %d %s\n" % [mode, 0, File.basename(channel[:remote])]
          channel.send_data(directive)
          channel[:state] = :close
        end
      end

      def mkdir_close_state(channel)
        if check_response(channel)
          channel.send_data("E\n")
          channel[:state] = :finish
        end
      end

      def mkdir_finish_state(channel)
        if check_response(channel)
          # FIXME technically need to send "\0" and wait for response one more time
          channel.close
        end
      end

      DEFAULT_CHUNK_SIZE = 2048

      def begin_upload(channel)
        prepare_channel(channel)

        channel[:sent      ] = 0
        channel[:size      ] = channel[:options][:size] || (channel[:io].respond_to?(:size) ? channel[:io].size : channel[:io].stat.size)
        channel[:chunk_size] = channel[:options][:chunk_size] || DEFAULT_CHUNK_SIZE

        channel.on_process { upload_state_machine(channel) }
      end

      def upload_state_machine(channel)
        case channel[:state]
        when :start
          start_state(channel)
        when :upload
          upload_state(channel)
        when :continue
          send_next_chunk(channel)
        when :finish
          channel.close
        end
      end

      def start_state(channel)
        if check_response(channel)
          mode = channel[:options][:mode] || 0600
          size = channel[:options][:size] || (channel[:io].respond_to?(:size) ? channel[:io].size : channel[:io].stat.size)
          directive = "C%04o %d %s\n" % [mode, size, File.basename(channel[:remote])]
          channel.send_data(directive)
          update_progress(channel)
          channel[:state] = :upload
        end
      end

      def upload_state(channel)
        if check_response(channel)
          channel[:state] = :continue
          send_next_chunk(channel)
        end
      end

      def send_next_chunk(channel)
        data = channel[:io].read(channel[:chunk_size])
        if data.nil?
          channel.send_data("\0")
          channel[:state] = :finish
        else
          channel[:sent] += data.length
          channel.send_data(data)
          update_progress(channel)
        end
      end

      def check_response(channel)
        return false if channel[:buffer].available == 0
        c = channel[:buffer].read_byte
        return true if c == 0
        raise "#{c.chr}#{channel[:buffer].read}"
      end

      def update_progress(channel)
        if channel[:progress]
          channel[:progress].call(channel[:sent], channel[:size])
        end
      end

      def process_directive(channel)
        return unless line = channel[:buffer].read_to("\n")
        channel[:buffer].consume!

        directive = parse_directive(line)
        case directive[:type]
        when :times then
          channel[:times] = directive
        when :directory
          channel[:stack] << directive.merge(:times => channel[:times])
          channel[:times] = nil
          channel[:callback].call(:in, channel[:stack].last)
        when :file
          channel[:file] = directive.merge(:times => channel[:times])
          channel[:times] = nil
          channel[:remaining] = channel[:file][:size]
          channel[:callback].call(:start, channel[:file])
          channel[:state] = :read
        when :end
          channel[:callback].call(:out, channel[:stack].pop)
          channel[:state] = :finish if channel[:stack].empty?
        end

        channel.send_data("\0")
      end

      def parse_directive(text)
        case type = text[0]
        when ?T
          parts = text[1..-1].split(/ /, 4).map { |i| i.to_i }
          { :type       => :times,
            :mtime_sec  => parts[0],
            :mtime_usec => parts[1],
            :atime_sec  => parts[2],
            :atime_usec => parts[3] }
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
  end
end

class Net::SSH::Connection::Session
  def scp
    @scp ||= Net::SCP.new(self)
  end
end