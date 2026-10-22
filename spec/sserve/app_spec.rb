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
    config

    head "/hello.txt"
    expect(last_response.status).to eq(200)

    post "/hello.txt"
    expect(last_response.status).to eq(405)
    expect(last_response.headers["allow"]).to eq("GET, HEAD")
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
end
