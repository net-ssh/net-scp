require 'open-uri'
require 'uri/scp'
require 'net/scp'

OpenURI::Options[:ssh] = nil

module URI

  class SCP
    def buffer_open(buf, proxy, open_options)
      options = open_options.merge(:port => port, :password => password)
      progress = options.delete(:progress_proc)
      output = Object.new
      output.define_singleton_method(:write) { |data| buf << data }
      Net::SCP.download!(host, user, path, output, options, &progress)
      buf.io.rewind
    end

    include OpenURI::OpenRead
  end

end
