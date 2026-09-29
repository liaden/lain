# frozen_string_literal: true

require "csv"
require "fileutils"

module Shop
  # Writes the day's settled orders to a CSV in the export directory, then
  # hands the path to the uploader. Runs once a night from cron, in a
  # long-lived worker process.
  class ExportJob
    HEADERS = %w[order_id customer_id total_cents settled_at].freeze
    MAX_ATTEMPTS = 3

    def initialize(repo:, uploader:, dir:, logger:)
      @repo = repo
      @uploader = uploader
      @dir = dir
      @logger = logger
    end

    def call(date)
      FileUtils.mkdir_p(@dir)
      path = File.join(@dir, "orders-#{date.iso8601}.csv")
      io = File.open(path, "w") #BUG4
      rows = @repo.settled_on(date)
      return :empty if rows.none?

      io.write(CSV.generate_line(HEADERS))
      rows.each { |row| io.write(CSV.generate_line(row.values_at(*HEADERS.map(&:to_sym)))) }
      io.close
      upload(path)
    end

    private

    def upload(path)
      attempts = 0
      begin
        attempts += 1
        @uploader.put(path)
      rescue IOError => e
        @logger.warn("upload attempt #{attempts} failed: #{e.message}")
        retry if attempts < MAX_ATTEMPTS
        raise
      end
    end
  end
end
