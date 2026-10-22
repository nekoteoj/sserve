# frozen_string_literal: true

require "rack/utils"
require "time"

module Sserve
  module Files
    # Decides what a path is. Returns a result; the HTTP layer turns that
    # into a response.
    class Catalog
      Result = Data.define(:type, :path, :entries, :directory_path) do
        def self.file(path, directory_path: nil)
          new(type: :file, path: path, entries: nil, directory_path: directory_path)
        end

        def self.listing(path, entries)
          new(type: :listing, path: path, entries: entries, directory_path: path)
        end

        def self.not_found
          new(type: :not_found, path: nil, entries: nil, directory_path: nil)
        end

        def self.forbidden(directory_path = nil)
          new(type: :forbidden, path: nil, entries: nil, directory_path: directory_path)
        end
      end

      def initialize(config)
        @config = config
        @paths = SafePath.new(config.root)
      end

      def lookup(request_path)
        real = @paths.resolve(request_path)
        return Result.not_found unless real
        return Result.not_found if hidden_request?(request_path)

        if File.directory?(real)
          index = File.join(real, @config.index)
          if servable_file?(index)
            return Result.file(File.realpath(index), directory_path: real)
          end

          return Result.forbidden(real) unless @config.listings

          Result.listing(real, list(real))
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

      def hidden_request?(request_path)
        request_path.to_s.split("/").any? { |segment| segment.start_with?(".") && segment != "." && segment != ".." }
      end

      def list(directory)
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
            href: href_for(directory, name, directory_entry)
          )
        rescue SystemCallError
          nil
        end

        entries.sort_by { |entry| [entry.directory ? 0 : 1, entry.name.downcase] }
      end

      def href_for(directory, name, directory_entry)
        encoded = Rack::Utils.escape_path(name)
        suffix = directory_entry ? "/" : ""
        "#{directory_url(directory)}#{encoded}#{suffix}"
      end

      # Canonical URL for a directory already accepted by SafePath. Built from
      # the real path so a request like //docs cannot emit a scheme-relative link.
      def directory_url(directory)
        return "/" if directory == @paths.root

        "/#{directory.delete_prefix("#{@paths.root}/")}/"
      end
    end
  end
end
