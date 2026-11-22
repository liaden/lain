# frozen_string_literal: true

module Lain
  module Confine
    # Reads just enough of an executable to say whether it runs on its own file, with no loader or library the
    # sandbox would also have to show. Only a 64-bit ELF is read, and its program headers only where the
    # kernel itself would accept them; anything else counts as not static.
    module Elf
      MAGIC = "\x7FELF".b.freeze
      HEADER_BYTES = 64
      ENTRY_BYTES = 56
      PT_INTERP = 3
      ORDERS = { 1 => "<", 2 => ">" }.freeze

      # The open is nonblocking and only a regular file is read, since a FIFO swapped in after the resolve
      # would wait on its writer.
      #
      # @param path [String] a resolved program
      # @return [Boolean] whether it is an ELF64 that names no loader
      def self.static?(path)
        File.open(path, File::RDONLY | File::NONBLOCK) do |io|
          io.binmode
          header = io.stat.file? ? io.read(HEADER_BYTES).to_s : ""
          order = ORDERS[header.getbyte(5)]
          elf64?(header) && !order.nil? && !interpreted?(table(io, header, order), order)
        end
      rescue SystemCallError, IOError
        false
      end

      def self.elf64?(header) = header.bytesize == HEADER_BYTES && header.start_with?(MAGIC) && header.getbyte(4) == 2

      # @return [String, nil] the program headers, or nil where they are not where and how the kernel reads them
      def self.table(io, header, order)
        offset = header.unpack1("Q#{order}", offset: 32)
        size, count = header.unpack("S#{order}S#{order}", offset: 54)
        bytes = count * ENTRY_BYTES
        return unless size == ENTRY_BYTES && count.positive? && offset + bytes <= io.size

        io.seek(offset)
        io.read(bytes)
      end

      def self.interpreted?(table, order)
        return true if table.nil?

        0.step(table.bytesize - 1, ENTRY_BYTES).any? { table.unpack1("L#{order}", offset: _1) == PT_INTERP }
      end
      private_class_method :elf64?, :table, :interpreted?
    end
  end
end
