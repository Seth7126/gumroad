# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe Api::Internal::AiProductDetailsGenerationsController do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    let(:valid_params) { { prompt: "Create a digital art course about Figma design" } }

    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { valid_params }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { user_with_role_for_seller }
      let(:policy_method) { :generate_product_details_with_ai? }
      let(:request_params) { valid_params }
      let(:request_format) { :json }
    end

    context "when user is authenticated and authorized" do
      before do
        Feature.activate_user(:ai_product_generation, seller)
      end

      it "generates product details successfully" do
        service_double = instance_double(Ai::ProductDetailsGeneratorService)
        allow(Ai::ProductDetailsGeneratorService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:generate_product_details).and_return({
          name: "Figma Design Mastery",
          description: "<p>Learn professional UI/UX design using Figma</p>",
          summary: "Complete guide to Figma design",
          number_of_content_pages: 5,
          price: 2500,
          currency_code: "usd",
          price_frequency_in_months: nil,
          native_type: "ebook",
          duration_in_seconds: 2.5
        })

        post :create, params: valid_params, format: :json

        expect(service_double).to have_received(:generate_product_details).with(prompt: "Create a digital art course about Figma design")
        expect(response).to be_successful
        expect(response.parsed_body).to eq({
          "success" => true,
          "data" => {
            "name" => "Figma Design Mastery",
            "description" => "<p>Learn professional UI/UX design using Figma</p>",
            "summary" => "Complete guide to Figma design",
            "number_of_content_pages" => 5,
            "price" => 2500,
            "currency_code" => "usd",
            "price_frequency_in_months" => nil,
            "native_type" => "ebook",
            "duration_in_seconds" => 2.5
          }
        })
      end

      it "returns error when prompt is blank" do
        post :create, params: { prompt: "" }, format: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({ "error" => "Prompt is required" })
      end

      it "returns error when prompt is missing" do
        post :create, params: {}, format: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({ "error" => "Prompt is required" })
      end
    end
  end
end
