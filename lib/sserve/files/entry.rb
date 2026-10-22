# frozen_string_literal: true

module Sserve
  module Files
    Entry = Data.define(:name, :directory, :size, :mtime, :href)
  end
end
