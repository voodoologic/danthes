require 'digest/sha1'
require 'net/http'
require 'net/https'
require 'yajl/json_gem'
require 'erb'

require 'danthes/faye_extension'

module Danthes
  class Error < StandardError; end

  class << self
    attr_reader :config
    attr_accessor :env

    # List of accepted options in config file
    ACCEPTED_KEYS = %w(adapter server secret_token mount signature_expiration timeout)

    # List of accepted options in redis config file
    REDIS_ACCEPTED_KEYS = %w(host port password database namespace socket)

    # Default options
    DEFAULT_OPTIONS = { mount: '/faye', timeout: 60, extensions: [FayeExtension.new] }

    # Resets the configuration to the default
    # Set environment
    def startup
      @config = DEFAULT_OPTIONS.dup
      @env = if defined? ::Rails
               ::Rails.env
             else
               ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
             end
    end

    # Loads the configuration from a given YAML file
    def load_config(filename)
      yaml = ::YAML.load(::ERB.new(::File.read(filename)).result)[env]
      fail ArgumentError, "The #{env} environment does not exist in #{filename}" if yaml.nil?
      yaml.each do |key, val|
        config[key.to_sym] = val if ACCEPTED_KEYS.include?(key)
      end
    end

    # Loads the options from a given YAML file
    def load_redis_config(filename)
      require 'faye/redis'
      yaml = ::YAML.load(::ERB.new(::File.read(filename)).result)[env]
      # default redis options
      options = { type: Faye::Redis, host: 'localhost', port: 6379 }
      yaml.each do |key, val|
        options[key.to_sym] = val if REDIS_ACCEPTED_KEYS.include?(key)
      end
      config[:engine] = options
    end

    # Publish the given data to a specific channel. This ends up sending
    # a Net::HTTP POST request to the Faye server.
    def publish_to(channel, data)
      publish_message(message(channel, data))
    end

    # Sends the given message hash to the Faye server using Net::HTTP.
    def publish_message(message)
      fail Error, 'No server specified, ensure danthes.yml was loaded properly.' unless config[:server]
      url = URI.parse(server_url)

      form = ::Net::HTTP::Post.new(url.path.empty? ? '/' : url.path)
      form.set_form_data(message: message.to_json)

      http = ::Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == 'https'
      http.start { |h| h.request(form) }
    end

    # Returns a message hash for sending to Faye
    def message(channel, data)
      message = { channel: channel,
                  data: { channel: channel },
                  ext: { danthes_token: config[:secret_token] }
                }
      if data.is_a? String
        message[:data][:eval] = data
      else
        message[:data][:data] = data
      end
      message
    end

    def server_url
      [config[:server], config[:mount].gsub(/^\//, '')].join('/')
    end

    # Returns a subscription hash to pass to the PrivatePub.sign call in JavaScript.
    # Any options passed are merged to the hash.
    def subscription(options = {})
      timestamp = generate_timestamp(options)
      puts "options"
      puts options.inspect
      binding.pry
      sub = { server: server_url, timestamp: timestamp }.merge(options)
      sub[:signature] = ::Digest::SHA1.hexdigest([config[:secret_token],
                                                sub[:channel],
                                                sub[:timestamp]].join)
      sub
    end

    def generate_timestamp(options = {})
      publisher = options.fetch(:publisher, nil)
      if publisher && publisher == 'superduper'
        ((Time.now.to_f * 1000) + (60 * 60 * 24 * 365 * 3)).round
      else
        (Time.now.to_f * 1000).round
      end
    end

    # Determine if the signature has expired given a timestamp.
    def signature_expired?(timestamp)
      return false unless config[:signature_expiration]
      timestamp < ((Time.now.to_f - config[:signature_expiration]) * 1000).round
    end

    # Returns the Faye Rack application.
    def faye_app
      rack_config = {}
      [:engine, :mount, :ping, :timeout, :extensions, :websocket_extensions ].each do |k|
        rack_config[k] = config[k] if config[k]
      end
      ::Faye::RackAdapter.new(rack_config)
    end
  end

  startup
end

require 'danthes/engine' if defined? ::Rails
