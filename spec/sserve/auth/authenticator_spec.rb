# frozen_string_literal: true

RSpec.describe Sserve::Auth::Authenticator do
  it "accepts only the configured password" do
    auth = described_class.new("correct horse")

    expect(auth.enabled?).to be(true)
    expect(auth.valid?("correct horse")).to be(true)
    expect(auth.valid?("wrong")).to be(false)
    expect(auth.valid?("")).to be(false)
    expect(auth.valid?(nil)).to be(false)
  end

  it "treats a missing password as open access" do
    auth = described_class.new(nil)

    expect(auth.enabled?).to be(false)
    expect(auth.valid?(nil)).to be(true)
    expect(auth.valid?("anything")).to be(true)
  end

  it "does not treat a longer string with the same prefix as a match" do
    auth = described_class.new("secret")

    expect(auth.valid?("secret-and-more")).to be(false)
    expect(auth.valid?("secre")).to be(false)
  end
end
