module Net; class SCP

  module Upload
    private

    DEFAULT_CHUNK_SIZE = 2048

    def upload_start_state(channel)
      if channel[:local].respond_to?(:read) && channel[:options][:recursive]
        raise "cannot recursively upload from an in-memory buffer"
      elsif channel[:local].respond_to?(:read) && channel[:options][:preserve]
        raise "cannot preserve access times from an in-memory buffer"
      end

      channel[:chunk_size] = channel[:options][:chunk_size] || DEFAULT_CHUNK_SIZE
      set_current(channel, channel[:local])
      await_response(channel, :upload_current)
    end

    def upload_current_state(channel)
      if channel[:current].respond_to?(:read)
        upload_file_state(channel)
      elsif File.directory?(channel[:current])
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
        mode = channel[:stat] ? channel[:stat].mode & 07777 : channel[:options][:mode]
        channel[:name] = channel[:current].respond_to?(:read) ? channel[:remote] : channel[:current]
        directive = "C%04o %d %s\n" % [mode || 0640, channel[:size], File.basename(channel[:name])]
        channel.send_data(directive)
        channel[:io] = channel[:current].respond_to?(:read) ? channel[:current] : File.open(channel[:current], "rb")
        channel[:sent] = 0
        progress_callback(channel, channel[:name], channel[:sent], channel[:size])
        await_response(channel, :send_data)
      end
    end

    def send_data_state(channel)
      data = channel[:io].read(channel[:chunk_size])
      if data.nil?
        channel[:io].close unless channel[:local].respond_to?(:read)
        channel.send_data("\0")
        await_response(channel, :next_item)
      else
        channel[:sent] += data.length
        progress_callback(channel, channel[:name], channel[:sent], channel[:size])
        channel.send_data(data)
      end
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

    def set_current(channel, path)
      path = channel[:cwd] ? File.join(channel[:cwd], path) : path
      channel[:current] = path

      if channel[:current].respond_to?(:read)
        channel[:stat] = channel[:current].stat if channel[:current].respond_to?(:stat)
      else
        channel[:stat] = File.stat(channel[:current])
      end

      channel[:size] = channel[:stat] ? channel[:stat].size : channel[:current].size
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
  end

end; end