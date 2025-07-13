# frozen_string_literal: true

require "spec_helper"

describe CreateIndiaSalesReportJob do
  it "raises an ArgumentError if the year is less than 2014 or greater than 3200" do
    expect do
      described_class.new.perform(1, 2013)
    end.to raise_error(ArgumentError)

    expect do
      described_class.new.perform(1, 3201)
    end.to raise_error(ArgumentError)
  end

  it "raises an ArgumentError if the month is not within 1 and 12 inclusive" do
    expect do
      described_class.new.perform(0, 2023)
    end.to raise_error(ArgumentError)

    expect do
      described_class.new.perform(13, 2023)
    end.to raise_error(ArgumentError)
  end

  it "defaults to previous month when no parameters provided" do
    travel_to(Time.zone.local(2023, 6, 15)) do
      # Mock S3 to prevent real API calls
      s3_bucket_double = double
      s3_object_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      allow(s3_bucket_double).to receive(:object).and_return(s3_object_double)
      allow(s3_object_double).to receive(:upload_file)
      allow(s3_object_double).to receive(:presigned_url).and_return("https://example.com/test-url")

      # Mock Slack notification
      allow(SlackMessageWorker).to receive(:perform_async)

      # Mock database queries to prevent actual data access
      allow(Purchase).to receive_message_chain(:joins, :where, :find_each).and_return([])

      # Test that it calls perform with previous month parameters
      expect_any_instance_of(described_class).to receive(:perform).with(5, 2023).and_call_original
      described_class.new.perform
    end
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/india-sales-report-spec-#{SecureRandom.hex(18)}.csv")
    end

    before do
      Feature.activate(:collect_tax_in)

      create(:zip_tax_rate, country: "IN", state: nil, zip_code: nil, combined_rate: 0.18, is_seller_responsible: false)

      test_time = Time.zone.local(2023, 6, 15)
      product = create(:product, price_cents: 1000)

      travel_to(test_time) do
        @india_purchase = create(:purchase,
                                 link: product,
                                 purchaser: product.user,
                                 purchase_state: "in_progress",
                                 quantity: 1,
                                 perceived_price_cents: 1000,
                                 country: "India",
                                 ip_country: "India",
                                 ip_state: "MH",
                                 stripe_transaction_id: "txn_test123"
        )
        @india_purchase.mark_test_successful!

        vat_purchase = create(:purchase,
                              link: product,
                              purchaser: product.user,
                              purchase_state: "in_progress",
                              quantity: 1,
                              perceived_price_cents: 1000,
                              country: "India",
                              ip_country: "India",
                              stripe_transaction_id: "txn_test456"
        )
        vat_purchase.mark_test_successful!
        vat_purchase.create_purchase_sales_tax_info!(business_vat_id: "GST123456789")

        refunded_purchase = create(:purchase,
                                   link: product,
                                   purchaser: product.user,
                                   purchase_state: "in_progress",
                                   quantity: 1,
                                   perceived_price_cents: 1000,
                                   country: "India",
                                   ip_country: "India",
                                   stripe_transaction_id: "txn_test789"
        )
        refunded_purchase.mark_test_successful!
        refunded_purchase.stripe_refunded = true
        refunded_purchase.save!
      end
    end

    it "generates CSV report for India sales" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(6, 2023)

      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("payments", "India Sales Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload[0]).to eq([
                                        "ID",
                                        "Date",
                                        "Place of Supply (State)",
                                        "Zip Tax Rate (%) (Rate from Database)",
                                        "Taxable Value (cents)",
                                        "Integrated Tax Amount (cents)",
                                        "Tax Rate (%) (Calculated From Tax Collected)",
                                        "Expected Tax (cents, rounded)",
                                        "Expected Tax (cents, floored)",
                                        "Tax Difference (rounded)",
                                        "Tax Difference (floored)"
                                      ])

      expect(actual_payload.length).to eq(2)

      data_row = actual_payload[1]
      expect(data_row[0]).to eq(@india_purchase.external_id)
      expect(data_row[2]).to eq("MH")
      expect(data_row[3]).to eq("18")
      expect(data_row[4]).to eq("1000")

      temp_file.close(true)
    end

    it "excludes purchases with business VAT ID" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(6, 2023)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(2)
      temp_file.close(true)
    end

    it "handles invalid Indian states" do
      travel_to(Time.zone.local(2023, 6, 15)) do
        invalid_product = create(:product, price_cents: 500)
        invalid_state_purchase = create(:purchase,
                                        link: invalid_product,
                                        purchaser: invalid_product.user,
                                        purchase_state: "in_progress",
                                        quantity: 1,
                                        perceived_price_cents: 500,
                                        country: "India",
                                        ip_country: "India",
                                        ip_state: "123",
                                        stripe_transaction_id: "txn_invalid_state"
        )
        invalid_state_purchase.mark_test_successful!

        expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

        described_class.new.perform(6, 2023)

        temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
        @s3_object.get(response_target: temp_file)
        temp_file.rewind
        actual_payload = CSV.read(temp_file)

        invalid_state_row = actual_payload.find { |row| row[0] == invalid_state_purchase.external_id }
        expect(invalid_state_row).to be_present
        expect(invalid_state_row[2]).to eq("")

        temp_file.close(true)
      end
    end
  end
end
