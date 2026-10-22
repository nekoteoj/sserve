# frozen_string_literal: true

RSpec.describe Sserve::Auth::ReturnTo do
  it "keeps a same-origin path" do
    expect(described_class.sanitize("/files/a?x=1")).to eq("/files/a?x=1")
  end

  it "falls back to the root for open redirects and empty values" do
    %w[//evil.test https://evil.test http://evil.test /\\evil \\evil].each do |value|
      expect(described_class.sanitize(value)).to eq("/")
    end

    expect(described_class.sanitize(nil)).to eq("/")
    expect(described_class.sanitize("")).to eq("/")
    expect(described_class.sanitize("files/a")).to eq("/")
  end
end
