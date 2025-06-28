# frozen_string_literal: true

# Settings / Main
class UserPolicy < ApplicationPolicy
  def deactivate?
    user.role_owner_for?(seller)
  end

  def generate_product_details_with_ai?
    Feature.active?(:ai_product_generation, seller)
  end
end
