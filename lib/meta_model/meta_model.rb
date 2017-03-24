require "active_model_serializers"

module MetaModel
  extend ActiveSupport::Autoload
  autoload :MetaModel
  
  class MetaModelSerializer < ActiveModel::Serializer

    def _type
      object.type.pluralize
    end

    def initialize *args, &block
      super
      args.first.setup_serializer(self)
    end

    # Return the +attributes+ of +object+ as presented
    # by the serializer.
    def attributes(requested_attrs = nil, reload = false)
      @attributes = nil if reload
      @attributes ||= self.singleton_class._attributes_data.each_with_object({}) do |(key, attr), hash|
        next if attr.excluded?(self)
        next unless requested_attrs.nil? || requested_attrs.include?(key)
        hash[key] = object.send(key)
      end
    end

    def associations(include_tree = DEFAULT_INCLUDE_TREE, include_slice = nil)
      include_slice ||= include_tree
      return unless object

      Enumerator.new do |y|
        self.singleton_class._reflections.each do |reflection|
          next if reflection.excluded?(self)
          key = reflection.options.fetch(:key, reflection.name)
          next unless include_tree.key?(key)
          y.yield reflection.build_association(self, instance_options, include_slice)
        end
      end
    end
  end
  
  class MetaModel < ActiveModelSerializers::Model

    attr_reader :type, :id

    def initialize(jsonapi_resource, index = nil)
      @jsonapi_resource = jsonapi_resource
      @type = jsonapi_resource[:data][:type]
      @id = jsonapi_resource[:data][:id]
      @attributes = jsonapi_resource[:data][:attributes] || {}
      @relationships = jsonapi_resource[:data][:relationships] || []
      @included = jsonapi_resource[:included] || []
      @index = index || Hash.new
      index_includes
      set_attributes if @attributes.size > 0
      populate_relationships if @relationships.size > 0
    end

    def setup_serializer(serializer)
      keys = (@attributes.keys + [:id]).join(', :')
      serializer.singleton_class.class_eval <<-end_eval
      self._attributes_data = {}
      self._reflections = []
      attributes :#{keys}
      end_eval

      @relationships.each do |relationship_name, value|
        relationship = value.is_a?(Array) ? "has_many" : "has_one"
        serializer.singleton_class.class_eval <<-end_eval
        #{relationship} :#{relationship_name}
        def #{relationship_name}
          object.#{relationship_name}
        end
        end_eval
      end
    end

    private

    def index_includes
      @included.each do |resource|
        id, type = resource[:id], resource[:type]
        key = "#{type}_#{id}"
        next if @index[key].present?
        to_pass = {}
        object = MetaModel.new({data: resource, included: @included.reject { |obj| obj.object_id == resource.object_id }}, to_pass.merge!(@index))
        @index = to_pass
        @index[key] = object
      end
    end

    def set_attributes
      keys = (@attributes.keys).join(', :')
      self.singleton_class.class_eval <<-end_eval
      attr_accessor :#{keys}
      end_eval
      @attributes.each do |key, value|
        self.send("#{key}=", value)
      end
    end

    def populate_relationships
      keys = @relationships.keys.join(', :')
      self.singleton_class.class_eval <<-end_eval
      attr_accessor :#{keys}
      end_eval

      @relationships.each do |relationship_name, value|
        internal = value[:data]
        next if internal.nil?
        if internal.is_a? Array
          self.send("#{relationship_name}=", multi_relationship_setup(internal))
        else
          self.send("#{relationship_name}=", single_relationship_setup(internal))
        end
      end
    end

    def multi_relationship_setup(value)
      value.map do |resource_id|
        resource_lookup resource_id
      end
    end

    def single_relationship_setup(value)
      resource_lookup value
    end

    def resource_lookup(value)
      @index["#{value[:type]}_#{value[:id]}"] || MetaModel.new({data: value})
    end
  end
end
