# frozen_string_literal: true

require "optparse"

module Sserve
  class CLI
    def self.start(argv = ARGV, env: ENV, out: $stdout, err: $stderr, server: Server)
      parsed = parse(argv, env: env)
      case parsed
      when :help
        out.puts help
        0
      when :version
        out.puts "sserve #{VERSION}"
        0
      else
        warn_public_bind(parsed, err)
        err.puts banner(parsed)
        server.start(parsed)
        0
      end
    rescue Config::Error, OptionParser::ParseError => e
      err.puts "sserve: #{e.message}"
      err.puts
      err.puts help
      1
    end

    def self.parse(argv, env: ENV)
      options = {}
      mode = :run
      parser = option_parser(options, mode_setter: ->(value) { mode = value })
      parser.parse!(argv)

      return mode unless mode == :run
      raise Config::Error, "unexpected argument: #{argv.first}" unless argv.empty? || argv.one?
      raise Config::Error, "use either --password or --password-env, not both" if options[:password] && options[:password_env]

      password = options[:password]
      if options[:password_env]
        password = env[options[:password_env]]
        raise Config::Error, "environment variable #{options[:password_env]} is empty" if password.nil? || password.empty?
      elsif options.key?(:password) && password.empty?
        raise Config::Error, "password cannot be blank"
      end

      Config.new(
        root: options[:directory] || argv.shift || ".",
        host: options.fetch(:host, "127.0.0.1"),
        port: options.fetch(:port, 8080),
        index: options.fetch(:index, "index.html"),
        password: password,
        listings: options.fetch(:listings, false)
      )
    end

    def self.help
      option_parser({}).to_s
    end

    def self.option_parser(options, mode_setter: ->(_) {})
      OptionParser.new do |parser|
        parser.banner = "Usage: sserve [DIRECTORY] [options]"
        parser.separator ""
        parser.separator "Serve a directory over HTTP. Authentication is off unless a password is set."
        parser.separator ""

        parser.on("-d", "--directory DIR", "Directory to serve (default: .)") { |dir| options[:directory] = dir }
        parser.on("-b", "--bind HOST", "Bind address (default: 127.0.0.1)") { |host| options[:host] = host }
        parser.on("-p", "--port PORT", Integer, "Port (default: 8080)") { |port| options[:port] = port }
        parser.on("-i", "--index NAME", "Index filename (default: index.html)") { |name| options[:index] = name }
        parser.on("-P", "--password PASS", "Shared password. Omit for no authentication") { |pass| options[:password] = pass }
        parser.on("--password-env VAR", "Read the password from an environment variable") { |var| options[:password_env] = var }
        parser.on("-l", "--listings", "Allow directory listings when no index file exists") { options[:listings] = true }
        parser.on("-h", "--help", "Show this help") { mode_setter.call(:help) }
        parser.on("-v", "--version", "Show version") { mode_setter.call(:version) }
      end
    end

    def self.banner(config)
      lines = ["sserve: http://#{config.host}:#{config.port}/", "sserve: serving #{config.root}"]
      lines << (config.auth_required? ? "sserve: password protection on" : "sserve: no password set")
      lines << (config.listings ? "sserve: directory listings on" : "sserve: directory listings off")
      lines.join("\n")
    end

    def self.warn_public_bind(config, err)
      return unless config.public_bind? && !config.auth_required?

      err.puts "sserve: warning: listening on #{config.host} without a password"
    end

    private_class_method :option_parser, :banner, :warn_public_bind
  end
end
