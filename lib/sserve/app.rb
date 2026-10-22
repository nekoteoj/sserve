# frozen_string_literal: true

require "digest"
require "rack/files"
require "rack/utils"
require "roda"
require "securerandom"

module Sserve
  # HTTP adapter. Routing and response mapping live here; password checks and
  # path rules stay in Auth and Files.
  class App < Roda
    VIEWS = File.expand_path("views", __dir__)
    STYLESHEET = File.read(File.join(VIEWS, "app.css")).freeze
    # Fixed name used before the cookie was tied to the process secret.
    LEGACY_SESSION_KEY = "sserve.session"
    SESSION_KEY_PATTERN = /\Asserve\.sid\.[0-9a-f]{16}\z/
    FILE_HEADERS = {"x-content-type-options" => "nosniff"}.freeze
    FILE_STATUSES = [200, 206, 304, 416].freeze
    MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

    plugin :render, views: VIEWS, layout: "layout", escape: true, engine: "erb"
    plugin :default_headers,
      "Content-Type" => "text/html; charset=utf-8",
      "X-Content-Type-Options" => "nosniff",
      "X-Frame-Options" => "DENY",
      "Referrer-Policy" => "no-referrer"
    plugin :content_security_policy do |csp|
      csp.default_src :none
      csp.form_action :self
      csp.base_uri :none
      csp.frame_ancestors :none
    end
    plugin :typecast_params
    plugin :head

    def self.build(config)
      klass = Class.new(self)
      klass.opts[:sserve_config] = config
      key = nil
      if config.auth_required?
        # The name changes with the secret. A fixed name lets a cookie from the
        # previous process hide this one, because Rack keeps the first of a name.
        key = session_cookie_key(config.session_secret)
        klass.plugin :sessions,
          secret: config.session_secret,
          key: key,
          max_idle_seconds: config.session_idle_seconds,
          max_seconds: nil,
          cookie_options: { path: config.prefix.empty? ? "/" : config.prefix }
        klass.plugin :route_csrf do |_request|
          response.status = 403
          @title = "Forbidden"
          @message = "The form expired. Refresh and try again."
          view("error")
        end
      end
      app = klass.freeze.app
      app = StaleSessionCookies.new(app, key: key, prefix: config.prefix) if key
      Mount.new(app, config.prefix)
    end

    # Cookie name for this process. Sixteen hex chars is enough to keep two
    # processes on the same host from sharing a name; the secret itself stays
    # out of the cookie jar.
    def self.session_cookie_key(secret)
      "sserve.sid.#{Digest::SHA256.hexdigest(secret)[0, 16]}"
    end
    private_class_method :session_cookie_key

    route do |r|
      apply_style_policy

      r.on "_sserve" do
        r.is "login" do
          next render_missing unless config.auth_required?

          r.get do
            next request.redirect(public_path(safe_return_to)) if authenticated?

            render_login
          end

          r.post do
            check_csrf!
            submit_login
          end
        end

        r.post "logout" do
          next render_missing unless config.auth_required?

          check_csrf!
          session.clear
          request.redirect login_path
        end

        render_missing
      end

      request.redirect login_url unless authenticated?

      r.on method: [:get, :head] do
        serve_current
      end

      method_not_allowed
    end

    def page_nonce
      @page_nonce ||= SecureRandom.urlsafe_base64(16)
    end

    def stylesheet
      STYLESHEET
    end

    def human_size(bytes)
      return "—" unless bytes

      units = %w[B KB MB GB TB]
      value = bytes.to_f
      unit = 0
      while value >= 1024 && unit < units.length - 1
        value /= 1024.0
        unit += 1
      end
      number = unit.zero? ? value.to_i.to_s : format("%<value>.1f", value: value)
      "#{number} #{units[unit]}"
    end

    def human_time(time)
      "#{time.day} #{MONTHS[time.month - 1]} #{time.year}"
    end

    # Browser path for an internal path. script_name is the mount prefix after
    # Mount strips it from PATH_INFO, or empty when the app is at the origin root.
    def public_path(internal)
      prefix = request.script_name.to_s
      return internal if prefix.empty?
      return prefix if internal == "/"

      "#{prefix}#{internal}"
    end

    def login_path
      public_path("/_sserve/login")
    end

    def logout_path
      public_path("/_sserve/logout")
    end

    private

    def config
      self.class.opts[:sserve_config]
    end

    def apply_style_policy
      content_security_policy.style_src [:nonce, page_nonce]
    end

    def authenticator
      @authenticator ||= Auth::Authenticator.new(config.password)
    end

    def catalog
      @catalog ||= Files::Catalog.new(config)
    end

    def file_server
      @file_server ||= Rack::Files.new(config.root)
    end

    def authenticated?
      return true unless config.auth_required?
      return false unless signed_in?

      session["seen"] = Time.now.to_i
      true
    end

    def login_url
      "#{login_path}?return_to=#{Rack::Utils.escape(internal_fullpath)}"
    end

    def internal_fullpath
      query = request.query_string
      query.nil? || query.empty? ? request.path_info : "#{request.path_info}?#{query}"
    end

    def safe_return_to
      Auth::ReturnTo.sanitize(string_param("return_to"))
    end

    def string_param(key)
      typecast_params.str(key)
    rescue Roda::RodaPlugins::TypecastParams::Error
      nil
    end

    def submit_login
      destination = safe_return_to
      if authenticator.valid?(string_param("password"))
        session["authenticated"] = true
        request.redirect public_path(destination)
      else
        render_login(error: "Incorrect password.", status: 401)
      end
    end

    def render_login(error: nil, status: 200)
      response.status = status
      @title = "Enter Password"
      @error = error
      @return_to = safe_return_to
      view("login")
    end

    def serve_current
      result = catalog.lookup(request.path_info)
      redirect_directory(result.directory_path) if result.directory_path

      case result.type
      when :file
        serve_file(result.path)
      when :listing
        render_listing(result)
      when :forbidden
        render_status(403, "Forbidden", "This directory cannot be listed.")
      else
        render_missing
      end
    end

    def serve_file(path)
      relative = path == config.root ? "" : path.delete_prefix("#{config.root}/")
      # Rack::Files percent-decodes PATH_INFO. Escape the accepted relative
      # path so decoding restores that file instead of a different one.
      env = request.env.merge("PATH_INFO" => "/#{Rack::Utils.escape_path(relative)}")
      status, headers, body = file_server.call(env)
      request.halt [status, headers.merge(FILE_HEADERS), body] if FILE_STATUSES.include?(status)

      close_body(body)
      render_missing
    end

    def redirect_directory(real)
      target = directory_url_path(real)
      return if request.path_info == target

      query = request.query_string
      location = public_path(target)
      request.redirect(query.nil? || query.empty? ? location : "#{location}?#{query}")
    end

    def directory_url_path(real)
      return "/" if real == config.root

      "/#{real.delete_prefix("#{config.root}/")}/"
    end

    def render_listing(result)
      path = directory_url_path(result.path)
      @title = listing_title(path)
      @entries = result.entries
      @authenticated = config.auth_required?
      @parent = parent_href(path)
      @parent_name = @parent ? parent_name(@parent) : nil
      view("listing")
    end

    def listing_title(path)
      segment = path.delete_suffix("/").split("/").last
      segment.nil? || segment.empty? ? File.basename(config.root) : segment
    end

    def parent_href(path)
      trimmed = path.delete_suffix("/")
      return nil if trimmed.empty?

      parent = File.dirname(trimmed)
      parent == "/" ? "/" : "#{parent}/"
    end

    def parent_name(href)
      return File.basename(config.root) if href == "/"

      File.basename(href.delete_suffix("/"))
    end

    def render_missing
      render_status(404, "Not Found", "That file is not here.")
    end

    def method_not_allowed
      response.headers["Allow"] = "GET, HEAD"
      render_status(405, "Method Not Allowed", "Only GET and HEAD are supported.")
    end

    def render_status(status, title, message)
      response.status = status
      @title = title
      @message = message
      @authenticated = signed_in?
      view("error")
    end

    def signed_in?
      config.auth_required? && session["authenticated"] == true
    end

    def close_body(body)
      body.close if body.respond_to?(:close)
    end
  end

  # Moves a configured mount prefix from PATH_INFO onto SCRIPT_NAME once.
  # The proxy must forward the prefix unchanged. Stripping it again would make
  # a directory of the same name resolve to the wrong file.
  class App::Mount
    def initialize(app, prefix)
      @app = app
      @prefix = prefix.to_s
    end

    def call(env)
      strip(env) unless @prefix.empty?
      @app.call(env)
    end

    private

    def strip(env)
      path = env["PATH_INFO"].to_s
      return unless path == @prefix || path.start_with?("#{@prefix}/")

      rest = path.delete_prefix(@prefix)
      env["SCRIPT_NAME"] = "#{env["SCRIPT_NAME"]}#{@prefix}"
      env["PATH_INFO"] = rest.empty? ? "/" : rest
    end
  end

  # Expires session cookies this process will not read. A restart generates a
  # new secret, so the previous cookie name is still in the browser. Deleting
  # it keeps the jar from growing; the new name is what makes login work
  # without asking the visitor to clear cookies.
  class App::StaleSessionCookies
    def initialize(app, key:, prefix:)
      @app = app
      @key = key
      @paths = ["/", prefix.to_s].uniq.reject(&:empty?)
    end

    def call(env)
      status, headers, body = @app.call(env)
      stale_names(env["HTTP_COOKIE"]).each { |name| expire(headers, name) }
      [status, headers, body]
    end

    private

    def stale_names(header)
      return [] if header.nil? || header.empty?

      Rack::Utils.parse_cookies_header(header).keys.select { |name| stale?(name) }
    end

    def stale?(name)
      name == App::LEGACY_SESSION_KEY || (name.match?(App::SESSION_KEY_PATTERN) && name != @key)
    end

    def expire(headers, name)
      @paths.each do |path|
        options = { path: path, httponly: true, same_site: :lax }
        Rack::Utils.delete_cookie_header!(headers, name, options)
        Rack::Utils.delete_cookie_header!(headers, name, options.merge(secure: true))
      end
    end
  end
end
