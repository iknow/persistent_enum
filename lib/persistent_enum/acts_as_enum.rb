require "active_support"
require "active_record"

module PersistentEnum
  module ActsAsEnum
    extend ActiveSupport::Concern

    class State
      attr_accessor :required_members, :name_attr, :by_name, :by_ordinal, :required_by_ordinal

      def initialize(required_members, name_attr)
        self.required_members    = required_members.freeze
        self.name_attr           = name_attr
        self.by_name             = {}.with_indifferent_access
        self.by_ordinal          = {}
        self.required_by_ordinal = {}
      end

      def freeze
        by_name.values.each(&:freeze)
        by_name.freeze
        by_ordinal.freeze
        required_by_ordinal.freeze
        super
      end
    end

    module ClassMethods
      def _acts_as_enum_state
        nil
      end

      def initialize_acts_as_enum(required_members, name_attr)
        prev_state = _acts_as_enum_state

        ActsAsEnum.register_acts_as_enum(self) if prev_state.nil?

        state = State.new(required_members, name_attr)

        singleton_class.class_eval do
          undef_method(:_acts_as_enum_state) if method_defined?(:_acts_as_enum_state)
          define_method(:_acts_as_enum_state){ state }
        end

        values = PersistentEnum.cache_constants(self, state.required_members, name_attr: state.name_attr)
        required_constants = values.map { |val| val.read_attribute(state.name_attr) }

        # Now we've ensured that our required constants are present, load the rest
        # of the enum from the database (if present)
        if table_exists?
          values.concat(unscoped { where("id NOT IN (?)", values) })
        end

        values.each do |value|
          name    = value.enum_constant
          ordinal = value.ordinal

          # If we already have a equal value in the previous state, we want to use
          # that rather than a new copy of it
          if prev_state.present?
            prev_value = prev_state.by_name[name]
            value = prev_value if prev_value == value
          end

          state.by_name[name]       = value
          state.by_ordinal[ordinal] = value
        end

        # Collect up the required values for #values and #ordinals
        state.required_by_ordinal = state.by_name.slice(*required_constants).values.index_by(&:ordinal)

        state.freeze

        before_destroy { raise ActiveRecord::ReadOnlyRecord }
      end

      def reinitialize_acts_as_enum
        current_state = _acts_as_enum_state
        raise "Cannot refresh acts_as_enum type #{self.name}: not already initialized!" if current_state.nil?
        initialize_acts_as_enum(current_state.required_members, current_state.name_attr)
      end

      def dummy_class
        PersistentEnum.dummy_class(self, name_attr)
      end

      def [](index)
        _acts_as_enum_state.by_ordinal[index]
      end

      def value_of(name)
        _acts_as_enum_state.by_name[name]
      end

      def value_of!(name)
        v = value_of(name)
        raise NameError.new("#{self.to_s}: Invalid member '#{name}'") unless v.present?
        v
      end

      alias_method :with_name, :value_of

      # Currently active ordinals
      def ordinals
        _acts_as_enum_state.required_by_ordinal.keys
      end

      # Currently active enum members
      def values
        _acts_as_enum_state.required_by_ordinal.values
      end

      def active?(member)
        _acts_as_enum_state.required_by_ordinal.has_key?(member.ordinal)
      end

      # All ordinals, including of inactive enum members
      def all_ordinals
        _acts_as_enum_state.by_ordinal.keys
      end

      # All enum members, including inactive
      def all_values
        _acts_as_enum_state.by_ordinal.values
      end

      def name_attr
        _acts_as_enum_state.name_attr
      end
    end

    # Enum values should not be mutable: allow creation and modification only
    # before the values array has been initialized.
    def readonly?
      self.class.values.present?
    end

    def enum_constant
      read_attribute(self.class.name_attr)
    end

    def to_sym
      enum_constant.to_sym
    end

    def ordinal
      read_attribute(:id)
    end

    def freeze
      enum_constant.freeze
      super
    end

    # Is this enum member still present in the enum declaration?
    def active?
      self.class.active?(self)
    end

    class << self
      KNOWN_ENUMERATIONS = {}
      LOCK = Monitor.new

      def register_acts_as_enum(clazz)
        LOCK.synchronize do
          KNOWN_ENUMERATIONS[clazz.name] = clazz
        end
      end

      # Reload enumerations from the database: useful if the database contents
      # may have changed (e.g. fixture loading).
      def reinitialize_enumerations
        LOCK.synchronize do
          KNOWN_ENUMERATIONS.each do |name, clazz|
            clazz.reinitialize_acts_as_enum
          end
        end
      end

      # Ensure that all KNOWN_ENUMERATIONS are loaded by resolving each name
      # constant and reregistering the resulting class. Raises NameError if a
      # previously-encountered type cannot be resolved.
      def rerequire_known_enumerations
        LOCK.synchronize do
          KNOWN_ENUMERATIONS.to_a.each do |name, old_clazz|
            new_clazz = name.safe_constantize
            unless new_clazz.is_a?(Class)
              raise NameError.new("Could not resolve ActsAsEnum type '#{name}' after reload")
            end
            register_acts_as_enum(new_clazz)
          end
        end
      end
    end
  end
end
