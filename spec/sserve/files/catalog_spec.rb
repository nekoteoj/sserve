# frozen_string_literal: true

require "tmpdir"

RSpec.describe Sserve::Files::Catalog do
  around do |example|
    Dir.mktmpdir("sserve-catalog") do |dir|
      @root = dir
      example.run
    end
  end

  def catalog(listings: false, index: "index.html", password: nil)
    config = Sserve::Config.new(root: @root, listings: listings, index: index, password: password)
    described_class.new(config)
  end

  it "serves an index file instead of a listing" do
    File.write(File.join(@root, "index.html"), "<p>home</p>")
    File.write(File.join(@root, "other.txt"), "x")

    result = catalog(listings: true).lookup("/")

    expect(result.type).to eq(:file)
    expect(result.path).to eq(File.realpath(File.join(@root, "index.html")))
  end

  it "lists a directory only when listings are enabled" do
    File.write(File.join(@root, "notes.txt"), "hello")
    Dir.mkdir(File.join(@root, "docs"))

    expect(catalog(listings: false).lookup("/").type).to eq(:forbidden)

    result = catalog(listings: true).lookup("/")
    expect(result.type).to eq(:listing)
    expect(result.entries.map(&:name)).to eq(%w[docs notes.txt])
    expect(result.entries.first.directory).to be(true)
    expect(result.entries.last.href).to eq("/notes.txt")
  end

  it "returns not found for a missing path" do
    expect(catalog.lookup("/missing.txt").type).to eq(:not_found)
  end

  it "hides dotfiles from listings and direct requests" do
    File.write(File.join(@root, ".env"), "SECRET")
    File.write(File.join(@root, "visible.txt"), "ok")

    listing = catalog(listings: true).lookup("/")
    expect(listing.entries.map(&:name)).to eq(["visible.txt"])
    expect(catalog.lookup("/.env").type).to eq(:not_found)
  end

  it "serves a normal file" do
    File.write(File.join(@root, "hello.txt"), "hi")

    result = catalog.lookup("/hello.txt")
    expect(result.type).to eq(:file)
    expect(File.read(result.path)).to eq("hi")
  end

  it "does not serve an index file inside a hidden directory" do
    Dir.mkdir(File.join(@root, ".hidden"))
    File.write(File.join(@root, ".hidden", "index.html"), "nope")

    expect(catalog.lookup("/.hidden/index.html").type).to eq(:not_found)
    expect(catalog.lookup("/.hidden/").type).to eq(:not_found)
  end

  it "builds listing links from the real directory, not the raw request path" do
    Dir.mkdir(File.join(@root, "docs"))
    File.write(File.join(@root, "docs", "note.txt"), "n")

    result = catalog(listings: true).lookup("//docs")

    expect(result.type).to eq(:listing)
    expect(result.entries.map(&:href)).to eq(["/docs/note.txt"])
  end

  it "does not follow a symlink out of the root" do
    outside = Dir.mktmpdir("sserve-catalog-out")
    File.write(File.join(outside, "secret.txt"), "nope")
    File.symlink(File.join(outside, "secret.txt"), File.join(@root, "escape"))

    expect(catalog.lookup("/escape").type).to eq(:not_found)
  ensure
    FileUtils.remove_entry(outside) if outside
  end
end
