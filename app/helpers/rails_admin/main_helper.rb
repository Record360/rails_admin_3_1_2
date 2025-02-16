# frozen_string_literal: true

module RailsAdmin
  module MainHelper
    def rails_admin_form_for(*args, &block)
      options = args.extract_options!.reverse_merge(builder: RailsAdmin::FormBuilder)
      (options[:html] ||= {})[:novalidate] ||= !RailsAdmin::Config.browser_validations

      form_for(*(args << options), &block) << after_nested_form_callbacks
    end

    def get_indicator(percent)
      return '' if percent < 0          # none
      return 'info' if percent < 34     # < 1/100 of max
      return 'success' if percent < 67  # < 1/10 of max
      return 'warning' if percent < 84  # < 1/3 of max

      'danger'                          # > 1/3 of max
    end

    def filterable_fields(bindings)
      # Pass bindings to all field definitions (for dynamic behavior)
      # https://github.com/Record360/rails_admin/commit/25e0dca5c5a7d19543b03b4b9d07e91893e84d4c

      @filterable_fields ||= @model_config.list.fields.collect { |f| f.with(bindings) }.select(&:filterable?)
    end

    def ordered_filters
      return @ordered_filters if @ordered_filters.present?

      @index = 0
      @ordered_filters = (params[:f].try(:permit!).try(:to_h) || @model_config.list.filters).inject({}) do |memo, filter|
        field_name = filter.is_a?(Array) ? filter.first : filter
        (filter.is_a?(Array) ? filter.last : {(@index += 1) => {'v' => ''}}).each do |index, filter_hash|
          if filter_hash['disabled'].blank?
            memo[index] = {field_name => filter_hash}
          else
            params[:f].delete(field_name)
          end
        end
        memo
      end.to_a.sort_by(&:first)
    end

    def ordered_filter_options(bindings)
      if ordered_filters
        @ordered_filter_options ||= ordered_filters.map do |duplet|
          filter_for_field = duplet[1]
          filter_name = filter_for_field.keys.first
          filter_hash = filter_for_field.values.first

          # Pass bindings to all field definitions (for dynamic behavior)
          # https://github.com/Record360/rails_admin/commit/25e0dca5c5a7d19543b03b4b9d07e91893e84d4c

          # TODO: Test ENUMS
          # Unable to find a way to fix enums similar to:
          # https://github.com/Record360/rails_admin/commit/ef49884325693dc2a3476f42a8459f12a1106422

          unless (field = filterable_fields(bindings).find { |f| f.name == filter_name.to_sym })
            raise "#{filter_name} is not currently filterable; filterable fields are #{filterable_fields.map(&:name).join(', ')}"
          end

          field.filter_options.merge(
            index: duplet[0],
            operator: filter_hash['o'] || field.default_filter_operator,
            value: filter_hash['v'],
          )
        end
      end
    end
  end
end
