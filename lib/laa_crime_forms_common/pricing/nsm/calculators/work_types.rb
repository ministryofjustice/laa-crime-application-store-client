module LaaCrimeFormsCommon
  module Pricing
    module Nsm
      module Calculators
        class WorkTypes
          WORK_TYPES = %w[
            travel
            waiting
            attendance_with_counsel
            attendance_without_counsel
            preparation
            advocacy
          ].freeze

          class << self
            def call(claim, show_assessed:, rates:)
              new(claim, show_assessed, rates).call
            end
          end

          def initialize(claim, show_assessed, rates)
            @claim = claim
            @show_assessed = show_assessed
            @rates = rates
          end

          def call
            calculations = work_items.map { Calculators::WorkItem.call(claim, _1, show_assessed:, rates:) }

            types = WORK_TYPES.to_h do |work_type|
              claimed_items = calculations.select { _1[:claimed_work_type] == work_type }
              assessed_items = calculations.select { _1[:assessed_work_type] == work_type } if show_assessed

              [work_type.to_sym, build_summary(claimed_items, assessed_items)]
            end

            types[:total] = add_vat(build_summary(calculations))

            types
          end

          def work_items
            @work_items ||= claim.work_items.map { Wrappers::WorkItem.new(_1) }
          end

          def build_summary(claimed_items, assessed_items = claimed_items)
            claimed_total_exc_vat = claimed_items.sum(Rational(0, 1)) { _1[:claimed_total_exc_vat] }

            data = {
              claimed_time_spent_in_minutes: claimed_items.sum(Rational(0, 1)) { _1[:claimed_time_spent_in_minutes] },
              claimed_total_exc_vat:,
              claimed_vatable: claim.vat_registered ? claimed_total_exc_vat : Rational(0, 1),
            }

            if show_assessed
              assessed_total_exc_vat = assessed_items.sum(Rational(0, 1)) { _1[:assessed_total_exc_vat] }
              data.merge!(
                assessed_time_spent_in_minutes: assessed_items.sum(Rational(0, 1)) { _1[:assessed_time_spent_in_minutes] },
                assessed_total_exc_vat:,
                assessed_vatable: claim.vat_registered ? assessed_total_exc_vat : Rational(0, 1),
                type_changes: claimed_items.any? { _1[:claimed_work_type] != _1[:assessed_work_type] },
                cost_summary_group_changes: claimed_items.any? { cost_summary_group_changed?(_1) },
              )
            end

            data
          end

          def cost_summary_group_changed?(work_item_calculation)
            cost_summary_group(work_item_calculation[:claimed_work_type]) != cost_summary_group(work_item_calculation[:assessed_work_type])
          end

          def cost_summary_group(work_type)
            return work_type if %w[travel waiting].include?(work_type)

            "profit_costs"
          end

          def add_vat(hash)
            hash[:claimed_vat] = hash[:claimed_vatable] * rates.vat
            hash[:assessed_vat] = (hash[:assessed_vatable] * rates.vat) if show_assessed
            hash[:claimed_total_inc_vat] = hash[:claimed_total_exc_vat] + hash[:claimed_vat]
            hash[:assessed_total_inc_vat] = (hash[:assessed_total_exc_vat] + hash[:assessed_vat]) if show_assessed

            hash
          end

          attr_reader :claim, :show_assessed, :rates
        end
      end
    end
  end
end
