# frozen_string_literal: true

require 'active_record'
require 'rails_admin/adapters/active_record/association'
require 'rails_admin/adapters/active_record/object_extension'
require 'rails_admin/adapters/active_record/property'

module RailsAdmin
  module Adapters
    module ActiveRecord
      DISABLED_COLUMN_TYPES = %i[tsvector blob binary spatial hstore geometry].freeze

      def new(params = {})
        model.new(params).extend(ObjectExtension)
      end

      def get(id, scope = scoped)
        object = scope.where(primary_key => id).first
        return unless object

        object.extend(ObjectExtension)
      end

      def scoped
        model.all
      end

      def first(options = {}, scope = nil, fields = config.list.fields)
        all(options, scope, fields).first
      end

      def all(options = {}, scope = nil, fields = config.list.fields)
        scope ||= scoped
        scope = scope.includes(options[:include]) if options[:include]
        scope = scope.limit(options[:limit]) if options[:limit]
        scope = bulk_scope(scope, options) if options[:bulk_ids]
        scope = query_scope(scope, options[:query], fields) if options[:query]
        scope = filter_scope(scope, options[:filters], fields) if options[:filters]
        scope = scope.send(Kaminari.config.page_method_name, options[:page]).per(options[:per]) if options[:page] && options[:per]
        scope = sort_scope(scope, options) if options[:sort]
        scope
      end

      def count(options = {}, scope = nil)
        all(options.merge(limit: false, page: false), scope).count(:all)
      end

      def destroy(objects)
        Array.wrap(objects).each(&:destroy)
      end

      def associations
        model.reflect_on_all_associations.collect do |association|
          Association.new(association, model)
        end
      end

      def properties
        columns = model.columns.reject do |c|
          c.type.blank? ||
            DISABLED_COLUMN_TYPES.include?(c.type.to_sym) ||
            c.try(:array)
        end
        columns.collect do |property|
          Property.new(property, model)
        end
      end

      def base_class
        model.base_class
      end

      delegate :primary_key, :table_name, to: :model, prefix: false

      def encoding
        adapter =
          if ::ActiveRecord::Base.respond_to?(:connection_db_config)
            ::ActiveRecord::Base.connection_db_config.configuration_hash[:adapter]
          else
            ::ActiveRecord::Base.connection_config[:adapter]
          end
        case adapter
        when 'postgresql'
          ::ActiveRecord::Base.connection.select_one("SELECT ''::text AS str;").values.first.encoding
        when 'mysql2'
          if RUBY_ENGINE == 'jruby'
            ::ActiveRecord::Base.connection.select_one("SELECT '' AS str;").values.first.encoding
          else
            ::ActiveRecord::Base.connection.raw_connection.encoding
          end
        when 'oracle_enhanced'
          ::ActiveRecord::Base.connection.select_one('SELECT dummy FROM DUAL').values.first.encoding
        else
          ::ActiveRecord::Base.connection.select_one("SELECT '' AS str;").values.first.encoding
        end
      end

      def embedded?
        false
      end

      def cyclic?
        false
      end

      def adapter_supports_joins?
        true
      end

    private

      def bulk_scope(scope, options)
        scope.where(primary_key => options[:bulk_ids])
      end

      def sort_scope(scope, options)
        direction = options[:sort_reverse] ? :asc : :desc

        # Sort with NULLS Last on PostgreSQL
        # https://github.com/Record360/rails_admin/commit/b66515ecf5ebe8053f1559827a3898adc468
        direction = "#{direction} NULL LAST" if model.connection.adapter_name.casecmp('postgresql').zero?

        case options[:sort]
        when String, Symbol
          scope.reorder("#{options[:sort]} #{direction}")
        when Array
          scope.reorder(options[:sort].zip(Array.new(options[:sort].size) { direction }).to_h)
        when Hash
          scope.reorder(options[:sort].map { |table_name, column| "#{table_name}.#{column}" }.
            zip(Array.new(options[:sort].size) { direction }).to_h)
        else
          raise ArgumentError.new("Unsupported sort value: #{options[:sort]}")
        end
      end

      class WhereBuilder
        def initialize(scope)
          @statements = []
          @values = []
          @tables = []
          @scope = scope
        end


        # Fix to support filtering on columns that aren't searchable
        # https://github.com/Record360/rails_admin/commit/09c14bbaf13d13f66384aac3aa09f26f674f3ba9

        def add_filter(field, value, operator)
          # support fields that are filterable but not searchable
          if field.filterable && !field.searchable
            column_infos = {column: "#{field.abstract_model.table_name}.#{field.name}", type: field.type}

            statement, value1, value2 = StatementBuilder.new(column_infos[:column], column_infos[:type], value, operator, @scope.connection.adapter_name).to_statement
            @statements << statement if statement.present?
            @values << value1 unless value1.nil?
            @values << value2 unless value2.nil?
            table, column = column_infos[:column].split('.')
            @tables.push(table) if column
          else
            add(field, value, operator)
          end
        end

        def add(field, value, operator)
          field.searchable_columns.flatten.each do |column_infos|
            statement, value1, value2 = StatementBuilder.new(column_infos[:column], column_infos[:type], value, operator, @scope.connection.adapter_name).to_statement
            @statements << statement if statement.present?
            @values << value1 unless value1.nil?
            @values << value2 unless value2.nil?
            table, column = column_infos[:column].split('.')
            @tables.push(table) if column
          end
        end

        def build
          scope = @scope.where(@statements.join(' OR '), *@values)
          scope = scope.references(*@tables.uniq) if @tables.any?
          scope
        end
      end

      # Fix to pass bindings to search_by in query_scope
      # https://github.com/Record360/rails_admin/commit/05de81b4007c48dfcb19be6cf03913cfa9aa46b2

      def query_scope(scope, query, fields = config.list.fields.select(&:queryable?))
        if config.list.with(fields.first.bindings).search_by
          scope.send(config.list.search_by, query)
        else
          wb = WhereBuilder.new(scope)
          fields.each do |field|
            value = parse_field_value(field, query)
            wb.add(field, value, field.search_operator)
          end
          # OR all query statements
          wb.build
        end
      end

      # filters example => {"string_field"=>{"0055"=>{"o"=>"like", "v"=>"test_value"}}, ...}
      # "0055" is the filter index, no use here. o is the operator, v the value
      def filter_scope(scope, filters, fields = config.list.fields.select(&:filterable?))
        filters.each_pair do |field_name, filters_dump|
          filters_dump.each do |_, filter_dump|
            wb = WhereBuilder.new(scope)
            field = fields.detect { |f| f.name.to_s == field_name }
            value = parse_field_value(field, filter_dump[:v])

            wb.add_field(field, value, (filter_dump[:o] || RailsAdmin::Config.default_search_operator))
            # AND current filter statements to other filter statements
            scope = wb.build
          end
        end
        scope
      end

      def build_statement(column, type, value, operator)
        StatementBuilder.new(column, type, value, operator, model.connection.adapter_name).to_statement
      end

      class StatementBuilder < RailsAdmin::AbstractModel::StatementBuilder
        def initialize(column, type, value, operator, adapter_name)
          super column, type, value, operator
          @adapter_name = adapter_name
        end

      protected

        def unary_operators
          case @type
          when :boolean
            boolean_unary_operators
          when :uuid
            uuid_unary_operators
          when :integer, :decimal, :float
            numeric_unary_operators
          else
            generic_unary_operators
          end
        end

      private

        def generic_unary_operators
          {
            '_blank' => ["(#{@column} IS NULL OR #{@column} = '')"],
            '_present' => ["(#{@column} IS NOT NULL AND #{@column} != '')"],
            '_null' => ["(#{@column} IS NULL)"],
            '_not_null' => ["(#{@column} IS NOT NULL)"],
            '_empty' => ["(#{@column} = '')"],
            '_not_empty' => ["(#{@column} != '')"],
          }
        end

        def boolean_unary_operators
          generic_unary_operators.merge(
            '_blank' => ["(#{@column} IS NULL)"],
            '_empty' => ["(#{@column} IS NULL)"],
            '_present' => ["(#{@column} IS NOT NULL)"],
            '_not_empty' => ["(#{@column} IS NOT NULL)"],
          )
        end
        alias_method :numeric_unary_operators, :boolean_unary_operators
        alias_method :uuid_unary_operators, :boolean_unary_operators

        def range_filter(min, max)
          if min && max && min == max
            ["(#{@column} = ?)", min]
          elsif min && max
            ["(#{@column} BETWEEN ? AND ?)", min, max]
          elsif min
            ["(#{@column} >= ?)", min]
          elsif max
            ["(#{@column} <= ?)", max]
          end
        end

        def build_statement_for_type
          case @type
          when :boolean                   then build_statement_for_boolean
          when :integer, :decimal, :float then build_statement_for_integer_decimal_or_float
          when :string, :text, :citext    then build_statement_for_string_or_text
          when :enum                      then build_statement_for_enum
          when :belongs_to_association    then build_statement_for_belongs_to_association
          when :uuid                      then build_statement_for_uuid
          end
        end

        def build_statement_for_boolean
          case @value
          when 'false', 'f', '0'
            ["(#{@column} IS NULL OR #{@column} = ?)", false]
          when 'true', 't', '1'
            ["(#{@column} = ?)", true]
          end
        end

        def column_for_value(value)
          ["(#{@column} = ?)", value]
        end

        def build_statement_for_belongs_to_association
          return if @value.blank?

          ["(#{@column} = ?)", @value.to_i] if @value.to_i.to_s == @value
        end

        def build_statement_for_string_or_text
          return if @value.blank?

          return ["(#{@column} = ?)", @value] if ['is', '='].include?(@operator)

          @value = @value.mb_chars.downcase unless %w[postgresql postgis].include? ar_adapter

          @value =
            case @operator
            when 'default', 'like', 'not_like'
              "%#{@value}%"
            when 'starts_with'
              "#{@value}%"
            when 'ends_with'
              "%#{@value}"
            else
              return
            end

          if %w[postgresql postgis].include? ar_adapter
            if @operator == 'not_like'
              ["(#{@column} NOT ILIKE ?)", @value]
            else
              ["(#{@column} ILIKE ?)", @value]
            end
          elsif @operator == 'not_like'
            ["(LOWER(#{@column}) NOT LIKE ?)", @value]
          else
            ["(LOWER(#{@column}) LIKE ?)", @value]
          end
        end

        def build_statement_for_enum
          return if @value.blank?

          ["(#{@column} IN (?))", Array.wrap(@value)]
        end

        def build_statement_for_uuid
          column_for_value(@value) if /\A[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}\z/.match?(@value.to_s)
        end

        def ar_adapter
          @adapter_name.downcase
        end
      end
    end
  end
end
