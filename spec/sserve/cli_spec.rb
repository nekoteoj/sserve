# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Sserve::CLI do
  def run(*argv, env: {}, server: double(start: nil))
    out = StringIO.new
    err = StringIO.new
    code = described_class.start(argv, env: env, out: out, err: err, server: server)
    [code, out.string, err.string]
  end

  it "prints help and version without starting the server" do
    server = double(start: nil)

    code, out, = run("--help", server: server)
    expect(code).to eq(0)
    expect(out).to include("Usage: sserve")
    expect(server).not_to have_received(:start)

    code, out, = run("--version", server: server)
    expect(code).to eq(0)
    expect(out).to eq("sserve #{Sserve::VERSION}\n")
  end

  it "builds config from flags and a positional directory" do
    Dir.mktmpdir("sserve-cli") do |dir|
      started = nil
      server = double(start: nil)
      allow(server).to receive(:start) { |config| started = config }

      code, = run(dir, "--port", "9090", "--bind", "0.0.0.0", "--index", "home.html",
        "--password", "s3cret", "--listings", server: server)

      expect(code).to eq(0)
      expect(started.root).to eq(File.realpath(dir))
      expect(started.port).to eq(9090)
      expect(started.host).to eq("0.0.0.0")
      expect(started.index).to eq("home.html")
      expect(started.password).to eq("s3cret")
      expect(started.listings).to be(true)
    end
  end

  it "reads the password from the environment" do
    Dir.mktmpdir("sserve-cli") do |dir|
      started = nil
      server = double(start: nil)
      allow(server).to receive(:start) { |config| started = config }

      code, = run("--directory", dir, "--password-env", "SSERVE_PASSWORD",
        env: {"SSERVE_PASSWORD" => "from-env"}, server: server)

      expect(code).to eq(0)
      expect(started.password).to eq("from-env")
    end
  end

  it "exits non-zero for invalid input and does not start the server" do
    server = double(start: nil)

    code, _, err = run("--port", "nope", server: server)
    expect(code).to eq(1)
    expect(err).to include("invalid argument")
    expect(server).not_to have_received(:start)

    code, _, err = run("--directory", "/tmp/sserve-missing-#{Process.pid}", server: server)
    expect(code).to eq(1)
    expect(err).to include("does not exist")

    code, _, err = run("--password-env", "MISSING_SSERVE_PASSWORD", env: {}, server: server)
    expect(code).to eq(1)
    expect(err).to include("MISSING_SSERVE_PASSWORD")
  end

  it "accepts a prefix and prints it in the listen url" do
    Dir.mktmpdir("sserve-cli") do |dir|
      started = nil
      server = double(start: nil)
      allow(server).to receive(:start) { |config| started = config }

      code, _, err = run("--directory", dir, "--prefix", "/files/", server: server)

      expect(code).to eq(0)
      expect(started.prefix).to eq("/files")
      expect(err).to include("http://127.0.0.1:8080/files/")
    end
  end

  it "rejects a prefix that is not an absolute path" do
    Dir.mktmpdir("sserve-cli") do |dir|
      code, _, err = run("--directory", dir, "--prefix", "files", server: double(start: nil))

      expect(code).to eq(1)
      expect(err).to include("prefix")
    end
  end

  it "warns when binding a public address without a password" do
    Dir.mktmpdir("sserve-cli") do |dir|
      code, _, err = run("--directory", dir, "--bind", "0.0.0.0", server: double(start: nil))

      expect(code).to eq(0)
      expect(err).to include("without a password")
    end
  end
end
