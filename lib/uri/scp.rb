require 'uri/generic'

module URI
  class SCP < Generic
    DEFAULT_PORT = 22

    COMPONENT = [
      :scheme,
      :userinfo,
      :host, :port, :path,
      :query
    ].freeze

    def self.new2(user, password, host, port, path, query)
      new('scp', [user, password], host, port, nil, path, nil, query)
    end

    def initialize(*args)
      super(*args)

      options
    end

    def options
      return @options if defined?(@options_query) && @options_query == query

      @options_query = query && query.dup
      @options = Hash.new
      (query || "").split(/&/).each do |pair|
        next if pair.empty?
        name, value = pair.split(/=/, 2)
        opt_name = name.to_sym
        values = value.to_s.split(/,/).map { |v| v.to_i.to_s == v ? v.to_i : v }
        values = values.first if values.length == 1
        @options[opt_name] = values
      end
      @options
    end
  end

  if respond_to? :register_scheme
    register_scheme "SCP", SCP
  else
    @@schemes["SCP"] = SCP
  end
end
