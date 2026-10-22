# frozen_string_literal: true

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
    SESSION_KEY = "sserve.session"
    FILE_HEADERS = {"x-content-type-options" => "nosniff"}.freeze
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

    def self.build(config)
      klass = Class.new(self)
      klass.opts[:sserve_config] = config
      if config.auth_required?
        klass.plugin :sessions,
          secret: config.session_secret,
          key: SESSION_KEY,
          max_idle_seconds: config.session_idle_seconds,
          max_seconds: nil
        klass.plugin :route_csrf do |_request|
          response.status = 403
          @title = "Forbidden"
          @message = "The form expired. Refresh and try again."
          view("error")
        end
      end
      klass.freeze.app
    end

    route do |r|
      apply_style_policy

      r.on "_sserve" do
        r.is "login" do
          next render_missing unless config.auth_required?

          r.get do
            next request.redirect(safe_return_to) if authenticated?

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
          request.redirect "/_sserve/login"
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
      "/_sserve/login?return_to=#{Rack::Utils.escape(request.fullpath)}"
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
        request.redirect destination
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
      result = catalog.lookup(request.path)
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
      status, headers, body = file_server.call(request.env.merge("PATH_INFO" => "/#{relative}"))
      request.halt [status, headers.merge(FILE_HEADERS), body]
    end

    def render_listing(result)
      path = request.path
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
  end
end
