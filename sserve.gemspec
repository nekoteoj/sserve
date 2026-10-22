# frozen_string_literal: true

require_relative "lib/sserve/version"

Gem::Specification.new do |spec|
  spec.name = "sserve"
  spec.version = Sserve::VERSION
  spec.authors = ["Pisit Wajanasara"]
  spec.email = ["compisit1234@gmail.com"]
  spec.summary = "Serve a directory over HTTP with optional password protection"
  spec.description = "A small CLI that serves a static directory with Roda on iodine, " \
                     "with an optional shared password and directory listings."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*", "exe/**/*", "LICENSE", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["sserve"]
  spec.require_paths = ["lib"]

  spec.add_dependency "erubi", "~> 1.13"
  spec.add_dependency "iodine", "~> 0.7.60"
  spec.add_dependency "rack", "~> 3.1"
  spec.add_dependency "roda", "~> 3.109"
  spec.add_dependency "tilt", "~> 2.4"

  spec.add_development_dependency "rack-test", "~> 2.2"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "rspec", "~> 3.13"

  spec.metadata["rubygems_mfa_required"] = "true"
end
