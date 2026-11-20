# frozen_string_literal: true

require "securerandom"

module Lain
  module Confine
    # What a masked file reads as inside a sandbox: an empty file, or, for a
    # Rails key, a decoy pair. A Rails app reads its credentials at boot, so
    # an unreadable or empty pair stops every `bin/rails` command, while a
    # random key and `{}` sealed under it boot with empty credentials. A real
    # credentials file under a decoy key fails to decrypt, so a masked key
    # puts the decoy over its credentials too.
    #
    # The pair is built once per process, on first use, so a guard can tell
    # each decoy's bytes from what any later call staged.
    class Decoys
      EMPTY = ""
      KEY = %r{/config/(?:master|credentials/[^/]+)\.key\z}
      CREDENTIALS = %r{/config/(?:credentials|credentials/[^/]+)\.yml\.enc\z}
      PAIR_LOCK = Mutex.new
      private_constant :PAIR_LOCK

      # @return [Array(String, String)] the decoy key and `{}` sealed under it, frozen
      def self.pair
        PAIR_LOCK.synchronize do
          @pair ||= SecureRandom.hex(16).then do |key|
            [key, Sensitivity::RailsCredentials.seal("{}", key:)].map(&:freeze).freeze
          end
        end
      end

      # @param mask [String] absolute
      # @param masks [Array<String>] every path the call masks
      # @return [String] frozen
      def bytes_for(mask, masks:)
        key, credentials = self.class.pair
        return key if KEY.match?(mask)
        return credentials if CREDENTIALS.match?(mask) && masks.include?(key_of(mask))

        EMPTY
      end

      # @param masks [Array<String>]
      # @return [Array<String>] the credentials beside each masked key, present and not masked themselves
      def partners(masks)
        masks.grep(KEY).map { credentials_of(_1) }.select { File.file?(_1) } - masks
      end

      private

      def key_of(credentials)
        credentials.sub(%r{/config/credentials\.yml\.enc\z}, "/config/master.key").sub(/\.yml\.enc\z/, ".key")
      end

      def credentials_of(key)
        key.sub(%r{/config/master\.key\z}, "/config/credentials.yml.enc").sub(/\.key\z/, ".yml.enc")
      end
    end
  end
end
