# frozen_string_literal: true

require "rack/utils"
require "time"

module Sserve
  module Files
    # Decides what a path is. Returns a result; the HTTP layer turns that
    # into a response.
    class Catalog
      Result = Data.define(:type, :path, :entries) do
        def self.file(path) = new(type: :file, path: path, entries: nil)
        def self.listing(path, entries) = new(type: :listing, path: path, entries: entries)
        def self.not_found = new(type: :not_found, path: nil, entries: nil)
        def self.forbidden = new(type: :forbidden, path: nil, entries: nil)
      end

      def initialize(config)
        @config = config
        @paths = SafePath.new(config.root)
      end

      def lookup(request_path)
        real = @paths.resolve(request_path)
        return Result.not_found unless real
        return Result.not_found if hidden_request?(request_path) && !index_file?(real)

        if File.directory?(real)
          index = File.join(real, @config.index)
          if servable_file?(index)
            return Result.file(File.realpath(index))
          end

          return Result.forbidden unless @config.listings

          Result.listing(real, list(real, request_path))
        elsif servable_file?(real)
          Result.file(real)
        else
          Result.not_found
        end
      end

      private

      def servable_file?(path)
        File.file?(path) && @paths.inside?(File.realpath(path))
      rescue SystemCallError
        false
      end

      def index_file?(real)
        File.basename(real) == @config.index
      end

      def hidden_request?(request_path)
        request_path.to_s.split("/").any? { |segment| segment.start_with?(".") && segment != "." && segment != ".." }
      end

      def list(directory, request_path)
        entries = Dir.children(directory).filter_map do |name|
          next if name.start_with?(".")

          child = File.join(directory, name)
          next unless @paths.inside?(File.realpath(child))

          stat = File.stat(child)
          directory_entry = stat.directory?
          Entry.new(
            name: name,
            directory: directory_entry,
            size: directory_entry ? nil : stat.size,
            mtime: stat.mtime,
            href: href_for(request_path, name, directory_entry)
          )
        rescue SystemCallError
          nil
        end

        entries.sort_by { |entry| [entry.directory ? 0 : 1, entry.name.downcase] }
      end

      def href_for(request_path, name, directory_entry)
        base = request_path.to_s
        base = "/#{base}" unless base.start_with?("/")
        base = "#{base}/" unless base.end_with?("/")
        encoded = Rack::Utils.escape_path(name)
        suffix = directory_entry ? "/" : ""
        "#{base}#{encoded}#{suffix}"
      end
    end
  end
end
