# frozen_string_literal: true

require_relative "lib/prompton/version"

Gem::Specification.new do |spec|
  spec.name = "prompton-sdk"
  spec.version = PromptOn::VERSION
  spec.authors = ["Polimo"]
  spec.summary = "The official Ruby SDK for PromptOn use-case documents and monitoring logs."
  spec.description = <<~TEXT
    PromptOn holds one pin per use case and environment: a prompt version, one model and its
    params. This SDK fetches a use-case document of those pins, renders the pinned prompt with your
    variables, and batches monitoring logs back. Your app calls the provider itself, with its own
    key and its own HTTP client, so PromptOn is never in the request path and an outage costs you
    nothing but fresher config. No runtime dependencies.
  TEXT
  spec.homepage = "https://github.com/polimo-dev/prompton-ruby"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
end
