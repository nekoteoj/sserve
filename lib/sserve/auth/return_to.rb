# frozen_string_literal: true

module Sserve
  module Auth
    # Keeps the post-login redirect inside this server. Anything that could
    # leave the origin, including scheme-relative URLs, falls back to "/".
    module ReturnTo
      module_function

      def sanitize(value)
        text = value.to_s
        return "/" if text.empty?
        return "/" unless text.start_with?("/")
        return "/" if text.start_with?("//", "/\\")
        return "/" if text.include?("\\") || text.include?("://")

        text
      end
    end
  end
end
