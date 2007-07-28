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

    private

      def begin_mkdir(channel)
        channel[:buffer    ] = Net::SSH::Buffer.new
        channel[:state     ] = :start

        channel.on_data          { |ch, data| channel[:buffer].append(data) }
        channel.on_extended_data { |ch, type, data| debug { data } }
        channel.on_close         { mkdir_cleanup(channel) }
        channel.on_process       { mkdir_state_machine(channel) }

        channel.on_request("exit-status") { |ch, data| channel[:exit] = data.read_long; true }
      end

      def mkdir_cleanup(channel)
        raise "SCP process did not terminate successfully (#{channel[:exit]})" if channel[:exit] != 0
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
          channel.close
        end
      end

      DEFAULT_CHUNK_SIZE = 2048

      def begin_upload(channel)
        channel[:buffer    ] = Net::SSH::Buffer.new
        channel[:state     ] = :start
        channel[:sent      ] = 0
        channel[:size      ] = channel[:options][:size] || (channel[:io].respond_to?(:size) ? channel[:io].size : channel[:io].stat.size)
        channel[:chunk_size] = channel[:options][:chunk_size] || DEFAULT_CHUNK_SIZE

        channel.on_data          { |ch, data| channel[:buffer].append(data) }
        channel.on_extended_data { |ch, type, data| debug { data } }
        channel.on_close         { cleanup_upload(channel) }
        channel.on_process       { state_machine(channel) }

        channel.on_request("exit-status") { |ch, data| channel[:exit] = data.read_long; true }
      end

      def state_machine(channel)
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

      def cleanup_upload(channel)
        channel[:io].close
        raise "SCP process did not terminate successfully (#{channel[:exit]})" if channel[:exit] != 0
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
  end
end

class Net::SSH::Connection::Session
  def scp
    @scp ||= Net::SCP.new(self)
  end
end