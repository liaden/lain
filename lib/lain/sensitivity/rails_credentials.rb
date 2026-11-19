# frozen_string_literal: true

require "date"
require "openssl"
require "yaml"

module Lain
  class Sensitivity
    # The values a Rails app keeps in its encrypted credentials, which a
    # program that decrypts them can print and no file read shows: the file on
    # disk is ciphertext. The keys are read the way Rails reads them (a key
    # file beside the credentials, else `RAILS_MASTER_KEY`), and the values are
    # held in memory only.
    #
    # Decrypted here rather than by ActiveSupport, whose encrypted
    # configuration loads the JSON core extensions and would change the shape
    # of every later `to_json` in the process. The plaintext is a marshalled
    # String, read by {.unmarshal} and never by `Marshal.load`.
    class RailsCredentials
      CONFIG = "config"
      # Names Rails itself puts in the credentials as plain structure, and which
      # stay legible in output. Deliberately not every plain word: a password can
      # be one, and a missed secret costs more than a masked word.
      STRUCTURAL = %w[development test production staging].freeze
      NUMERIC_OR_BOOLEAN = /\A(?:true|false|nil|null|-?\d+(?:\.\d+)?)\z/i
      MASTER_KEY_ENV = "RAILS_MASTER_KEY"
      CIPHER = "aes-128-gcm"
      # OpenSSL accepts a truncated tag, which would weaken the authentication.
      IV_BYTES = 12
      TAG_BYTES = 16
      # What Marshal appends to a UTF-8 or US-ASCII String after its bytes.
      ENCODING_TAIL = ["\x06:\x06ET".b, "\x06:\x06EF".b].freeze

      # The text inside a marshalled String, for exactly that shape and nothing else.
      #
      # @param bytes [String] binary
      # @return [String]
      # @raise [ArgumentError] for any other shape
      def self.unmarshal(bytes)
        bytes = bytes.b
        body = bytes.delete_prefix("\x04\b".b)
        wrapped = body.start_with?("I\"".b)
        raise ArgumentError, "not a marshalled string" unless body != bytes && (wrapped || body.start_with?("\"".b))

        length, offset = length_at(body, wrapped ? 2 : 1)
        text = body.byteslice(offset, length)
        tail = body.byteslice((offset + length)..)
        raise ArgumentError, "not a marshalled string" unless text&.bytesize == length && tail_ok?(tail, wrapped)

        text.force_encoding(Encoding::UTF_8)
      end

      def self.tail_ok?(tail, wrapped) = wrapped ? ENCODING_TAIL.include?(tail) : tail.empty?

      # Marshal's small-integer encoding, non-negative values only.
      def self.length_at(body, at)
        first = body.getbyte(at) or raise ArgumentError, "truncated"
        return [first - 5, at + 1] if (6..127).cover?(first)
        return [0, at + 1] if first.zero?
        raise ArgumentError, "unsupported length" unless (1..4).cover?(first)

        [body.byteslice(at + 1, first).unpack("C*").each_with_index.sum { |byte, i| byte << (8 * i) }, at + 1 + first]
      end
      private_class_method :tail_ok?, :length_at

      # @param root [String] the project root
      # @param report [#call] receives a reason, naming a file and never a key
      def initialize(root:, report: ->(_reason) {})
        @root = root
        @report = report
        @memo = nil
      end

      # @return [Array<String>] frozen binary strings, each at least {Literals::FLOOR} bytes
      def leaves = memoized

      private

      # Re-read only when a credentials file, a key file or the env key moved. The ctime is in the
      # stamp because a rotation can restore the mtime but never the ctime.
      def memoized
        signature = [files.flatten.map { stamp(_1) }, master_key]
        return @memo.last if @memo&.first == signature

        @memo = [signature, read]
        @memo.last
      end

      def stamp(path)
        stat = File.stat(path)
        [path, stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec, stat.size]
      rescue SystemCallError
        [path, nil]
      end

      def read
        files.flat_map { |file| leaves_of(file) }.select { known?(_1) }.map { _1.b.freeze }.uniq.freeze
      end

      def files
        main = File.join(@root, CONFIG, "credentials.yml.enc")
        each_env = Dir.glob(File.join(@root, CONFIG, "credentials", "*.yml.enc"))
        [[main, File.join(@root, CONFIG, "master.key")]] +
          each_env.map { [_1, "#{_1.delete_suffix(".yml.enc")}.key"] }
      end

      def leaves_of((path, key_path))
        return [] unless File.file?(path) && keyed?(key_path)

        strings(decrypt(path, key_path))
      rescue StandardError
        report(path)
        []
      end

      def keyed?(key_path) = File.file?(key_path) || !master_key.to_s.empty?

      # The env key wins in Rails, so a stale one from another app would hide
      # this project's own key file; the file is tried after it.
      def decrypt(path, key_path)
        keys(key_path).each do |key|
          return YAML.safe_load(plaintext(path, key), permitted_classes: [Symbol, Date, Time], aliases: true)
        rescue StandardError
          next
        end
        raise ArgumentError, "undecryptable"
      end

      def keys(key_path)
        [master_key, (File.binread(key_path).strip if File.file?(key_path))].reject { _1.to_s.empty? }
      end

      def master_key = ENV.fetch(MASTER_KEY_ENV, nil)

      def plaintext(path, key)
        data, iv, tag = File.binread(path).strip.split("--", 3).map { _1.unpack1("m") }
        cipher = gcm(key, iv, tag)
        self.class.unmarshal(cipher.update(data) + cipher.final)
      end

      def gcm(key, nonce, tag)
        raise ArgumentError, "bad iv or tag length" unless nonce&.bytesize == IV_BYTES && tag&.bytesize == TAG_BYTES

        cipher = OpenSSL::Cipher.new(CIPHER).decrypt
        cipher.key = [key].pack("H*")
        cipher.iv = nonce
        cipher.auth_tag = tag
        cipher.auth_data = ""
        cipher
      end

      def strings(node)
        case node
        when Hash then node.values.flat_map { strings(_1) }
        when Array then node.flat_map { strings(_1) }
        when String then [node]
        when Symbol then [node.to_s]
        else []
        end
      end

      def known?(value)
        value.bytesize >= Literals::FLOOR && !STRUCTURAL.include?(value) && !NUMERIC_OR_BOOLEAN.match?(value)
      end

      def report(path)
        name = path.delete_prefix("#{@root}/")
        @report.call("#{name} did not decrypt")
      end
    end
  end
end
