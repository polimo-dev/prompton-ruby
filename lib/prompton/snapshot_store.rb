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
                       :prompt_meta,
                       keyword_init: true) do
      def stale?
        source != "remote" || !stale_since.nil?
      end
    end

    PromptEntry = Struct.new(:data, :etag, :last_modified, :source, :fetched_at, :stale_since, :body,
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
      @prompt_meta = {}
      @prompt_entries = {}
    end

    # The current entry, or nil when no tier has produced a document yet.
    def entry
      @mutex.synchronize { @entry }
    end

    # The current document, or nil.
    def data
      entry&.data
    end

    def prompt_entry(prompt_key)
      key = prompt_key.to_s
      @mutex.synchronize do
        @prompt_entries[key]
      end
    end

    # Loads the disk cache, then the bundle. Returns the entry it installed, or nil.
    def load_local
      candidates = [[@config.disk_cache_path, "disk"], [@config.bundle_path, "bundle"]]
      candidates.each do |path, source|
        next if path.nil?

        loaded = read_file(path, source)
        next if loaded.nil?

        @mutex.synchronize do
          @entry = loaded
          @prompt_meta = loaded.prompt_meta || local_prompt_meta(loaded.data, source, loaded)
          rebuild_prompt_entries(loaded.data, @prompt_meta, source, loaded)
        end
        @config.logger.info("[PromptOn] loaded snapshot from #{source} (#{path}) etag=#{loaded.etag}")
        return loaded
      end
      nil
    end

    # Installs a document fetched from the server and mirrors it to the disk cache.
    def install_remote(body, etag: nil, last_modified: nil, persist: true)
      data = UseCaseDocument.parse(body)
      guard!(data)
      now = Time.now
      entry = Entry.new(data: data, etag: etag, last_modified: last_modified, source: "remote",
                        fetched_at: now, stale_since: nil, body: body, prompt_meta: {})
      @mutex.synchronize do
        @entry = entry
        @prompt_meta = local_prompt_meta(data, "remote", entry)
        entry.prompt_meta = @prompt_meta.dup
        rebuild_prompt_entries(data, @prompt_meta, "remote", entry)
      end
      write_disk(body, entry) if persist && @config.disk_cache_path
      entry
    end

    def install_prompt_remote(prompt_key, body, etag: nil, last_modified: nil, persist: true, deadline_expired: nil)
      key = prompt_key.to_s
      data = UseCaseDocument.parse(body)
      guard!(data)
      guard_prompt!(data, key)
      raise TransportError, "config fetch exceeded deadline before cache install" if deadline_expired&.call

      now = Time.now
      entry = nil
      @mutex.synchronize do
        merged = merge_documents(@entry&.data, data, key)
        merged_body = JSON.generate(document_to_h(merged))
        @prompt_meta[key] = { etag: etag, last_modified: last_modified, source: "remote",
                              fetched_at: now, stale_since: nil }
        @prompt_entries[key] =
          PromptEntry.new(data: data, etag: etag, last_modified: last_modified, source: "remote",
                          fetched_at: now, stale_since: nil, body: body)
        entry = Entry.new(data: merged, etag: etag, last_modified: last_modified, source: "remote",
                          fetched_at: now, stale_since: nil, body: merged_body,
                          prompt_meta: @prompt_meta.dup)
        @entry = entry
      end
      write_disk(entry.body, entry) if persist && @config.disk_cache_path
      entry
    end

    # Installs a document the caller already holds — test mode, or a manual override.
    def install_document(document, source: "manual", etag: "manual")
      body = document.is_a?(String) ? document : JSON.generate(document)
      data = UseCaseDocument.parse(body)
      entry = Entry.new(data: data, etag: etag, last_modified: nil, source: source,
                        fetched_at: Time.now, stale_since: nil, body: body, prompt_meta: {})
      @mutex.synchronize do
        @entry = entry
        @prompt_meta = local_prompt_meta(data, source, entry)
        entry.prompt_meta = @prompt_meta.dup
        rebuild_prompt_entries(data, @prompt_meta, source, entry)
      end
      entry
    end

    # The server answered 304: the document we hold is current after all.
    def confirm_current(prompt_key = nil, etag: nil, last_modified: nil)
      @mutex.synchronize do
        next if @entry.nil?

        if prompt_key
          key = prompt_key.to_s
          meta = @prompt_meta[key] || {}
          @prompt_meta[key] = meta.merge(etag: etag || meta[:etag] || @entry.etag,
                                         last_modified: last_modified || meta[:last_modified] || @entry.last_modified,
                                         source: "remote", fetched_at: Time.now, stale_since: nil)
          if @prompt_entries[key]
            @prompt_entries[key] = @prompt_entries[key].class.new(**@prompt_entries[key].to_h,
                                                                  etag: @prompt_meta[key][:etag],
                                                                  last_modified: @prompt_meta[key][:last_modified],
                                                                  source: "remote",
                                                                  fetched_at: @prompt_meta[key][:fetched_at],
                                                                  stale_since: nil)
          end
        else
          @prompt_meta = local_prompt_meta(@entry.data, "remote", @entry)
          rebuild_prompt_entries(@entry.data, @prompt_meta, "remote", @entry)
        end
        @entry = @entry.class.new(
          **@entry.to_h, source: "remote", stale_since: nil, prompt_meta: @prompt_meta.dup
        )
      end
    end

    # A refresh failed. The document stays in place and starts reporting itself as stale.
    def mark_stale(prompt_key = nil)
      @mutex.synchronize do
        next if @entry.nil?

        stale_at = Time.now
        if prompt_key
          key = prompt_key.to_s
          meta = @prompt_meta[key]
          @prompt_meta[key] = meta.merge(stale_since: meta[:stale_since] || stale_at) if meta
          if meta && @prompt_entries[key]
            @prompt_entries[key] = @prompt_entries[key].class.new(**@prompt_entries[key].to_h,
                                                                  stale_since: @prompt_meta[key][:stale_since])
          end
        elsif @entry.stale_since
          next
        end
        @entry = @entry.class.new(
          **@entry.to_h, stale_since: @entry.stale_since || stale_at, prompt_meta: @prompt_meta.dup
        )
      end
    end

    def clear
      @mutex.synchronize do
        @entry = nil
        @prompt_meta = {}
        @prompt_entries = {}
      end
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

    def prompt_info(prompt_key)
      current = prompt_entry(prompt_key)
      if current.nil?
        return { source: "none", etag: nil, last_modified: nil, fetched_at: nil, stale: true,
                 age_seconds: nil, environment: nil, project: nil }
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
      entry = Entry.new(data: data, etag: meta["etag"], last_modified: meta["last_modified"], source: source,
                        fetched_at: parse_time(meta["fetched_at"]) || Time.now, stale_since: nil,
                        body: body, prompt_meta: {})
      entry.prompt_meta = prompt_meta_from_sidecar(meta, data, source, entry)
      entry
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
        "fetched_at" => entry.fetched_at.utc.iso8601(6), "sdk" => "#{SDK_NAME}/#{VERSION}",
        "prompts" => (entry.prompt_meta || {}).to_h do |key, meta|
          prompt_entry = @prompt_entries[key]
          [key, { "etag" => meta[:etag], "last_modified" => meta[:last_modified],
                  "source" => meta[:source], "fetched_at" => meta[:fetched_at]&.utc&.iso8601(6),
                  "body" => json_body_string(prompt_entry&.body) }.compact]
        end }
    end

    def guard_prompt!(data, key)
      raise InvalidUseCaseDocumentError, "prompt document did not include #{key.inspect}" unless data.use_case(key)
    end

    def json_body_string(body)
      return nil if body.nil?

      body.to_s.dup.force_encoding(Encoding::UTF_8)
    end

    def rebuild_prompt_entries(data, prompt_meta, source, entry)
      @prompt_entries = data.use_case_keys.to_h do |key|
        meta = prompt_meta[key] || {}
        prompt_data = isolate_document(data, key, meta[:body])
        [key, PromptEntry.new(data: prompt_data, etag: meta[:etag] || entry.etag,
                              last_modified: meta[:last_modified] || entry.last_modified,
                              source: meta[:source] || source,
                              fetched_at: meta[:fetched_at] || entry.fetched_at,
                              stale_since: meta[:stale_since] || entry.stale_since,
                              body: meta[:body] || JSON.generate(document_to_h(prompt_data)))]
      end
    end

    def isolate_document(data, key, body = nil)
      document = body ? UseCaseDocument.parse(body) : merge_documents(nil, data, key)
      guard!(document)
      guard_prompt!(document, key)
      document
    end

    def merge_documents(existing, incoming, key)
      merged = existing ? document_to_h(existing) : base_document(incoming)
      incoming_hash = document_to_h(incoming)
      %w[use_cases prompts deployments].each do |collection|
        next unless incoming_hash[collection].is_a?(Hash)

        merged[collection] ||= {}
        merged[collection][key] = incoming_hash[collection][key] if incoming_hash[collection].key?(key)
      end
      %w[prompt_versions models].each do |collection|
        merged[collection] ||= {}
        merged[collection].merge!(incoming_hash[collection] || {})
      end
      UseCaseDocument.from_hash(merged)
    end

    def base_document(data)
      { "schema_version" => data.schema_version, "project" => data.project,
        "environment" => data.environment, "use_cases" => {}, "deployments" => {},
        "prompt_versions" => {}, "models" => {} }
    end

    def document_to_h(data)
      {
        "schema_version" => data.schema_version,
        "project" => data.project,
        "environment" => data.environment,
        "use_cases" => data.use_cases.transform_values do |use_case|
          { "id" => use_case.id, "kind" => use_case.kind,
            "input_schema" => use_case.input_schema, "default_params" => use_case.default_params,
            "payload_policy" => payload_policy_to_h(use_case.payload_policy) }.compact
        end,
        "deployments" => data.deployments.transform_values do |deployment|
          { "id" => deployment.id, "use_case_key" => deployment.use_case_key,
            "revision" => deployment.revision, "model_id" => deployment.model_id,
            "params" => deployment.params, "provider_options" => deployment.provider_options,
            "prompt_pins" => deployment.prompt_pins, "api" => deployment.api,
            "request_path" => deployment.request_path }.compact
        end,
        "prompt_versions" => data.prompt_versions.transform_values do |version|
          { "id" => version.id, "prompt_id" => version.prompt_id, "number" => version.number,
            "engine" => version.engine, "messages" => version.messages,
            "text_template" => version.text_template, "kind" => version.kind,
            "decision" => version.decision, "tools" => version.tools }.compact
        end,
        "models" => data.models.transform_values do |model|
          { "id" => model.id, "provider" => model.provider, "model_id" => model.model_id,
            "display_name" => model.display_name, "metadata" => model.metadata,
            "provider_options" => model.provider_options, "capabilities" => model.capabilities,
            "pricing" => model.pricing, "context_length" => model.context_length,
            "status" => model.status }.compact
        end
      }
    end

    def payload_policy_to_h(policy)
      return nil unless policy

      { "mode" => policy[:mode], "sample_rate" => policy[:sample_rate],
        "max_bytes" => policy[:max_bytes], "retention_days" => policy[:retention_days],
        "encrypt" => policy[:encrypt] }.compact
    end

    def local_prompt_meta(data, source, entry)
      data.use_case_keys.to_h do |key|
        [key, { etag: entry.etag, last_modified: entry.last_modified, source: source,
                fetched_at: entry.fetched_at, stale_since: source == "remote" ? nil : Time.now }]
      end
    end

    def prompt_meta_from_sidecar(meta, data, source, entry)
      raw = meta["prompts"]
      return local_prompt_meta(data, source, entry) unless raw.is_a?(Hash)

      data.use_case_keys.to_h do |key|
        prompt = raw[key] || {}
        body = prompt["body"].is_a?(String) ? prompt["body"] : nil
        [key, { etag: prompt["etag"] || entry.etag,
                last_modified: prompt["last_modified"] || entry.last_modified,
                source: source,
                fetched_at: parse_time(prompt["fetched_at"]) || entry.fetched_at,
                stale_since: source == "remote" ? nil : Time.now,
                body: body }]
      end
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
