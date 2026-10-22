# frozen_string_literal: true

require "tmpdir"

RSpec.describe Sserve::App do
  include Rack::Test::Methods

  around do |example|
    Dir.mktmpdir("sserve-app") do |dir|
      @root = dir
      File.write(File.join(dir, "hello.txt"), "hi")
      example.run
    end
  end

  def app
    described_class.build(@config)
  end

  def config(**overrides)
    @config = Sserve::Config.new(
      root: @root,
      password: overrides.fetch(:password, nil),
      listings: overrides.fetch(:listings, false),
      index: overrides.fetch(:index, "index.html"),
      prefix: overrides.fetch(:prefix, nil),
      session_secret: "s" * 64,
      session_idle_seconds: overrides.fetch(:session_idle_seconds, 12 * 60 * 60)
    )
  end

  def csrf_from(body, path)
    body[/name="_csrf" value="([^"]+)"/, 1] ||
      raise("missing csrf token for #{path} in #{body}")
  end

  def login(password, return_to: "/hello.txt")
    get "/_sserve/login", { "return_to" => return_to }
    token = csrf_from(last_response.body, "/_sserve/login")
    post "/_sserve/login", { "password" => password, "return_to" => return_to, "_csrf" => token }
  end

  def call_app(app, path)
    status, headers, body = app.call(Rack::MockRequest.env_for(path))
    text = +""
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    [status, headers, text]
  end

  def set_cookie_headers(response = last_response)
    Array(response.headers["set-cookie"])
  end

  def live_session_pair(headers)
    Array(headers["set-cookie"]).map { |header| header.split(";", 2).first }.find do |pair|
      name, value = pair.split("=", 2)
      name.match?(/\Asserve\.sid\.[0-9a-f]{16}\z/) && !value.to_s.empty?
    end || raise("missing session cookie in #{headers["set-cookie"].inspect}")
  end

  it "serves files with no login when a password is not set" do
    config
    get "/hello.txt"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("hi")
    expect(last_response.headers["content-type"]).to include("text/plain")
    expect(last_response.headers["x-content-type-options"]).to eq("nosniff")

    get "/_sserve/login"
    expect(last_response.status).to eq(404)
  end

  it "serves an index file and otherwise forbids directory listings" do
    File.write(File.join(@root, "index.html"), "<p>home</p>")
    config(listings: false)

    get "/"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("home")

    Dir.mkdir(File.join(@root, "docs"))
    get "/docs/"
    expect(last_response.status).to eq(403)
    expect(last_response.body).to include("cannot be listed")
  end

  it "lists a directory when listings are enabled and hides dotfiles" do
    File.write(File.join(@root, ".env"), "SECRET")
    config(listings: true)

    get "/"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("hello.txt")
    expect(last_response.body).not_to include(".env")
  end

  it "redirects anonymous requests to a password form and rejects a bad password" do
    config(password: "s3cret")

    get "/hello.txt"
    expect(last_response).to be_redirect
    expect(last_response.location).to include("/_sserve/login")
    expect(last_response.location).to include("return_to=")

    get "/_sserve/login"
    expect(last_response.body).to include('type="password"')
    expect(last_response.body).not_to include("username")
    expect(last_response.body).to include("Enter Password")
    expect(last_response.headers["content-security-policy"]).to include("nonce-")

    login("nope")
    expect(last_response.status).to eq(401)
    expect(last_response.body).to include("Incorrect password")

    get "/hello.txt"
    expect(last_response).to be_redirect
  end

  it "signs in, follows a safe return path, and ignores an external one" do
    config(password: "s3cret")

    login("s3cret", return_to: "/hello.txt")
    expect(last_response).to be_redirect
    expect(last_response.location).to eq("/hello.txt")
    expect(last_response.headers["set-cookie"]).to include("sserve.sid.")
    expect(last_response.headers["set-cookie"]).not_to include("max-age=0")

    get last_response.location
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("hi")
  end

  it "ignores an external return path" do
    config(password: "s3cret")
    get "/_sserve/login", { "return_to" => "https://evil.test/phish" }
    expect(last_response.body).to include('value="/"')

    token = csrf_from(last_response.body, "/_sserve/login")
    post "/_sserve/login", {
      "password" => "s3cret",
      "return_to" => "//evil.test",
      "_csrf" => token
    }
    expect(last_response.location).to eq("/")
  end

  it "rejects a login without a csrf token" do
    config(password: "s3cret")
    get "/_sserve/login"
    post "/_sserve/login", { "password" => "s3cret", "return_to" => "/hello.txt" }

    expect(last_response.status).to eq(403)
    get "/hello.txt"
    expect(last_response).to be_redirect
  end

  it "logs out" do
    config(password: "s3cret", listings: true)
    login("s3cret", return_to: "/")
    follow_redirect!

    token = csrf_from(last_response.body, "/_sserve/logout")
    post "/_sserve/logout", { "_csrf" => token }

    expect(last_response).to be_redirect
    get "/hello.txt"
    expect(last_response).to be_redirect
    expect(last_response.location).to include("/_sserve/login")
  end

  it "answers HEAD and rejects other methods" do
    config(listings: true)

    head "/hello.txt"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("")

    head "/"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("")

    post "/hello.txt"
    expect(last_response.status).to eq(405)
    expect(last_response.headers["allow"]).to eq("GET, HEAD")
  end

  it "does not serve an index file inside a hidden directory" do
    Dir.mkdir(File.join(@root, ".hidden"))
    File.write(File.join(@root, ".hidden", "index.html"), "SECRET INDEX")
    config

    get "/.hidden/index.html"

    expect(last_response.status).to eq(404)
    expect(last_response.body).not_to include("SECRET INDEX")
  end

  it "redirects a directory request to its canonical trailing slash" do
    Dir.mkdir(File.join(@root, "docs"))
    File.write(File.join(@root, "docs", "index.html"), "<link href=\"style.css\">")
    File.write(File.join(@root, "docs", "note.txt"), "n")
    config(listings: true)

    get "/docs"
    expect(last_response).to be_redirect
    expect(last_response.location).to eq("/docs/")

    get "/docs?x=1"
    expect(last_response.location).to eq("/docs/?x=1")

    follow_redirect!
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("style.css")
    expect(last_response.headers["content-security-policy"]).to be_nil
  end

  it "redirects a double-slash directory request to the canonical path" do
    Dir.mkdir(File.join(@root, "docs"))
    File.write(File.join(@root, "docs", "note.txt"), "n")
    config(listings: true)

    status, headers, body = app.call(Rack::MockRequest.env_for("/").merge("PATH_INFO" => "//docs"))
    text = +""
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)

    expect(status).to eq(302)
    expect(headers["location"]).to eq("/docs/")
    expect(text).not_to include("//docs")
  end

  it "serves the file that was accepted when its name contains percent escapes" do
    Dir.mkdir(File.join(@root, "docs"))
    File.write(File.join(@root, "docs", ".env"), "DOTENV")
    File.write(File.join(@root, "docs%2f.env"), "literal")
    config

    get "/docs%2f.env"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("literal")
    expect(last_response.headers["content-security-policy"]).to be_nil
  end

  it "does not put a return path with a newline into the location header" do
    config(password: "s3cret")
    get "/_sserve/login"
    token = csrf_from(last_response.body, "/_sserve/login")

    post "/_sserve/login", {
      "password" => "s3cret",
      "return_to" => "/ok\r\nSet-Cookie: pwned=1",
      "_csrf" => token
    }

    expect(last_response).to be_redirect
    expect(last_response.location).to eq("/")
    expect(last_response.headers["set-cookie"]).not_to include("pwned")
  end

  it "expires an idle session" do
    config(password: "s3cret", session_idle_seconds: 10)
    now = Time.at(1_700_000_000)
    allow(Time).to receive(:now).and_return(now)

    login("s3cret")
    get "/hello.txt"
    expect(last_response.status).to eq(200)

    allow(Time).to receive(:now).and_return(now + 11)
    get "/hello.txt"
    expect(last_response).to be_redirect
  end

  describe "with a mount prefix" do
    it "strips the prefix once, including when a directory has the same name" do
      File.write(File.join(@root, "index.html"), "root-index")
      File.write(File.join(@root, "filesomething.txt"), "lookalike")
      Dir.mkdir(File.join(@root, "files"))
      File.write(File.join(@root, "files", "index.html"), "nested-index")
      config(prefix: "/files")

      get "/files"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("root-index")

      get "/files/files"
      expect(last_response).to be_redirect
      expect(last_response.location).to eq("/files/files/")

      follow_redirect!
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("nested-index")

      get "/filesomething.txt"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("lookalike")

      get "/hello.txt"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("hi")
    end

    it "keeps login, listings, and the session cookie under the prefix" do
      Dir.mkdir(File.join(@root, "docs"))
      File.write(File.join(@root, "docs", "note.txt"), "n")
      config(password: "s3cret", listings: true, prefix: "/tools/files")

      get "/tools/files/docs"
      expect(last_response).to be_redirect
      expect(last_response.location).to eq("/tools/files/_sserve/login?return_to=%2Fdocs")

      get "/tools/files/hello.txt?x=1"
      expect(last_response.location).to eq("/tools/files/_sserve/login?return_to=%2Fhello.txt%3Fx%3D1")

      get "/tools/files/_sserve/login", { "return_to" => "/hello.txt" }
      expect(last_response.body).to include('action="/tools/files/_sserve/login"')
      expect(last_response.body).to include('value="/hello.txt"')
      token = csrf_from(last_response.body, "/tools/files/_sserve/login")
      post "/tools/files/_sserve/login", {
        "password" => "s3cret",
        "return_to" => "/hello.txt",
        "_csrf" => token
      }
      expect(last_response).to be_redirect
      expect(last_response.location).to eq("/tools/files/hello.txt")
      expect(last_response.headers["set-cookie"]).to include("path=/tools/files")

      get last_response.location
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("hi")

      get "/tools/files/_sserve/login", { "return_to" => "/hello.txt" }
      expect(last_response).to be_redirect
      expect(last_response.location).to eq("/tools/files/hello.txt")

      get "/tools/files/"
      expect(last_response.body).to include('href="/tools/files/hello.txt"')
      expect(last_response.body).to include('href="/tools/files/docs/"')
      expect(last_response.body).to include('action="/tools/files/_sserve/logout"')

      get "/tools/files/docs?x=1"
      expect(last_response.location).to eq("/tools/files/docs/?x=1")
      follow_redirect!
      expect(last_response.body).to include('href="/tools/files"')
      expect(last_response.body).to include("note.txt")

      get "/tools/files/"
      token = csrf_from(last_response.body, "/tools/files/_sserve/logout")
      post "/tools/files/_sserve/logout", { "_csrf" => token }
      expect(last_response).to be_redirect
      expect(last_response.location).to eq("/tools/files/_sserve/login")

      get "/tools/files/hello.txt"
      expect(last_response).to be_redirect
      expect(last_response.location).to include("/tools/files/_sserve/login")
    end

    it "prefixes the fallback when a return path leaves the origin" do
      config(password: "s3cret", prefix: "/files")
      get "/files/_sserve/login", { "return_to" => "https://evil.test/phish" }
      expect(last_response.body).to include('value="/"')

      token = csrf_from(last_response.body, "/files/_sserve/login")
      post "/files/_sserve/login", {
        "password" => "s3cret",
        "return_to" => "//evil.test",
        "_csrf" => token
      }
      expect(last_response.location).to eq("/files")
    end

    it "logs in when a previous process's session cookie is sent first" do
      config(password: "s3cret", prefix: "/files")
      previous = described_class.build(
        Sserve::Config.new(root: @root, password: "s3cret", prefix: "/files", session_secret: "a" * 64)
      )
      _status, previous_headers, _body = call_app(previous, "/files/_sserve/login")
      stale = live_session_pair(previous_headers)
      expect(stale).to start_with("sserve.sid.")

      get "/files/_sserve/login", {}, { "HTTP_COOKIE" => "sserve.session=leftover; #{stale}" }
      expect(last_response.status).to eq(200)
      expired = set_cookie_headers.join("\n")
      expect(expired).to include("sserve.session=; path=/; max-age=0")
      expect(expired).to include("sserve.session=; path=/files; max-age=0")
      expect(expired).to match(/sserve\.session=; path=\/; max-age=0; expires=[^;]+; secure/)
      expect(expired).to match(/sserve\.session=; path=\/files; max-age=0; expires=[^;]+; secure/)
      stale_name = stale.split("=", 2).first
      expect(expired).to include("#{stale_name}=; path=/files; max-age=0")
      expect(expired).to match(/#{Regexp.escape(stale_name)}=; path=\/files; max-age=0; expires=[^;]+; secure/)

      fresh = live_session_pair(last_response.headers)
      expect(fresh).to start_with("sserve.sid.")
      expect(fresh).not_to start_with("#{stale_name}=")
      token = csrf_from(last_response.body, "/files/_sserve/login")
      post "/files/_sserve/login", {
        "password" => "s3cret",
        "return_to" => "/hello.txt",
        "_csrf" => token
      }, { "HTTP_COOKIE" => "#{stale}; sserve.session=leftover; #{fresh}" }

      expect(last_response).to be_redirect
      expect(last_response.location).to eq("/files/hello.txt")
      signed_in = live_session_pair(last_response.headers)
      expect(set_cookie_headers.join("\n")).not_to include("#{signed_in.split("=", 2).first}=;")

      get "/files/hello.txt", {}, { "HTTP_COOKIE" => "#{stale}; sserve.session=leftover; #{signed_in}" }
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("hi")
    end

    it "prefixes the logout form on a generated error page" do
      Dir.mkdir(File.join(@root, "empty"))
      config(password: "s3cret", prefix: "/files", listings: false)
      get "/files/_sserve/login"
      token = csrf_from(last_response.body, "/files/_sserve/login")
      post "/files/_sserve/login", { "password" => "s3cret", "return_to" => "/", "_csrf" => token }

      get "/files/empty/"
      expect(last_response.status).to eq(403)
      expect(last_response.body).to include('action="/files/_sserve/logout"')
    end
  end
end
