require 'open-uri'
require 'uri/scp'
require 'net/scp'

OpenURI::Options[:ssh] = nil

module URI

  class SCP
    def buffer_open(buf, proxy, open_options)
      options = open_options.merge(:port => port, :password => password)
      progress = options.delete(:progress_proc)
      content_length = options.delete(:content_length_proc)
      buf << Net::SCP.download!(host, user, path, nil, options) do |_channel, _name, received, total|
        if content_length
          content_length.call(total)
          content_length = nil
        end
        progress.call(received) if progress
      end
      buf.io.rewind
    end

    include OpenURI::OpenRead
  end

end
