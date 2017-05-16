module Api
  class BaseController
    module Renderer
      #
      # Helper proc to render a collection
      #
      def render_collection(type, resources, opts = {})
        render :json => collection_to_jbuilder(type, gen_reftype(type, opts), resources, opts).target!
      end

      #
      # Helper proc to render a single resource
      #
      def render_resource(type, resource, opts = {})
        render :json => resource_to_jbuilder(type, gen_reftype(type, opts), resource, opts).target!
      end

      #
      # We want reftype to reflect subcollection if targeting as such.
      #
      def gen_reftype(type, opts)
        opts[:is_subcollection] ? "#{@req.collection}/#{@req.c_id}/#{type}" : type
      end

      # Methods for Serialization as Jbuilder Objects.

      #
      # Given a resource, return its serialized flavor using Jbuilder
      #
      def collection_to_jbuilder(type, reftype, resources, opts = {})
        Jbuilder.new do |json|
          json.ignore_nil!
          json.set! 'name', opts[:name] if opts[:name]

          @paging.collection_counts(json)

          unless @req.hide?("resources")
            json.resources resources.collect do |resource|
              if opts[:expand_resources]
                add_hash json, resource_to_jbuilder(type, reftype, resource, opts).attributes!
              else
                json.href normalize_href(reftype, resource["id"])
              end
            end
          end
          cspec = collection_config[type]
          aspecs = gen_action_spec_for_collections(type, cspec, opts[:is_subcollection], reftype) if cspec
          add_actions(json, aspecs, reftype)

          @paging.paging_links(json)
        end
      end

      def resource_to_jbuilder(type, reftype, resource, opts = {})
        normalize_options = {}
        reftype = get_reftype(type, reftype, resource, opts)
        json    = Jbuilder.new
        json.ignore_nil!

        physical_attrs, virtual_attrs = validate_attr_selection(resource)
        normalize_options[:render_attributes] = physical_attrs if physical_attrs.present?

        add_hash json, normalize_hash(reftype, resource, normalize_options)

        expand_virtual_attributes(json, type, resource, virtual_attrs) unless virtual_attrs.empty?
        expand_subcollections(json, type, resource) if resource.respond_to?(:attributes)

        expand_actions(resource, json, type, opts, physical_attrs) if opts[:expand_actions]
        expand_resource_custom_actions(resource, json, type, physical_attrs)
        json
      end

      def get_reftype(type, reftype, resource, _opts = {})
        # sometimes we are returning different objects than the posted resource, i.e. request for an order.
        return reftype unless resource.respond_to?(:attributes)

        rclass = resource.class
        collection_class = collection_class(type)

        # Ensures hrefs are consistent with those of the collection they were requested from
        return reftype if collection_class == rclass || collection_class.descendants.include?(rclass)

        collection_config.name_for_klass(rclass) || reftype
      end

      #
      # Common proc for adding a child element to the Jbuilder
      #
      def add_child(json, hash)
        json.child! { |js| hash.each { |attr, value| js.set! attr, value } } unless hash.blank?
      end

      #
      # Common proc for adding a hash directly to the Jbuilder
      #
      def add_hash(json, hash)
        return if hash.blank?
        hash.each do |attr, value|
          json.set! attr, value
        end
      end

      #
      # Render nothing for normal resource deletes.
      #
      def render_normal_destroy
        head :no_content
      end

      #
      # Render nothing for normal update.
      #
      def render_normal_update(type, res = {})
        render_resource type, res
      end

      #
      # Method name for optional accessor of virtual attributes
      #
      def virtual_attribute_accessor(type, attr)
        method = "fetch_#{type}_#{attr}"
        respond_to?(method) ? method : nil
      end

      private

      def resource_search(id, type, klass)
        validate_id(id, klass)
        target = respond_to?("find_#{type}") ? public_send("find_#{type}", id) : klass.find(id)
        res = Rbac.filtered_object(target, :user => User.current_user, :class => klass)
        raise ForbiddenError, "Access to the resource #{type}/#{id} is forbidden" unless res
        res
      end

      def collection_search(is_subcollection, type, klass)
        res =
          if is_subcollection
            send("#{type}_query_resource", parent_resource_obj)
          elsif by_tag_param
            klass.find_tagged_with(:all => by_tag_param, :ns => TAG_NAMESPACE, :separator => ',')
          else
            klass.all
          end

        res = res.where(public_send("#{type}_search_conditions")) if respond_to?("#{type}_search_conditions")

        miq_expression = filter_param(klass)

        if miq_expression
          if is_subcollection && !res.respond_to?(:where)
            raise BadRequestError, "Filtering is not supported on #{type} subcollection"
          end
          sql, _, attrs = miq_expression.to_sql
          res = res.where(sql) if attrs[:supported_by_sql]
        end
        sort_options = sort_params(klass) if res.respond_to?(:reorder)
        res = res.reorder(sort_options) if sort_options.present?

        options = {:user => User.current_user}
        options[:order] = sort_options if sort_options.present?

        @paging.options(options)

        options[:filter] = miq_expression if miq_expression

        miq_expression.present? ? subquery_search(res, options) : Rbac.filtered(res, options)
      end

      def subquery_search(res, options)
        subquery_res = Rbac.search(:targets => res, :skip_counts => true)
        @paging.subquery_count = subquery_res.count
        Rbac.filtered(res, options)
      end

      def virtual_attribute_search(resource, attribute)
        if resource.class < ApplicationRecord
          # is relation in 'attribute' variable plural in the model class (from 'resource.class') ?
          if [:has_many, :has_and_belongs_to_many].include?(resource.class.reflection_with_virtual(attribute).try(:macro))
            resource_attr = resource.public_send(attribute)
            return resource_attr unless resource_attr.try(:first).kind_of?(ApplicationRecord)
            Rbac.filtered(resource_attr)
          else
            Rbac.filtered_object(resource).try(:public_send, attribute)
          end
        else
          resource.public_send(attribute)
        end
      end

      #
      # Let's expand subcollections for objects if asked for
      #
      def expand_subcollections(json, type, resource)
        collection_config.subcollections(type).each do |sc|
          target = "#{sc}_query_resource"
          next unless expand_subcollection?(sc, target)
          if Array(attribute_selection).include?(sc.to_s)
            raise BadRequestError, "Cannot expand subcollection #{sc} by name and virtual attribute"
          end
          expand_subcollection(json, sc, "#{type}/#{resource.id}/#{sc}", send(target, resource))
        end
      end

      def expand_subcollection?(sc, target)
        return false unless respond_to?(target) # If there's no query method, no need to go any further
        expand_resources?(sc) || expand_action_resource?(sc) || resource_requested?(sc)
      end

      # Expand if: expand='resources' && no attributes specified && subcollection is configured
      def expand_resources?(sc)
        @req.expand?('resources') && @req.attributes.empty? && collection_config.show?(sc)
      end

      # Expand if: resource is being returned and subcollection is configured
      # IE an update to /service_catalogs expects service_templates as part of its resource
      def expand_action_resource?(sc)
        @req.method != :get && collection_config.show?(sc)
      end

      # Expand if: explicitly requested
      def resource_requested?(sc)
        @req.expand?(sc)
      end

      #
      # Let's expand virtual attributes and related objects if asked for
      # Supporting [<related_object>]*.<virtual_attribute>
      #
      def expand_virtual_attributes(json, type, resource, virtual_attrs)
        result = {}
        object_hash = {}
        virtual_attrs.each do |vattr|
          attr_name, attr_base = split_virtual_attribute(vattr)
          value, value_result = if attr_base.blank?
                                  fetch_direct_virtual_attribute(type, resource, attr_name)
                                else
                                  fetch_indirect_virtual_attribute(type, resource, attr_base, attr_name, object_hash)
                                end
          result = result.deep_merge(value_result) unless value.nil?
        end
        add_hash json, result
      end

      def fetch_direct_virtual_attribute(type, resource, attr)
        return unless attr_accessible?(resource, attr)
        virtattr_accessor = virtual_attribute_accessor(type, attr)
        value = virtattr_accessor ? send(virtattr_accessor, resource) : virtual_attribute_search(resource, attr)
        result = {attr => normalize_attr(attr, value)}
        # set nil vtype above to "#{type}/#{resource.id}/#{attr}" to support id normalization
        [value, result]
      end

      def fetch_indirect_virtual_attribute(_type, resource, base, attr, object_hash)
        query_related_objects(base, resource, object_hash)
        return unless attr_accessible?(object_hash[base], attr)
        value  = virtual_attribute_search(object_hash[base], attr)
        result = {attr => normalize_attr(attr, value)}
        # set nil vtype above to "#{type}/#{resource.id}/#{base.tr('.', '/')}/#{attr}" to support id normalization
        base.split(".").reverse_each { |level| result = {level => result} }
        [value, result]
      end

      #
      # Accesing and hashing <resource>[.<related_object>]+ in object_hash
      #
      def query_related_objects(object_path, resource, object_hash)
        return if object_hash[object_path].present?
        related_resource = resource
        related_objects  = []
        object_path.split(".").each do |related_object|
          related_objects << related_object
          if attr_accessible?(related_resource, related_object)
            related_resource = related_resource.public_send(related_object)
            object_hash[related_objects.join(".")] = related_resource if related_resource
          end
        end
      end

      def split_virtual_attribute(attr)
        attr_parts = attr_split(attr)
        return [attr_parts.first, ""] if attr_parts.length == 1
        [attr_parts.last, attr_parts[0..-2].join(".")]
      end

      def attr_accessible?(object, attr)
        return true if object && object.respond_to?(attr)
        object.class.try(:has_attribute?, attr) ||
          object.class.try(:reflect_on_association, attr) ||
          object.class.try(:virtual_attribute?, attr) ||
          object.class.try(:virtual_reflection?, attr)
      end

      def attr_virtual?(object, attr)
        return false if ID_ATTRS.include?(attr)
        primary = attr_split(attr).first
        (object.class.respond_to?(:reflect_on_association) && object.class.reflect_on_association(primary)) ||
          (object.class.respond_to?(:virtual_attribute?) && object.class.virtual_attribute?(primary)) ||
          (object.class.respond_to?(:virtual_reflection?) && object.class.virtual_reflection?(primary))
      end

      def attr_physical?(object, attr)
        return true if ID_ATTRS.include?(attr)
        (object.class.respond_to?(:has_attribute?) && object.class.has_attribute?(attr)) &&
          !(object.class.respond_to?(:virtual_attribute?) && object.class.virtual_attribute?(attr))
      end

      def attr_split(attr)
        attr.tr("/", ".").split(".")
      end

      #
      # Let's expand actions
      #
      def expand_actions(resource, json, type, opts, physical_attrs)
        return unless render_actions(physical_attrs)

        href = json.attributes!["href"]
        cspec = collection_config[type]
        aspecs = gen_action_spec_for_resources(cspec, opts[:is_subcollection], href, resource) if cspec
        add_actions(json, aspecs, type)
      end

      def add_actions(json, aspecs, type)
        if aspecs && aspecs.any?
          json.actions do |js|
            aspecs.each { |action_spec| add_child js, normalize_hash(type, action_spec) }
          end
        end
      end

      def expand_resource_custom_actions(resource, json, type, physical_attrs)
        return unless render_actions(physical_attrs) && collection_config.custom_actions?(type)

        href = json.attributes!["href"]
        json.actions do |js|
          resource_custom_action_names(resource).each do |action|
            add_child js, "name" => action, "method" => :post, "href" => href
          end
        end
      end

      def resource_custom_action_names(resource)
        return [] unless resource.respond_to?(:custom_action_buttons)
        Array(resource.custom_action_buttons).collect(&:name).collect(&:downcase)
      end

      def validate_attr_selection(resource)
        physical_attrs, virtual_attrs = [], []
        attrs = attribute_selection
        return [physical_attrs, virtual_attrs] if resource.kind_of?(Hash) || attrs == 'all'

        attrs.each do |attr|
          if attr_physical?(resource, attr) || attr == 'actions'
            physical_attrs.push(attr)
          elsif attr_virtual?(resource, attr) || @additional_attributes.try(:include?, attr)
            virtual_attrs.push(attr)
          end
        end

        attrs = attrs - physical_attrs - virtual_attrs
        raise BadRequestError, "Invalid attributes specified: #{attrs.join(',')}" unless attrs.empty?

        [(physical_attrs - ID_ATTRS).empty? ? [] : physical_attrs, virtual_attrs]
      end

      #
      # Let's expand a subcollection
      #
      def expand_subcollection(json, sc, sctype, subresources)
        if collection_config.show_as_collection?(sc)
          copts = {
            :count            => subresources.length,
            :is_subcollection => true,
            :expand_resources => @req.expand?(sc)
          }
          json.set! sc.to_s, collection_to_jbuilder(sc.to_sym, sctype, subresources, copts)
        else
          json.set! sc.to_s do |js|
            subresources.each do |scr|
              if @req.expand?(sc) || scr["id"].nil?
                add_child js, normalize_hash(sctype, scr)
              else
                js.child! { |jsc| jsc.href normalize_href(sctype, scr["id"]) }
              end
            end
          end
        end
      end

      def gen_action_spec_for_collections(collection, cspec, is_subcollection, href)
        if is_subcollection
          target = :subcollection_actions
          cspec_target = cspec[target] || collection_config.typed_subcollection_actions(@req.collection, collection)
        else
          target = :collection_actions
          cspec_target = cspec[target]
        end
        return [] unless cspec_target
        cspec_target.each.collect do |method, action_definitions|
          next unless render_actions_for_method(cspec[:verbs], method)
          typed_action_definitions = fetch_typed_subcollection_actions(method, is_subcollection) || action_definitions
          typed_action_definitions.each.collect do |action|
            if !action[:disabled] && api_user_role_allows?(action[:identifier])
              {"name" => action[:name], "method" => method, "href" => (href ? href : collection)}
            end
          end
        end.flatten.compact
      end

      def gen_action_spec_for_resources(cspec, is_subcollection, href, resource)
        if is_subcollection
          target = :subresource_actions
          cspec_target = cspec[target] || collection_config.typed_subcollection_actions(@req.collection, @req.subcollection, :subresource)
        else
          target = :resource_actions
          cspec_target = cspec[target]
        end
        return [] unless cspec_target
        cspec_target.each.collect do |method, action_definitions|
          next unless render_actions_for_method(cspec[:verbs], method)
          typed_action_definitions = action_definitions || fetch_typed_subcollection_actions(method, is_subcollection)
          typed_action_definitions.each.collect do |action|
            if !action[:disabled] && api_user_role_allows?(action[:identifier]) && action_validated?(resource, action)
              {"name" => action[:name], "method" => method, "href" => href}
            end
          end
        end.flatten.compact
      end

      def render_actions_for_method(methods, method)
        method != :get && methods.include?(method)
      end

      def fetch_typed_subcollection_actions(method, is_subcollection)
        return unless is_subcollection
        collection_config.typed_subcollection_action(@req.collection, @req.subcollection, method)
      end

      def api_user_role_allows?(action_identifier)
        return true unless action_identifier
        Array(action_identifier).any? { |identifier| User.current_user.role_allows?(:identifier => identifier) }
      end

      def render_actions(physical_attrs)
        render_attr("actions") || physical_attrs.blank?
      end

      def action_validated?(resource, action_spec)
        if action_spec[:options] && action_spec[:options].include?(:validate_action)
          validate_method = "validate_#{action_spec[:name]}"
          return resource.respond_to?(validate_method) && resource.send(validate_method)
        end
        true
      end

      def render_options(resource, data = {})
        klass = collection_class(resource)
        render :json => OptionsSerializer.new(klass, data).serialize
      end
    end
  end
end
