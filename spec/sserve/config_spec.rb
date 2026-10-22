# frozen_string_literal: true

require "tmpdir"

RSpec.describe Sserve::Config do
  def write_root
    Dir.mktmpdir("sserve-config")
  end

  it "accepts a directory and applies defaults" do
    root = write_root
    config = described_class.new(root: root)

    expect(config.root).to eq(File.realpath(root))
    expect(config.host).to eq("127.0.0.1")
    expect(config.port).to eq(8080)
    expect(config.index).to eq("index.html")
    expect(config.password).to be_nil
    expect(config.listings).to be(false)
    expect(config.prefix).to eq("")
    expect(config.auth_required?).to be(false)
    expect(config.session_secret.bytesize).to be >= 64
  ensure
    FileUtils.remove_entry(root) if root
  end

  it "keeps a password and enables auth" do
    root = write_root
    config = described_class.new(root: root, password: "secret")

    expect(config.password).to eq("secret")
    expect(config.auth_required?).to be(true)
  ensure
    FileUtils.remove_entry(root) if root
  end

  it "treats a blank password as no auth" do
    root = write_root
    config = described_class.new(root: root, password: "")

    expect(config.auth_required?).to be(false)
  ensure
    FileUtils.remove_entry(root) if root
  end

  it "rejects a missing directory" do
    expect { described_class.new(root: "/tmp/sserve-missing-#{Process.pid}") }
      .to raise_error(described_class::Error, /does not exist/)
  end

  it "rejects a file used as the root" do
    Dir.mktmpdir("sserve-config") do |dir|
      file = File.join(dir, "file.txt")
      File.write(file, "x")

      expect { described_class.new(root: file) }
        .to raise_error(described_class::Error, /not a directory/)
    end
  end

  it "rejects an out-of-range port" do
    root = write_root
    expect { described_class.new(root: root, port: 0) }
      .to raise_error(described_class::Error, /port/)
    expect { described_class.new(root: root, port: "nope") }
      .to raise_error(described_class::Error, /port/)
  ensure
    FileUtils.remove_entry(root) if root
  end

  it "rejects an index name that is not a single segment" do
    root = write_root
    expect { described_class.new(root: root, index: "../index.html") }
      .to raise_error(described_class::Error, /index/)
    expect { described_class.new(root: root, index: "nested/index.html") }
      .to raise_error(described_class::Error, /index/)
  ensure
    FileUtils.remove_entry(root) if root
  end

  it "accepts a mount prefix and drops a trailing slash" do
    root = write_root
    expect(described_class.new(root: root, prefix: "/files").prefix).to eq("/files")
    expect(described_class.new(root: root, prefix: "/tools/files/").prefix).to eq("/tools/files")
    expect(described_class.new(root: root, prefix: "/").prefix).to eq("")
  ensure
    FileUtils.remove_entry(root) if root
  end

  it "rejects a prefix that is not a plain absolute path" do
    root = write_root
    ["files", "//files", "/../files", "/files/../secret", "/files//docs", "/files/./docs", "/files?x=1", "https://evil.test/files"].each do |prefix|
      expect { described_class.new(root: root, prefix: prefix) }
        .to raise_error(described_class::Error, /prefix/)
    end
  ensure
    FileUtils.remove_entry(root) if root
  end

  it "knows when the bind address is not loopback" do
    root = write_root
    expect(described_class.new(root: root, host: "127.0.0.1").public_bind?).to be(false)
    expect(described_class.new(root: root, host: "0.0.0.0").public_bind?).to be(true)
  ensure
    FileUtils.remove_entry(root) if root
  end
end
