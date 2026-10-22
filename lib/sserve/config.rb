# frozen_string_literal: true

require "securerandom"

module Sserve
  # Immutable settings for one server process. Built by the CLI, consumed by
  # the app. Nothing in this object talks to Rack or iodine.
  class Config
    class Error < StandardError; end

    SESSION_IDLE_SECONDS = 12 * 60 * 60
    LOCAL_HOSTS = %w[127.0.0.1 localhost ::1].freeze

    attr_reader :root, :host, :port, :index, :password, :listings, :session_secret, :session_idle_seconds

    def initialize(root:, host: "127.0.0.1", port: 8080, index: "index.html", password: nil,
      listings: false, session_secret: nil, session_idle_seconds: SESSION_IDLE_SECONDS)
      @root = self.class.expand_root(root)
      @host = host.to_s
      raise Error, "host is required" if @host.empty?
      @port = self.class.parse_port(port)
      @index = self.class.parse_index(index)
      @password = password.nil? || password.empty? ? nil : password.to_s
      @listings = listings ? true : false
      @session_idle_seconds = Integer(session_idle_seconds)
      raise Error, "session idle seconds must be positive" unless @session_idle_seconds.positive?
      @session_secret = session_secret || SecureRandom.bytes(64)
      raise Error, "session secret must be at least 64 bytes" if @session_secret.bytesize < 64
      freeze
    end

    def auth_required?
      !password.nil?
    end

    def public_bind?
      !LOCAL_HOSTS.include?(host)
    end

    def self.expand_root(path)
      text = path.to_s
      raise Error, "directory is required" if text.empty?

      expanded = File.expand_path(text)
      raise Error, "directory does not exist: #{text}" unless File.exist?(expanded)
      raise Error, "not a directory: #{text}" unless File.directory?(expanded)

      File.realpath(expanded)
    end

    def self.parse_port(value)
      port = Integer(value)
      raise Error, "port must be between 1 and 65535" unless (1..65535).cover?(port)

      port
    rescue ArgumentError, TypeError
      raise Error, "port must be a number"
    end

    def self.parse_index(value)
      name = value.to_s
      if name.empty? || name.include?("/") || name.include?("\\") || name == "." || name == ".."
        raise Error, "index must be a single filename"
      end

      name
    end
  end
end
