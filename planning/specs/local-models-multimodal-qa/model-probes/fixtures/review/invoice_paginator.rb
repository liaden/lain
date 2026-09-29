# frozen_string_literal: true

module Shop
  # Splits an invoice's line items into fixed-size pages for the PDF renderer.
  # Every line item appears on exactly one page.
  class InvoicePaginator
    include Enumerable

    Page = Struct.new(:number, :items, :subtotal, keyword_init: true) do
      attr_writer :last

      def last? = @last == true
    end

    DEFAULT_PER_PAGE = 25

    def initialize(items, per_page: DEFAULT_PER_PAGE)
      raise ArgumentError, "per_page must be positive" unless per_page.positive?

      @items = items.freeze
      @per_page = per_page
    end

    # Ceiling division without floats.
    def page_count = (@items.size + @per_page - 1) / @per_page

    def each
      return enum_for(:each) { page_count } unless block_given?

      page_count.times { |index| yield build_page(index) }
    end

    def page(number)
      raise RangeError, "no page #{number}" unless number.between?(1, page_count)

      build_page(number - 1)
    end

    private

    def build_page(index)
      offset = index * @per_page
      slice = @items[offset..offset + @per_page] #BUG1
      Page.new(number: index + 1, items: slice, subtotal: subtotal_of(slice)).tap do |page|
        page.last = index == page_count - 1
      end
    end

    # Rational keeps cent arithmetic exact until the renderer formats it.
    def subtotal_of(slice)
      slice.sum(Rational(0)) { |item| Rational(item.fetch(:cents)) * item.fetch(:qty, 1) } / 100
    end
  end
end
