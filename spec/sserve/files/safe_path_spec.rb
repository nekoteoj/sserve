# frozen_string_literal: true

require "tmpdir"

RSpec.describe Sserve::Files::SafePath do
  around do |example|
    Dir.mktmpdir("sserve-safe") do |dir|
      @root = dir
      @outside = Dir.mktmpdir("sserve-outside")
      example.run
    ensure
      FileUtils.remove_entry(@outside) if @outside && File.exist?(@outside)
    end
  end

  def paths
    described_class.new(@root)
  end

  it "resolves a file inside the root" do
    File.write(File.join(@root, "hello.txt"), "hi")

    expect(paths.resolve("/hello.txt")).to eq(File.realpath(File.join(@root, "hello.txt")))
    expect(paths.resolve("hello.txt")).to eq(File.realpath(File.join(@root, "hello.txt")))
  end

  it "resolves the root itself" do
    expect(paths.resolve("/")).to eq(File.realpath(@root))
    expect(paths.resolve("")).to eq(File.realpath(@root))
  end

  it "rejects parent segments, null bytes, and missing paths" do
    expect(paths.resolve("/../etc/passwd")).to be_nil
    expect(paths.resolve("/foo/../../etc/passwd")).to be_nil
    expect(paths.resolve("/hello\0.txt")).to be_nil
    expect(paths.resolve("/missing.txt")).to be_nil
  end

  it "rejects a symlink that leaves the root" do
    File.write(File.join(@outside, "secret.txt"), "nope")
    File.symlink(File.join(@outside, "secret.txt"), File.join(@root, "escape"))

    expect(paths.resolve("/escape")).to be_nil
  end

  it "allows a symlink whose target stays inside the root" do
    File.write(File.join(@root, "real.txt"), "yes")
    File.symlink(File.join(@root, "real.txt"), File.join(@root, "alias.txt"))

    expect(paths.resolve("/alias.txt")).to eq(File.realpath(File.join(@root, "real.txt")))
  end
end
