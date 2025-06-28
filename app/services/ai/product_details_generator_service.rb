# frozen_string_literal: true

class Ai::ProductDetailsGeneratorService
  class MaxRetriesExceededError < StandardError; end

  PRODUCT_DETAILS_GENERATION_TIMEOUT_IN_SECONDS = 30
  RICH_CONTENT_PAGES_GENERATION_TIMEOUT_IN_SECONDS = 60
  COVER_IMAGE_GENERATION_TIMEOUT_IN_SECONDS = 120

  SUPPORTED_PRODUCT_NATIVE_TYPES = [
    Link::NATIVE_TYPE_DIGITAL,
    Link::NATIVE_TYPE_COURSE,
    Link::NATIVE_TYPE_EBOOK,
    Link::NATIVE_TYPE_MEMBERSHIP
  ].freeze

  def initialize(current_seller:)
    @current_seller = current_seller
  end

  # @param prompt [String] The user's prompt
  # @return [Hash] with the following keys:
  #   - name: [String] The product name
  #   - description: [String] The product description as an HTML string
  #   - summary: [String] The product summary
  #   - native_type: [String] The product native type
  #   - price: [Float] The product price in the current seller's currency
  #   - price_frequency_in_months: [Integer] The product price frequency in months (1, 3, 6, 12, 24)
  #   - duration_in_seconds: [Integer] The duration of the operation in seconds
  def generate_product_details(prompt:)
    result, duration = with_retries(operation: "Generate product details", context: prompt) do
      response = openai_client(PRODUCT_DETAILS_GENERATION_TIMEOUT_IN_SECONDS).chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: %Q{
                You are an expert digital product creator. Generate detailed product information based on the user's prompt.
                Return the following JSON format **only**:
                {
                  "name": "Product name as a string",
                  "description": "Product description as a safe HTML string with only <p>, <ul>, <ol>, <li>, <h2>, <h3>, <h4>, <strong>, and <em> tags",
                  "summary": "Short summary of the product",
                  "native_type": "Must be one of: #{SUPPORTED_PRODUCT_NATIVE_TYPES.join(", ")}",
                  "price": 4.99, // Price in #{current_seller.currency_type}
                  "price_frequency_in_months": 1 // Only include if native_type is 'membership' (1, 3, 6, 12, 24)
                }
              }.split("\n").map(&:strip).join("\n")
            },
            {
              role: "user",
              content: prompt
            }
          ],
          response_format: { type: "json_object" },
          temperature: 0.5
        }
      )

      content = response.dig("choices", 0, "message", "content")
      JSON.parse(content, symbolize_names: true)
    end

    result.merge(
      currency_code: current_seller.currency_type,
      duration_in_seconds: duration
    )
  end

  # @param product_name [String] The product name
  # @return [Hash] with the following keys:
  #   - blob: [ActiveStorage::Blob] The cover image
  #   - duration_in_seconds: [Integer] The duration of the operation in seconds
  def generate_cover_image(product_name:)
    blob, duration = with_retries(operation: "Generate cover image", context: product_name) do
      image_prompt = "Professional, fully covered, high-quality digital product cover image with a modern, clean design and elegant typography. The cover features the product name, '#{product_name}', centered and fully visible, with proper text wrapping, balanced spacing, and padding. Design is optimized to ensure no text is cropped or cut off. Avoid any clipping or cropping of text, and maintain a margin around all edges. Include subtle gradients, minimalist icons, and a harmonious color palette suited for a digital marketplace. The style is sleek, professional, and visually balanced within a square 1024x1024 canvas."
      response = openai_client(COVER_IMAGE_GENERATION_TIMEOUT_IN_SECONDS).images.generate(
        parameters: {
          prompt: image_prompt,
          model: "gpt-image-1",
          size: "1024x1024",
          quality: "medium",
          output_format: "jpeg"
        }
      )

      b64_json = response.dig("data", 0, "b64_json")
      raise "Failed to generate cover image - no image data returned" if b64_json.blank?

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(Base64.decode64(b64_json)),
        filename: "cover_image-#{Time.now.to_i}.jpeg",
        content_type: "image/jpeg"
      )

      blob.analyze
      blob
    end

    {
      blob:,
      duration_in_seconds: duration
    }
  end

  # @param product_info [Hash] The product info
  #   - name: [String] The product name
  #   - description: [String] The product description as an HTML string
  #   - native_type: [String] The product native type
  #   - price: [Float] The product price in the current seller's currency
  #   - price_frequency_in_months: [Integer] The product price frequency in months
  # @return [Hash] with the following keys:
  #   - pages: [Array<Hash>] The rich content pages
  #   - duration_in_seconds: [Integer] The duration of the operation in seconds
  def generate_rich_content_pages(product_info, current_seller:)
    pages, duration = with_retries(operation: "Generate rich content pages", context: product_info[:name]) do
      price_frequency_in_months_prompt = product_info[:price_frequency_in_months] ? "Price frequency in months: #{product_info[:price_frequency_in_months]}." : ""

      response = openai_client(RICH_CONTENT_PAGES_GENERATION_TIMEOUT_IN_SECONDS).chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: %Q{
                You are creating rich content pages for a digital product.
                Generate 3-4 pages of content in Tiptap JSON format, each page having a title and content array with 8-10 meaningful and contextually relevant paragraphs, headings, and lists.
                Return a JSON array of pages. Example output format:
                [
                  { "title": "Page 1",
                    "content": [
                      { "type": "heading", "attrs": { "level": 2 }, "content": [ { "type": "text", "text": "Heading 1" } ] },
                      { "type": "paragraph", "content": [ { "type": "text", "text": "Paragraph 1" } ] },
                      { "type": "orderedList", "content": [ { "type": "listItem", "content": [ { "type": "text", "text": "List item 1" } ] } ] },
                      { "type": "bulletList", "content": [ { "type": "listItem", "content": [ { "type": "text", "text": "List item 2" } ] } ] }
                    ]
                  }
                ]
              }.split("\n").map(&:strip).join("\n")
            },
            {
              role: "user",
              content: "Create detailed content pages for: #{product_info[:name]}. Description: #{product_info[:description]}. Product native type: #{product_info[:native_type]}. Price: #{product_info[:price]} #{current_seller.currency_type}. #{price_frequency_in_months_prompt}"
            }
          ],
          response_format: { type: "json_object" },
          temperature: 0.5
        }
      )

      content = response.dig("choices", 0, "message", "content")
      raise "Failed to generate rich content pages - no content returned" if content.blank?

      JSON.parse(content)
    end

    {
      pages:,
      duration_in_seconds: duration
    }
  end

  private
    attr_reader :current_seller

    def openai_client(timeout_in_seconds)
      OpenAI::Client.new(request_timeout: timeout_in_seconds)
    end

    def with_retries(operation:, context: nil, max_tries: 2, delay: 1)
      tries = 0
      start_time = Time.now
      begin
        tries += 1
        result = yield
        duration = Time.now - start_time
        Rails.logger.info("Successfully completed '#{operation}' in #{duration.round(2)}s")
        [result, duration]
      rescue StandardError => e
        duration = Time.now - start_time
        if tries < max_tries
          Rails.logger.info("Failed to perform '#{operation}', attempt #{tries}/#{max_tries}: #{context}: #{e.message}")
          sleep(delay)
          retry
        else
          Rails.logger.error("Failed to perform '#{operation}' after #{max_tries} attempts in #{duration.round(2)}s: #{context}: #{e.message}")
          raise MaxRetriesExceededError, "Failed to perform '#{operation}' after #{max_tries} attempts: #{e.message}"
        end
      end
    end
end
