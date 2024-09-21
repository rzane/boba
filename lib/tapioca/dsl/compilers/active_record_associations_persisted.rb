# typed: ignore
# frozen_string_literal: true

return unless defined?(ActiveRecord::Base)

module Tapioca
  module Dsl
    module Compilers
      # `Tapioca::Dsl::Compilers::ActiveRecordAssociationsPersisted` extends the default Tapioca compiler `Tapioca::Dsl::Compilers::ActiveRecordAssociations`
      # to provide an option to generate RBI files for associations on models assuming that the model is persisted. These sigs therefore respect
      # validations and DB constraints, and generate non-nilable types for associations that are required or non-optional.
      #
      # This compiler accepts a `ActiveRecordAssociationTypes` option that can be used to specify
      # how the types of `belongs_to` and `has_one` associations should be generated. The option can be one of the
      # following:
      #  - `nilable (_default_)`: All association methods will be generated with `T.nilable` return types. This is
      #  strictly the most correct way to type the methods, but it can make working with the models more cumbersome, as
      #  you will have to handle the `nil` cases explicitly using `T.must` or the safe navigation operator `&.`, even
      #  for valid persisted models.
      #  - `persisted`: The methods will be generated with the type that matches validations on the association. If
      #  there is a `required: true` or `optional: false`, then the types will be generated as non-nilable. This mode
      #  basically treats each model as if it was a valid and persisted model. Note that this makes typing Active Record
      #  models easier, but does not match the behaviour of non-persisted or invalid models, which can have `nil`
      #  associations.
      #
      # For example, with the following model class:
      #
      # ~~~rb
      # class Post < ActiveRecord::Base
      #   belongs_to :category
      #   has_many :comments
      #   has_one :author, class_name: "User", optional: false
      #
      #   accepts_nested_attributes_for :category, :comments, :author
      # end
      # ~~~
      #
      # By default, the compiler will generate types consistent with `Tapioca::Dsl::Compilers::ActiveRecordAssociationsPersisted`.
      # If `ActiveRecordAssociationTypes` is `persisted`, the `author` method will be generated as:
      # ~~~rbi
      #     sig { returns(::User) }
      #     def author; end
      # ~~~
      # and if the option is set to `untyped`, the `author` method will be generated as:
      # ~~~rbi
      #     sig { returns(T.untyped) }
      #     def author; end
      # ~~~
      class ActiveRecordAssociationsPersisted < ::Tapioca::Dsl::Compilers::ActiveRecordAssociations
        extend T::Sig

        class AssociationTypeOption < T::Enum
          extend T::Sig

          enums do
            Nilable = new("nilable")
            Persisted = new("persisted")
          end

          class << self
            extend T::Sig

            sig do
              params(
                options: T::Hash[String, T.untyped],
                block: T.proc.params(value: String, default_association_type_option: AssociationTypeOption).void,
              ).returns(AssociationTypeOption)
            end
            def from_options(options, &block)
              association_type_option = Nilable
              value = options["ActiveRecordAssociationTypes"]

              if value
                if has_serialized?(value)
                  association_type_option = from_serialized(value)
                else
                  block.call(value, association_type_option)
                end
              end

              association_type_option
            end
          end

          sig { returns(T::Boolean) }
          def persisted?
            self == AssociationTypeOption::Persisted
          end

          sig { returns(T::Boolean) }
          def nilable?
            self == AssociationTypeOption::Nilable
          end
        end

        private

        sig { returns(AssociationTypeOption) }
        def association_type_option
          @association_type_option ||= T.let(
            AssociationTypeOption.from_options(options) do |value, default_association_type_option|
              add_error(<<~MSG.strip)
                Unknown value for compiler option `ActiveRecordAssociationTypes` given: `#{value}`.
                Proceeding with the default value: `#{default_association_type_option.serialize}`.
              MSG
            end,
            T.nilable(AssociationTypeOption),
          )
        end

        sig do
          params(
            klass: RBI::Scope,
            association_name: T.any(String, Symbol),
            reflection: ReflectionType,
          ).void
        end
        def populate_single_assoc_getter_setter(klass, association_name, reflection)
          association_class = type_for(reflection)
          association_type = single_association_type_for(reflection)
          association_methods_module = constant.generated_association_methods

          klass.create_method(
            association_name.to_s,
            return_type: association_type,
          )
          klass.create_method(
            "#{association_name}=",
            parameters: [create_param("value", type: association_type)],
            return_type: "void",
          )
          klass.create_method(
            "reload_#{association_name}",
            return_type: association_type,
          )
          klass.create_method(
            "reset_#{association_name}",
            return_type: "void",
          )
          if association_methods_module.method_defined?("#{association_name}_changed?")
            klass.create_method(
              "#{association_name}_changed?",
              return_type: "T::Boolean",
            )
          end
          if association_methods_module.method_defined?("#{association_name}_previously_changed?")
            klass.create_method(
              "#{association_name}_previously_changed?",
              return_type: "T::Boolean",
            )
          end
          unless reflection.polymorphic?
            klass.create_method(
              "build_#{association_name}",
              parameters: [
                create_rest_param("args", type: "T.untyped"),
                create_block_param("blk", type: "T.untyped"),
              ],
              return_type: association_class,
            )
            klass.create_method(
              "create_#{association_name}",
              parameters: [
                create_rest_param("args", type: "T.untyped"),
                create_block_param("blk", type: "T.untyped"),
              ],
              return_type: association_class,
            )
            klass.create_method(
              "create_#{association_name}!",
              parameters: [
                create_rest_param("args", type: "T.untyped"),
                create_block_param("blk", type: "T.untyped"),
              ],
              return_type: association_class,
            )
          end
        end

        sig do
          params(
            reflection: ReflectionType,
          ).returns(String)
        end
        def single_association_type_for(reflection)
          association_class = type_for(reflection)
          return as_nilable_type(association_class) unless association_type_option.persisted?

          if has_one_and_required_reflection?(reflection) || belongs_to_and_non_optional_reflection?(reflection)
            association_class
          else
            as_nilable_type(association_class)
          end
        end

        # Note - one can do more here. If the association's attribute has an unconditional presence validation, it
        # should also be considered required.
        sig { params(reflection: ReflectionType).returns(T::Boolean) }
        def has_one_and_required_reflection?(reflection)
          reflection.has_one? && !!reflection.options[:required]
        end

        # Note - one can do more here. If the FK defining the belongs_to association is non-nullable at the DB level, or
        # if the association's attribute has an unconditional presence validation, it should also be considered
        # non-optional.
        sig { params(reflection: ReflectionType).returns(T::Boolean) }
        def belongs_to_and_non_optional_reflection?(reflection)
          return false unless reflection.belongs_to?

          optional = if reflection.options.key?(:required)
            !reflection.options[:required]
          else
            reflection.options[:optional]
          end

          if optional.nil?
            !!reflection.active_record.belongs_to_required_by_default
          else
            !optional
          end
        end
      end
    end
  end
end