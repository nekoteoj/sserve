# frozen_string_literal: true

module Sserve
  # Boots iodine as a Rack server. Static files are not handed to iodine's
  # C file handler: that path never reaches Ruby, so it cannot enforce the
  # password, the index name, or the listing switch.
  class Server
    def self.start(config)
      require "iodine"
      require "rack/common_logger"

      app = Rack::CommonLogger.new(App.build(config), $stderr)
      Iodine.workers = 1
      Iodine.threads = 4
      Iodine.listen(service: :http, address: config.host, port: config.port.to_s, handler: app)
      Iodine.start
    end
  end
end
