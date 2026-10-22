require 'open-uri'
require 'uri/scp'
require 'net/scp'

OpenURI::Options[:ssh] = nil

module URI

  class SCP
    def buffer_open(buf, proxy, open_options)
      options = open_options.merge(:port => port, :password => password && URI::DEFAULT_PARSER.unescape(password))
      progress = options.delete(:progress_proc)
      buf << Net::SCP.download!(hostname, user && URI::DEFAULT_PARSER.unescape(user), URI::DEFAULT_PARSER.unescape(path), nil, options, &progress)
      buf.io.rewind
    end

    include OpenURI::OpenRead
  end

end
