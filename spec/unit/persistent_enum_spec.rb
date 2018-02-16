# frozen_string_literal: true

# rubocop:disable Performance/HashEachMethods, Style/Semicolon, Lint/MissingCopEnableDirective

require 'persistent_enum'
require 'byebug'

require_relative '../spec_helper'

RSpec.describe PersistentEnum, :database do
  CONSTANTS = [:One, :Two, :Three, :Four].freeze

  before(:context) do
    initialize_database
  end

  let(:logger) { spy("logger") }

  before(:each) do
    ActiveRecord::Base.logger = logger
  end

  after(:each) do
    destroy_test_models
    ActiveRecord::Base.logger = logger
  end

  shared_examples "acts like an enum" do
    # abstract :model

    it "looks up each value" do
      CONSTANTS.each do |c|
        e = model.value_of(c)
        expect(e).to               be_present
        expect(e.enum_constant).to be_a(String)
        expect(e.to_sym).to        eq(c)
        expect(e).to               eq(model[e.ordinal])
        expect(e).to               eq(model.const_get(c.upcase))
        expect(e).to               be_frozen
        expect(e.enum_constant).to be_frozen
      end
    end

    it "returns all values from the cache" do
      expect(model.values.map(&:to_sym)).to contain_exactly(*CONSTANTS)
    end
  end

  shared_examples "acts like a persisted enum" do
    # abstract :model

    include_examples "acts like an enum"

    context "a referring model" do
      let(:foreign_name) { model.model_name.singular }
      let(:foreign_key) { foreign_name + "_id" }

      let(:other_model) do
        foreign_name = foreign_name()
        foreign_key_type = model.columns.detect { |x| x.name == "id" }.sql_type

        create_table = ->(t) {
          t.references foreign_name, type: foreign_key_type, foreign_key: true
        }

        create_test_model(:referrer, create_table) do
          belongs_to_enum foreign_name
        end
      end

      it "can be created from enum value" do
        model.values.each do |v|
          t = other_model.new(foreign_name => v)
          expect(t).to be_valid
                   .and have_attributes(foreign_name => v,
                                        foreign_key  => v.ordinal)
        end
      end

      it "can be created from constant name" do
        model.values.each do |v|
          t = other_model.new(foreign_name => v.enum_constant)
          expect(t).to be_valid
                   .and have_attributes(foreign_name => v,
                                        foreign_key  => v.ordinal)
        end
      end

      it "can be created from ordinal" do
        model.values.each do |v|
          t = other_model.new(foreign_key => v.ordinal)
          expect(t).to be_valid
                   .and have_attributes(foreign_name => v,
                                        foreign_key  => v.ordinal)
        end
      end

      it "can be created with null foreign key" do
        t = other_model.new
        expect(t).to be_valid
      end

      it "can not be created with invalid foreign key" do
        t = other_model.new(foreign_key => -1)
        expect(t).not_to be_valid
      end

      it "can not be created with invalid foreign constant" do
        expect {
          other_model.new(foreign_name => :BadConstant)
        }.to raise_error(NameError)
      end
    end
  end

  context "with an enum model" do
    let(:model) do
      create_test_model(:with_table, ->(t) { t.string :name }) do
        acts_as_enum(CONSTANTS)
      end
    end

    it_behaves_like "acts like a persisted enum"

    it "returns all values from the database" do
      expect(model.all.map(&:to_sym)).to contain_exactly(*CONSTANTS)
    end

    it "is immutable" do
      expect { model.create(name: "foo") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)

      expect { model::ONE.name = "foo" }
        .to raise_error(RuntimeError, /can't modify frozen/) # Frozen object

      expect { model.first.update_attribute(:name, "foo") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)

      expect { model.first.destroy }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  context "with a table-less enum" do
    let(:model) do
      create_test_model(:without_table, nil, create_table: false) do
        acts_as_enum(CONSTANTS)
      end
    end

    it "warns that the table is not present" do
      expect(model).to be_present
      expect(logger).to have_received(:warn).with(a_string_matching(/Database table for model.*doesn't exist/))
    end

    it_behaves_like "acts like an enum"

    it "initializes dummy values correctly" do
      model.values.each do |val|
        i = val.ordinal
        expect(i).to be_a(Integer)
        expect(val.id).to    eq(i)
        expect(val["id"]).to eq(i)
        expect(val[:id]).to  eq(i)

        c = val.enum_constant
        expect(c).to be_a(String)
        expect(val.name).to    eq(c)
        expect(val["name"]).to eq(c)
        expect(val[:name]).to  eq(c)
      end
    end
  end

  context "with existing data" do
    let(:initial_ordinal) { 9998 }
    let(:initial_constant) { CONSTANTS.first }

    let(:existing_ordinal) { 9999 }
    let(:existing_constant) { :Hello }

    let!(:model) do
      model = create_test_model(:with_existing, ->(t) { t.string :name })
      @initial_value  = model.create(id: initial_ordinal, name: initial_constant.to_s)
      @existing_value = model.create(id: existing_ordinal, name: existing_constant.to_s)
      model.acts_as_enum(CONSTANTS)
      model
    end

    it_behaves_like "acts like a persisted enum"

    let(:expected_all) { (CONSTANTS + [existing_constant]) }
    let(:expected_required) { CONSTANTS }

    it "caches required values" do
      expect(model.values.map(&:to_sym)).to contain_exactly(*expected_required)
    end

    it "caches all values" do
      expect(model.all_values.map(&:to_sym)).to contain_exactly(*expected_all)
    end

    it "loads all values" do
      expect(model.all.map(&:to_sym)).to contain_exactly(*expected_all)
    end

    let(:required_ordinals) { expected_required.map { |name| model.value_of!(name).ordinal } }
    let(:all_ordinals) { expected_all.map { |name| model.value_of!(name).ordinal } }

    it "caches required ordinals" do
      expect(model.ordinals).to contain_exactly(*required_ordinals)
    end

    it "caches all ordinals" do
      expect(model.all_ordinals).to contain_exactly(*all_ordinals)
    end

    it "loads all ordinals" do
      expect(model.pluck(:id)).to contain_exactly(*all_ordinals)
    end

    it "respects initial value" do
      expect(model[initial_ordinal]).to eq(@initial_value)
      expect(model.value_of(initial_constant)).to eq(@initial_value)
      expect(model.where(name: initial_constant).first).to eq(@initial_value)
    end

    it "respects existing value" do
      expect(model[existing_ordinal]).to eq(@existing_value)
      expect(model.value_of(existing_constant)).to eq(@existing_value)
      expect(model.where(name: existing_constant).first).to eq(@existing_value)
    end

    it "marks existing model as non-active" do
      expect(model[existing_ordinal]).to_not be_active
    end
  end

  context "with cached constants" do
    let(:model) do
      create_test_model(:with_constants, ->(t) { t.string :name }) do
        PersistentEnum.cache_constants(self, CONSTANTS)
      end
    end

    it "caches all the constants" do
      CONSTANTS.each do |c|
        cached = model.const_get(c.upcase)
        expect(cached).to be_present
        expect(cached.name).to eq(c.to_s)

        loaded = model.find_by(name: c.to_s)
        expect(loaded).to be_present.and eq(cached)
      end
    end
  end

  context "with complex constant names" do
    let(:test_constants) do
      {
        "CamelCase"             => "CAMEL_CASE",
        :Symbolic               => "SYMBOLIC",
        "with.punctuation"      => "WITH_PUNCTUATION",
        "multiple_.underscores" => "MULTIPLE_UNDERSCORES"
      }
    end

    let(:model) do
      test_constants = test_constants()
      create_test_model(:with_complex_names, ->(t) { t.string :name }) do
        PersistentEnum.cache_constants(self, test_constants.keys)
      end
    end

    it "caches the constant name as we expect" do
      test_constants.each do |expected_name, expected_constant|
        val = model.const_get(expected_constant)
        expect(val).to be_present
        expect(val.name).to eq(expected_name.to_s)
      end
    end
  end

  context "with extra fields" do
    let(:members) do
      {
        :One   => { count: 1 },
        :Two   => { count: 2 },
        :Three => { count: 3 },
        :Four  => { count: 4 }
      }
    end

    shared_examples "acts like an enum with extra fields" do
      it "has all expected members with expected values" do
        members.each do |name, fields|
          ev = model.value_of(name)

          # Ensure it exists and is correctly saved
          expect(ev).to be_present
          expect(model.values).to include(ev)
          expect(model.all_values).to include(ev)
          expect(ev).to eq(model[ev.ordinal])

          # Ensure it's correctly saved
          if model.table_exists?
            expect(model.where(name: name).first).to eq(ev)
          end

          # and that fields have been correctly set
          fields.each do |fname, fvalue|
            expect(ev[fname]).to eq(fvalue)
          end
        end
      end
    end

    shared_examples "acts like a persisted enum with extra fields" do
      include_examples "acts like an enum with extra fields"
    end

    context "providing a hash" do
      let(:model) do
        members = members()
        create_test_model(:with_extra_field, ->(t) { t.string :name; t.integer :count }) do
          # pre-existing matching, non-matching, and outdated data
          create(name: "One", count: 3)
          create(name: "Two", count: 2)
          create(name: "Zero", count: 0)

          acts_as_enum(members)
        end
      end

      it_behaves_like "acts like a persisted enum"
      it_behaves_like "acts like a persisted enum with extra fields"

      it "keeps outdated data" do
        z = model.value_of("Zero")
        expect(z).to be_present
        expect(model[z.ordinal]).to eq(z)
        expect(z.count).to eq(0)
        expect(model.all_values).to include(z)
        expect(model.values).not_to include(z)
      end
    end

    context "using builder interface" do
      let(:model) do
        create_test_model(:with_extra_field_using_builder, ->(t) { t.string :name; t.integer :count }) do
          acts_as_enum([]) do
            One(count: 1)
            Two(count: 2)
            constant!(:Three, count: 3)
            Four(count: 4)
          end
        end
      end

      it_behaves_like "acts like a persisted enum"
      it_behaves_like "acts like a persisted enum with extra fields"
    end

    context "without table" do
      let(:model) do
        members = members()
        create_test_model(:with_extra_field_without_table, nil, create_table: false) do
          acts_as_enum(members)
        end
      end

      it_behaves_like "acts like an enum"
      it_behaves_like "acts like an enum with extra fields"
    end

    it "requires all required attributes to be provided" do
      expect {
        create_test_model(:test_invalid_args_a, ->(t) { t.string :name; t.integer :count }) do
          acts_as_enum([:Bad])
        end
      }.to raise_error(ArgumentError)
      destroy_test_model(:test_invalid_args_a)
    end

    context "with attributes with defaults" do
      let(:model) do
        create_test_model(:test_invalid_args_b, ->(t) { t.string :name; t.integer :count, default: 1 }) do
          acts_as_enum([]) do
            One()
            Two(count: 2)
          end
        end
      end

      it "allows defaults to be omitted" do
        o = model.value_of("One")
        expect(o).to be_present
        expect(o.count).to eq(1)

        t = model.value_of("Two")
        expect(t).to be_present
        expect(t.count).to eq(2)
      end
    end

    it "warns if nonexistent attributes are provided" do
      create_test_model(:test_invalid_args_c, ->(t) { t.string :name }) do
        acts_as_enum({ :One => { incorrect: 1 } })
      end

      expect(logger).to have_received(:warn).with(a_string_matching(/missing from table/))
    end
  end

  context "using a postgresql enum valued id" do
    let(:name) { "with_enum_id" }
    let(:enum_type) { "#{name}_type" }

    context "with table" do
      before(:each) do
        ActiveRecord::Base.connection.execute("CREATE TYPE #{enum_type} AS ENUM ()")
        ActiveRecord::Base.connection.create_table(name.pluralize, id: false) do |t|
          t.column :id, enum_type, primary_key: true, null: false
          t.string :name
        end
      end

      after(:each) do
        ActiveRecord::Base.connection.execute("DROP TYPE #{enum_type} CASCADE")
      end

      let!(:model) do
        enum_type = enum_type()
        create_test_model(:with_enum_id, nil, create_table: false) do
          acts_as_enum(CONSTANTS, sql_enum_type: enum_type)
        end
      end

      it_behaves_like "acts like a persisted enum"
    end

    context "without table" do
      let!(:model) do
        enum_type = enum_type()
        create_test_model(:no_table_enum_id, nil, create_table: false) do
          acts_as_enum(CONSTANTS, sql_enum_type: enum_type)
        end
      end

      it_behaves_like "acts like an enum"
    end
  end

  context "with the name of the enum value column changed" do
    let(:model) do
      create_test_model(:test_new_name, ->(t) { t.string :namey }) do
        acts_as_enum(CONSTANTS, name_attr: :namey)
      end
    end
    it_behaves_like "acts like a persisted enum"
  end

  it "refuses to create a table in a transaction" do
    expect {
      ActiveRecord::Base.transaction do
        create_test_model(:test_create_in_transaction, ->(t) { t.string :name }) do
          acts_as_enum([:A, :B])
        end
      end
    }.to raise_error(RuntimeError, /unsafe class initialization during/)
  end

  context "with an empty constants array" do
    let(:initial_ordinal) { 9998 }
    let(:initial_constant) { CONSTANTS.first }

    let(:model) do
      model = create_test_model(:with_empty_constants, ->(t) { t.string :name })
      @prior_value = model.create!(id: initial_ordinal, name: initial_constant.to_s)
      model.acts_as_enum([])
      model
    end

    it "looks up the existing value" do
      expect(model.value_of(initial_constant)).to eq(@prior_value)
      expect(model[initial_ordinal]).to eq(@prior_value)
    end

    it "caches the existing value" do
      expect(model.all_values).to eq([@prior_value])
    end
  end
end