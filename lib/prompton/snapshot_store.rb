# frozen_string_literal: true

require "fileutils"
require "time"
require "json"
require "securerandom"
require_relative "errors"
require_relative "use_case_document"

module PromptOn
  # The three tiers a snapshot can come from: memory, one local file, and a file bundled into the
  # app. There is no fourth tier and no external service — no database, no Redis, nothing shared.
  # Instances never coordinate; each keeps its own copy, which ETag polling makes cheap.
  #
  # Load order on start is memory, then disk, then bundle, then remote. A document for another
  # environment or project is never used: the file records both and a mismatch is ignored, so a
  # staging process can never boot on a production pin. A corrupt or partial file is ignored too,
  # which is what makes a concurrent rename by another process on the same host harmless.
  class SnapshotStore
    # One loaded document plus where it came from.
    Entry = Struct.new(:data, :etag, :last_modified, :source, :fetched_at, :stale_since, :body,
                       keyword_init: true) do
      def stale?
        source != "remote" || !stale_since.nil?
      end
    end

    attr_reader :config

    def initialize(config)
      @config = config
      @mutex = Mutex.new
      @entry = nil
    end

    # The current entry, or nil when no tier has produced a document yet.
    def entry
      @mutex.synchronize { @entry }
    end

    # The current document, or nil.
    def data
      entry&.data
    end

    # Loads the disk cache, then the bundle. Returns the entry it installed, or nil.
    def load_local
      candidates = [[@config.disk_cache_path, "disk"], [@config.bundle_path, "bundle"]]
      candidates.each do |path, source|
        next if path.nil?

        loaded = read_file(path, source)
        next if loaded.nil?

        @mutex.synchronize { @entry = loaded }
        @config.logger.info("[PromptOn] loaded snapshot from #{source} (#{path}) etag=#{loaded.etag}")
        return loaded
      end
      nil
    end

    # Installs a document fetched from the server and mirrors it to the disk cache.
    def install_remote(body, etag: nil, last_modified: nil, persist: true)
      data = UseCaseDocument.parse(body)
      guard!(data)
      entry = Entry.new(data: data, etag: etag, last_modified: last_modified, source: "remote",
                        fetched_at: Time.now, stale_since: nil, body: body)
      @mutex.synchronize { @entry = entry }
      write_disk(body, entry) if persist && @config.disk_cache_path
      entry
    end

    # Installs a document the caller already holds — test mode, or a manual override.
    def install_document(document, source: "manual", etag: "manual")
      body = document.is_a?(String) ? document : JSON.generate(document)
      data = UseCaseDocument.parse(body)
      entry = Entry.new(data: data, etag: etag, last_modified: nil, source: source,
                        fetched_at: Time.now, stale_since: nil, body: body)
      @mutex.synchronize { @entry = entry }
      entry
    end

    # The server answered 304: the document we hold is current after all.
    def confirm_current
      @mutex.synchronize do
        next if @entry.nil?

        @entry = @entry.class.new(**@entry.to_h, source: "remote", stale_since: nil)
      end
    end

    # A refresh failed. The document stays in place and starts reporting itself as stale.
    def mark_stale
      @mutex.synchronize do
        next if @entry.nil? || @entry.stale_since

        @entry = @entry.class.new(**@entry.to_h, stale_since: Time.now)
      end
    end

    def clear
      @mutex.synchronize { @entry = nil }
    end

    # Writes the current document (and its sidecar) to +path+, for building a bundle to commit.
    def export(path)
      current = entry or raise NotReadyError

      write_file(path, current.body)
      write_file(meta_path(path), JSON.generate(meta_for(current)))
      path
    end

    def info
      current = entry
      if current.nil?
        return { source: "none", etag: nil, last_modified: nil, fetched_at: nil, stale: true,
                 age_seconds: nil }
      end

      { source: current.source, etag: current.etag, last_modified: current.last_modified,
        fetched_at: current.fetched_at, stale: current.stale?,
        age_seconds: (Time.now - current.fetched_at).round,
        environment: current.data.environment, project: current.data.project }
    end

    def meta_path(path)
      "#{path}.meta.json"
    end

    private

    def guard!(data)
      if data.environment && data.environment != @config.environment
        raise InvalidUseCaseDocumentError,
              "snapshot is for environment #{data.environment.inspect}, " \
              "this process reads #{@config.environment.inspect}"
      end
      return unless @config.project && data.project && data.project != @config.project

      raise InvalidUseCaseDocumentError,
            "snapshot is for project #{data.project.inspect}, this process reads #{@config.project.inspect}"
    end

    def read_file(path, source)
      body = File.read(path)
      data = UseCaseDocument.parse(body)
      guard!(data)
      meta = read_meta(path)
      Entry.new(data: data, etag: meta["etag"], last_modified: meta["last_modified"], source: source,
                fetched_at: parse_time(meta["fetched_at"]) || Time.now, stale_since: nil, body: body)
    rescue Errno::ENOENT
      nil
    rescue InvalidUseCaseDocumentError => e
      @config.logger.warn("[PromptOn] ignoring #{source} snapshot #{path}: #{e.message}")
      nil
    rescue SystemCallError, IOError => e
      @config.logger.warn("[PromptOn] could not read #{source} snapshot #{path}: #{e.message}")
      nil
    end

    def read_meta(path)
      parsed = JSON.parse(File.read(meta_path(path)))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def write_disk(body, entry)
      write_file(@config.disk_cache_path, body)
      write_file(meta_path(@config.disk_cache_path), JSON.generate(meta_for(entry)))
    rescue SystemCallError, IOError => e
      @config.logger.warn("[PromptOn] disk cache write failed (#{@config.disk_cache_path}): #{e.message}")
    end

    def meta_for(entry)
      { "etag" => entry.etag, "last_modified" => entry.last_modified,
        "environment" => entry.data.environment, "project" => entry.data.project,
        "fetched_at" => entry.fetched_at.utc.iso8601(6), "sdk" => "#{SDK_NAME}/#{VERSION}" }
    end

    # tmp file then rename, so a reader on the same host either sees the old file or the new one
    # and never a half-written document.
    def write_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      begin
        File.binwrite(tmp, content)
        File.rename(tmp, path)
      rescue StandardError
        FileUtils.rm_f(tmp)
        raise
      end
    end

    def parse_time(value)
      value && Time.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
