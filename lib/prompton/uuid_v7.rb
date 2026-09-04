# frozen_string_literal: true

require "securerandom"

module PromptOn
  # RFC 9562 UUIDv7 generator with no external dependencies.
  #
  # A monitoring log id is the idempotency key the app issues up front, and the PromptOn column
  # is a UUIDv7 type: a v4 id is accepted by request validation and then fails on write, coming
  # back in `rejected` with "record could not be stored". Layout:
  # 48-bit unix milliseconds | 4-bit version (7) | 12-bit random | 2-bit variant (10) | 62-bit
  # random, rendered as lowercase hex with dashes.
  module UuidV7
    module_function

    # A new UUIDv7 string.
    def generate(unix_ms = nil)
      unix_ms ||= (Time.now.to_f * 1000).floor
      raise ArgumentError, "unix_ms must be a non-negative integer" if unix_ms.negative?

      bytes = SecureRandom.bytes(10).unpack("C*")
      hex = format("%012x", unix_ms & 0xFFFF_FFFF_FFFF)
      hex += format("7%03x", ((bytes[0] << 8) | bytes[1]) & 0x0FFF)
      hex += format("%04x", (((bytes[2] << 8) | bytes[3]) & 0x3FFF) | 0x8000)
      hex += bytes[4, 6].map { |b| format("%02x", b) }.join

      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    # The unix milliseconds encoded in a UUIDv7 string, or nil when it is not one.
    def timestamp_ms(uuid)
      return nil unless uuid.is_a?(String) && uuid =~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      (uuid[0, 8] + uuid[9, 4]).to_i(16)
    end
  end
end
