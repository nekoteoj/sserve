# frozen_string_literal: true

require "digest"
require "rack/utils"

module Sserve
  module Auth
    # Compares a submitted password with the configured shared secret.
    # Both sides are hashed first so Rack's constant-time compare does not
    # leak the secret's length.
    class Authenticator
      def initialize(password)
        @digest = password.nil? ? nil : Digest::SHA256.digest(password.to_s)
      end

      def enabled?
        !@digest.nil?
      end

      def valid?(given)
        return true unless enabled?
        return false unless given.is_a?(String)

        Rack::Utils.secure_compare(Digest::SHA256.digest(given), @digest)
      end
    end
  end
end
