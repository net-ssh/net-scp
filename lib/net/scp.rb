require 'net/ssh'
require 'net/scp/upload'
require 'net/scp/download'

module Net
  class SCP
    include Net::SSH::Loggable
    include Upload, Download

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
        channel.close
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