# frozen_string_literal: true

module Sserve
  module Files
    # Resolves a request path and refuses anything that is not a real path
    # inside the serve root. Symlinks are followed, then checked again.
    class SafePath
      def initialize(root)
        @root = File.realpath(root)
      end

      attr_reader :root

      def resolve(request_path)
        relative = relative_path(request_path)
        return nil if relative.nil?

        candidate = File.join(@root, relative)
        return nil unless File.exist?(candidate)

        real = File.realpath(candidate)
        return nil unless inside?(real)

        real
      rescue SystemCallError
        nil
      end

      def inside?(path)
        path == @root || path.start_with?("#{@root}#{File::SEPARATOR}")
      end

      private

      def relative_path(request_path)
        text = request_path.to_s
        return nil if text.include?("\0")

        text = text.delete_prefix("/")
        return "" if text.empty?

        segments = text.split("/").reject(&:empty?)
        return nil if segments.any? { |segment| segment == "." || segment == ".." }

        File.join(*segments)
      end
    end
  end
end
