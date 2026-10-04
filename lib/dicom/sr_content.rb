module DICOM

  # The SRContent module provides an editable content tree view of the
  # Content Sequence (0040,A730) of a DICOM Structured Report (SR) document.
  #
  # The tree wraps the content items of an SR document in Node instances which
  # expose the common value types (TEXT, CODE, NUM, IMAGE and SCOORD) as well
  # as the Relationship Type (0040,A010) of each content item. Content items
  # with a by-reference relationship are resolved through their content item
  # path (Referenced Content Item Identifier (0040,DB73)).
  #
  # Structural edits (insert, move, delete) automatically rebind the content
  # item paths of all by-reference relationships that still have a valid
  # target. Deleting content that is still the target of a by-reference
  # relationship is refused by default, unless the caller explicitly selects
  # a cleanup policy.
  #
  # @example Build a small SR content tree
  #   dcm = DICOM::DObject.new
  #   tree = DICOM::SRContent::Tree.new(dcm)
  #   report = tree.insert(nil, :value_type => 'CONTAINER', :continuity => 'SEPARATE')
  #   finding = tree.insert(report, :value_type => 'TEXT', :relationship_type => 'CONTAINS', :text => 'Mass')
  #   measure = tree.insert(report, :value_type => 'NUM', :relationship_type => 'CONTAINS', :numeric_value => 12.5)
  #   reference = tree.insert(finding, :relationship_type => 'by-reference', :target => measure)
  #   reference.target == measure # => true
  #
  module SRContent

    # Tag of the Content Sequence which holds the SR content items.
    CONTENT_SEQUENCE_TAG = '0040,A730'
    # Tag of the Relationship Type element.
    RELATIONSHIP_TYPE_TAG = '0040,A010'
    # Tag of the Value Type element.
    VALUE_TYPE_TAG = '0040,A040'
    # Tag of the Concept Name Code Sequence.
    CONCEPT_NAME_CODE_TAG = '0040,A043'
    # Tag of the Continuity Of Content element (CONTAINER value type).
    CONTINUITY_OF_CONTENT_TAG = '0040,A050'
    # Tag of the Text Value element (TEXT value type).
    TEXT_VALUE_TAG = '0040,A160'
    # Tag of the Concept Code Sequence (CODE value type).
    CONCEPT_CODE_TAG = '0040,A168'
    # Tag of the Measured Value Sequence (NUM value type).
    MEASURED_VALUE_TAG = '0040,A300'
    # Tag of the Numeric Value element (inside the Measured Value Sequence).
    NUMERIC_VALUE_TAG = '0040,A30A'
    # Tag of the Measurement Units Code Sequence (inside the Measured Value Sequence).
    MEASUREMENT_UNITS_CODE_TAG = '0040,08EA'
    # Tag of the Referenced SOP Sequence (IMAGE value type).
    REFERENCED_SOP_SEQUENCE_TAG = '0008,1199'
    # Tag of the Referenced SOP Class UID element.
    REFERENCED_SOP_CLASS_UID_TAG = '0008,1150'
    # Tag of the Referenced SOP Instance UID element.
    REFERENCED_SOP_INSTANCE_UID_TAG = '0008,1155'
    # Tag of the Graphic Data element (SCOORD value type).
    GRAPHIC_DATA_TAG = '0070,0022'
    # Tag of the Graphic Type element (SCOORD value type).
    GRAPHIC_TYPE_TAG = '0070,0023'
    # Tag of the Referenced Content Item Identifier element (by-reference relationships).
    REFERENCED_CONTENT_ITEM_TAG = '0040,DB73'
    # Tag of the Code Value element (inside code sequence items).
    CODE_VALUE_TAG = '0008,0100'
    # Tag of the Coding Scheme Designator element (inside code sequence items).
    CODING_SCHEME_DESIGNATOR_TAG = '0008,0102'
    # Tag of the Code Meaning element (inside code sequence items).
    CODE_MEANING_TAG = '0008,0104'

    # Relationship type used by content items that reference another content item.
    BY_REFERENCE = 'by-reference'

    # Raised when a delete operation is refused because the content is still
    # targeted by one or more by-reference relationships.
    class ReferencedContentError < StandardError; end

    # Raised when a structural edit would be invalid (e.g. moving a node into
    # its own subtree, or referencing a target outside the tree).
    class InvalidEditError < StandardError; end

    # The Tree class wraps the Content Sequence of an SR document and exposes
    # it as an editable tree of Node instances. All structural edits are
    # applied directly to the underlying DObject, and by-reference
    # relationships are automatically rebound to their (possibly moved)
    # targets after every edit.
    #
    class Tree

      # The DObject whose Content Sequence is wrapped by this tree.
      attr_reader :dcm

      # Creates a content tree for the given DICOM object.
      #
      # @param [DObject] dcm a DICOM object (typically an SR document)
      # @return [Tree] the initialized Tree instance
      #
      def initialize(dcm)
        raise ArgumentError, "Expected a DICOM::DObject, got #{dcm.class}" unless dcm.is_a?(DObject)
        @dcm = dcm
      end

      # The root level content items of the SR document.
      #
      # @return [Array<Node>] the root nodes (empty array if there is no Content Sequence)
      #
      def roots
        seq = @dcm[CONTENT_SEQUENCE_TAG]
        seq ? seq.items.map { |item| Node.new(self, item) } : []
      end

      # All nodes of the tree, enumerated depth-first (pre-order).
      #
      # @return [Array<Node>] all content item nodes of the tree
      #
      def nodes
        collected = []
        walk = lambda do |node|
          collected << node
          node.children.each { |child| walk.call(child) }
        end
        roots.each { |root| walk.call(root) }
        collected
      end

      # Retrieves the node at the given content item path.
      #
      # @param [Array<Integer>, String] path a path of 1-based positions, e.g. [2, 1] or "2.1"
      # @return [Node, NilClass] the node at the given path (nil if the path doesn't resolve)
      #
      def [](path)
        positions = path.is_a?(String) ? path.split('.').map { |p| p.to_i } : path
        seq = @dcm[CONTENT_SEQUENCE_TAG]
        item = nil
        positions.each do |position|
          return nil unless seq && position >= 1
          item = seq.items[position - 1]
          return nil unless item
          seq = item[CONTENT_SEQUENCE_TAG]
        end
        item ? Node.new(self, item) : nil
      end

      # Inserts a new content item as a child of the given parent node
      # (or as a root node when parent is nil).
      #
      # After the insertion, all by-reference relationships whose targets are
      # still valid are rebound to the updated content item paths.
      #
      # @param [Node, NilClass] parent the parent node (nil for root level insertion)
      # @param [Hash] attributes content item attributes
      # @option attributes [String] :value_type the Value Type (e.g. 'TEXT', 'CODE', 'NUM', 'IMAGE', 'SCOORD', 'CONTAINER')
      # @option attributes [String] :relationship_type the Relationship Type (e.g. 'CONTAINS', 'by-reference')
      # @option attributes [Hash] :concept_name a code hash (:code_value, :coding_scheme_designator, :code_meaning)
      # @option attributes [String] :text the Text Value (TEXT)
      # @option attributes [Hash] :code a code hash (CODE)
      # @option attributes [Numeric] :numeric_value the Numeric Value (NUM)
      # @option attributes [Hash] :unit a code hash for the measurement units (NUM)
      # @option attributes [Hash] :referenced_sop a hash with :sop_class_uid and :sop_instance_uid (IMAGE)
      # @option attributes [String] :graphic_type the Graphic Type (SCOORD)
      # @option attributes [Array<Numeric>] :graphic_data the Graphic Data coordinates (SCOORD)
      # @option attributes [String] :continuity the Continuity Of Content (CONTAINER)
      # @option attributes [Node, Array, String] :target the target of a by-reference relationship
      # @param [Hash] options the options used for the insertion
      # @option options [Integer] :index the position (0-based) among the parent's children at which to insert
      # @return [Node] the newly created node
      #
      def insert(parent, attributes={}, options={})
        parent = coerce_node(parent) if parent
        references = snapshot_references
        sequence = ensure_content_sequence(parent)
        item = Item.new
        options[:index] ? sequence.add_item(item, :index => options[:index]) : sequence.add_item(item)
        node = Node.new(self, item)
        node.send(:apply, attributes)
        rebind!(references)
        if attributes[:target]
          target_item = resolve_target_item(attributes[:target])
          node.send(:reference_path=, path_of(target_item))
        end
        node
      end

      # Moves a node (with its subtree) to a new parent (or to the root level
      # when parent is nil).
      #
      # After the move, all by-reference relationships whose targets are still
      # valid are rebound to the updated content item paths.
      #
      # @param [Node] node the node to move
      # @param [Hash] options the options used for the move
      # @option options [Node, NilClass] :parent the new parent node (nil for root level)
      # @option options [Integer] :index the position (0-based) among the new parent's children
      # @return [Node] the moved node
      #
      def move(node, options={})
        node = coerce_node(node)
        parent = options[:parent] ? coerce_node(options[:parent]) : nil
        if parent && subtree_items(node).include?(parent.item)
          raise InvalidEditError, "A node cannot be moved into its own subtree."
        end
        references = snapshot_references
        detach(node.item)
        sequence = ensure_content_sequence(parent)
        options[:index] ? sequence.add_item(node.item, :index => options[:index]) : sequence.add_item(node.item)
        rebind!(references)
        node
      end

      # Deletes a node (with its subtree) from the tree.
      #
      # If content outside the deleted subtree still references content inside
      # it, the deletion is refused (policy :strict, the default) or the
      # dangling by-reference content items are removed as well (policy
      # :prune), as specified by the caller.
      #
      # @param [Node] node the node to delete
      # @param [Hash] options the options used for the deletion
      # @option options [Symbol] :policy :strict (refuse, raising ReferencedContentError) or :prune (also remove referencing content items)
      # @return [Node] the deleted (now detached) node
      #
      def delete(node, options={})
        policy = options[:policy] || :strict
        raise ArgumentError, "Unknown deletion policy: #{policy.inspect} (valid policies are :strict and :prune)" unless [:strict, :prune].include?(policy)
        node = coerce_node(node)
        references = snapshot_references
        doomed = subtree_items(node)
        external_references = references.select do |reference_node, target_item|
          target_item && doomed.include?(target_item) && !doomed.include?(reference_node.item)
        end
        if external_references.any?
          if policy == :strict
            referrers = external_references.keys.map { |reference_node| reference_node.path.join('.') }
            raise ReferencedContentError, "Deletion refused: content item(s) at #{node.path.join('.')} are still referenced by by-reference content item(s) at #{referrers.join(', ')}. Delete with :policy => :prune to remove the referencing content items as well."
          end
        end
        detach(node.item)
        external_references.each_key { |reference_node| detach(reference_node.item) }
        rebind!(references)
        node
      end

      # Rebinds all by-reference relationships of the tree to the current
      # content item paths of their targets.
      #
      # References whose target can no longer be resolved are left untouched.
      #
      # @return [Tree] self
      #
      def rebind!(references=nil)
        references ||= snapshot_references
        references.each do |reference_node, target_item|
          next unless target_item
          next unless in_tree?(reference_node.item)
          new_path = path_of(target_item)
          reference_node.send(:reference_path=, new_path) if new_path
        end
        self
      end

      # Computes the content item path (1-based positions, from the root
      # Content Sequence) of the given item.
      #
      # @param [Item] item a content item
      # @return [Array<Integer>, NilClass] the content item path (nil if the item is not part of this tree)
      #
      def path_of(item)
        positions = []
        current = item
        while current.is_a?(Item)
          parent = current.parent
          return nil unless parent.is_a?(Sequence)
          positions.unshift(current.index + 1)
          current = parent.parent
        end
        current.equal?(@dcm) ? positions : nil
      end


      private


      # Converts the argument to a Node, raising an informative error otherwise.
      def coerce_node(node)
        return node if node.is_a?(Node)
        raise ArgumentError, "Expected a DICOM::SRContent::Node, got #{node.class}"
      end

      # Returns (creating if necessary) the Content Sequence of the given
      # parent node (or of the DObject when parent is nil).
      def ensure_content_sequence(parent)
        holder = parent ? parent.item : @dcm
        sequence = holder[CONTENT_SEQUENCE_TAG]
        sequence ||= Sequence.new(CONTENT_SEQUENCE_TAG, :parent => holder)
        sequence
      end

      # Removes the given item from its parent sequence and compacts the
      # indices of the remaining items.
      def detach(item)
        sequence = item.parent
        raise InvalidEditError, "The content item is not part of a Content Sequence." unless sequence.is_a?(Sequence)
        sequence.delete(item.index)
        compact(sequence)
      end

      # Renumbers the items of a sequence so that their indices are
      # consecutive (0-based), preserving their order.
      def compact(sequence)
        items = sequence.items
        items.each { |item| sequence.delete(item.index, :no_follow => true) }
        items.each { |item| sequence.add_item(item) }
      end

      # Checks if the given item is currently connected to this tree's DObject.
      def in_tree?(item)
        item.top_parent.equal?(@dcm)
      end

      # Returns all items of the subtree rooted at the given node (including
      # the node's own item).
      def subtree_items(node)
        items = [node.item]
        node.children.each do |child|
          items.concat(subtree_items(child))
        end
        items
      end

      # Captures the current by-reference relationships of the tree as a map
      # from reference node to target item (nil target if unresolvable).
      def snapshot_references
        references = {}
        nodes.each do |node|
          if node.by_reference?
            target = node.reference_path ? self[node.reference_path] : nil
            references[node] = target ? target.item : nil
          end
        end
        references
      end

      # Resolves a target specification (Node, path array or path string) to
      # a content item of this tree.
      def resolve_target_item(target)
        node = target.is_a?(Node) ? target : self[target]
        raise InvalidEditError, "The by-reference target #{target.inspect} does not resolve to a content item of this tree." unless node
        node.item
      end

    end

    # The Node class wraps a single SR content item and gives convenient
    # access to its value (TEXT, CODE, NUM, IMAGE or SCOORD), its
    # Relationship Type, its children and, for by-reference relationships,
    # its referenced target node.
    #
    class Node

      # The Tree this node belongs to.
      attr_reader :tree
      # The underlying DICOM Item of this content item.
      attr_reader :item

      # Creates a Node wrapper for the given content item.
      #
      # @param [Tree] tree the content tree the item belongs to
      # @param [Item] item a content item of the SR Content Sequence
      #
      def initialize(tree, item)
        @tree = tree
        @item = item
      end

      # Checks for equality. Two nodes are equal if they wrap the same
      # underlying content item.
      #
      # @param other an object to be compared with self
      # @return [Boolean] true if both nodes wrap the same content item
      #
      def ==(other)
        other.is_a?(Node) && other.item.equal?(item)
      end

      alias_method :eql?, :==

      # Computes a hash code for this object.
      #
      # @return [Integer] the object's hash code
      #
      def hash
        item.object_id
      end

      # The Value Type (0040,A040) of the content item (e.g. 'TEXT', 'NUM').
      #
      # @return [String, NilClass] the value type
      #
      def value_type
        element_value(VALUE_TYPE_TAG)
      end

      # Sets the Value Type (0040,A040) of the content item.
      def value_type=(type)
        set_element(VALUE_TYPE_TAG, type)
      end

      # The Relationship Type (0040,A010) of the content item (e.g.
      # 'CONTAINS', 'INFERRED FROM', 'by-reference').
      #
      # @return [String, NilClass] the relationship type
      #
      def relationship_type
        element_value(RELATIONSHIP_TYPE_TAG)
      end

      # Sets the Relationship Type (0040,A010) of the content item.
      def relationship_type=(type)
        set_element(RELATIONSHIP_TYPE_TAG, type)
      end

      # The Concept Name of the content item, as a code hash.
      #
      # @return [Hash, NilClass] hash with :code_value, :coding_scheme_designator and :code_meaning
      #
      def concept_name
        read_code(CONCEPT_NAME_CODE_TAG)
      end

      # Sets the Concept Name Code Sequence (0040,A043) of the content item.
      def concept_name=(code)
        write_code(CONCEPT_NAME_CODE_TAG, code)
      end

      # The Continuity Of Content (0040,A050) of a CONTAINER content item.
      #
      # @return [String, NilClass] the continuity ('SEPARATE' or 'CONTINUOUS')
      #
      def continuity
        element_value(CONTINUITY_OF_CONTENT_TAG)
      end

      # Sets the Continuity Of Content (0040,A050) of a CONTAINER content item.
      def continuity=(value)
        set_element(CONTINUITY_OF_CONTENT_TAG, value)
      end

      # The Text Value (0040,A160) of a TEXT content item.
      #
      # @return [String, NilClass] the text value
      #
      def text
        element_value(TEXT_VALUE_TAG)
      end

      # Sets the Text Value (0040,A160) of a TEXT content item.
      def text=(value)
        set_element(TEXT_VALUE_TAG, value)
      end

      # The Concept Code of a CODE content item, as a code hash.
      #
      # @return [Hash, NilClass] hash with :code_value, :coding_scheme_designator and :code_meaning
      #
      def code
        read_code(CONCEPT_CODE_TAG)
      end

      # Sets the Concept Code Sequence (0040,A168) of a CODE content item.
      def code=(code)
        write_code(CONCEPT_CODE_TAG, code)
      end

      # The Numeric Value (0040,A30A) of a NUM content item.
      #
      # @return [Float, Array<Float>, NilClass] the numeric value(s)
      #
      def numeric_value
        measured = measured_value_item
        return nil unless measured
        values = multi_value(measured.value(NUMERIC_VALUE_TAG))
        return nil unless values
        numbers = values.map { |v| v.to_f }
        numbers.length == 1 ? numbers.first : numbers
      end

      # Sets the Numeric Value (0040,A30A) of a NUM content item.
      def numeric_value=(number)
        set_on_item(ensure_measured_value_item, NUMERIC_VALUE_TAG, number)
      end

      # The Measurement Units of a NUM content item, as a code hash.
      #
      # @return [Hash, NilClass] hash with :code_value, :coding_scheme_designator and :code_meaning
      #
      def unit
        measured = measured_value_item
        measured ? read_code_from(measured, MEASUREMENT_UNITS_CODE_TAG) : nil
      end

      # Sets the Measurement Units Code Sequence (0040,08EA) of a NUM content item.
      def unit=(code)
        write_code_to(ensure_measured_value_item, MEASUREMENT_UNITS_CODE_TAG, code)
      end

      # The referenced SOP instance of an IMAGE content item.
      #
      # @return [Hash, NilClass] hash with :sop_class_uid and :sop_instance_uid
      #
      def referenced_sop
        sequence = item[REFERENCED_SOP_SEQUENCE_TAG]
        referenced = sequence && sequence.items.first
        return nil unless referenced
        {
          :sop_class_uid => referenced.value(REFERENCED_SOP_CLASS_UID_TAG),
          :sop_instance_uid => referenced.value(REFERENCED_SOP_INSTANCE_UID_TAG)
        }
      end

      # Sets the Referenced SOP Sequence (0008,1199) of an IMAGE content item.
      def referenced_sop=(sop)
        if sop.nil?
          item.delete(REFERENCED_SOP_SEQUENCE_TAG) if item.exists?(REFERENCED_SOP_SEQUENCE_TAG)
          return
        end
        sequence = item[REFERENCED_SOP_SEQUENCE_TAG] || Sequence.new(REFERENCED_SOP_SEQUENCE_TAG, :parent => item)
        referenced = sequence.items.first || sequence.add_item
        set_on_item(referenced, REFERENCED_SOP_CLASS_UID_TAG, sop[:sop_class_uid])
        set_on_item(referenced, REFERENCED_SOP_INSTANCE_UID_TAG, sop[:sop_instance_uid])
      end

      # The Graphic Type (0070,0023) of a SCOORD content item.
      #
      # @return [String, NilClass] the graphic type (e.g. 'POINT', 'POLYLINE')
      #
      def graphic_type
        element_value(GRAPHIC_TYPE_TAG)
      end

      # Sets the Graphic Type (0070,0023) of a SCOORD content item.
      def graphic_type=(type)
        set_element(GRAPHIC_TYPE_TAG, type)
      end

      # The Graphic Data (0070,0022) of a SCOORD content item.
      #
      # @return [Array<Float>, NilClass] the spatial coordinates
      #
      def graphic_data
        values = multi_value(element_value(GRAPHIC_DATA_TAG))
        values && values.map { |v| v.to_f }
      end

      # Sets the Graphic Data (0070,0022) of a SCOORD content item.
      def graphic_data=(coordinates)
        set_element(GRAPHIC_DATA_TAG, coordinates && coordinates.map { |c| c.to_f })
      end

      # The value of the content item, dispatched on its Value Type.
      #
      # @return [String, Hash, Array, NilClass] the content item's value
      #
      def value
        case value_type
        when 'TEXT' then text
        when 'CODE' then code
        when 'NUM' then { :value => numeric_value, :unit => unit }
        when 'IMAGE' then referenced_sop
        when 'SCOORD' then { :graphic_type => graphic_type, :graphic_data => graphic_data }
        end
      end

      # The child content items of this node.
      #
      # @return [Array<Node>] the child nodes (empty array if childless)
      #
      def children
        sequence = item[CONTENT_SEQUENCE_TAG]
        sequence ? sequence.items.map { |child_item| Node.new(tree, child_item) } : []
      end

      # The parent node of this node (nil for root level nodes).
      #
      # @return [Node, NilClass] the parent node
      #
      def parent
        sequence = item.parent
        return nil unless sequence.is_a?(Sequence)
        parent_item = sequence.parent
        parent_item.is_a?(Item) ? Node.new(tree, parent_item) : nil
      end

      # The content item path of this node (1-based positions from the root
      # Content Sequence), as used by by-reference relationships.
      #
      # @return [Array<Integer>, NilClass] the content item path
      #
      def path
        tree.path_of(item)
      end

      # Checks if this content item has a by-reference relationship to
      # another content item.
      #
      # @return [Boolean] true if the node is a by-reference content item
      #
      def by_reference?
        relationship_type.to_s.downcase == BY_REFERENCE || item.exists?(REFERENCED_CONTENT_ITEM_TAG)
      end

      # The content item path that a by-reference content item points to
      # (Referenced Content Item Identifier (0040,DB73)).
      #
      # @return [Array<Integer>, NilClass] the referenced content item path
      #
      def reference_path
        values = multi_value(element_value(REFERENCED_CONTENT_ITEM_TAG))
        values && values.map { |v| v.to_i }
      end

      # The node targeted by a by-reference content item.
      #
      # @return [Node, NilClass] the referenced target node (nil if unresolvable)
      #
      def target
        path = reference_path
        path ? tree[path] : nil
      end

      # Inserts a new child content item below this node.
      #
      # @param [Hash] attributes content item attributes (see Tree#insert)
      # @param [Hash] options insertion options (see Tree#insert)
      # @return [Node] the newly created node
      #
      def add_child(attributes={}, options={})
        tree.insert(self, attributes, options)
      end

      # Deletes this node (with its subtree) from the tree.
      #
      # @param [Hash] options deletion options (see Tree#delete)
      # @return [Node] the deleted (now detached) node
      #
      def delete(options={})
        tree.delete(self, options)
      end

      # Returns a short, informative string representation of the node.
      #
      # @return [String] a string describing the node
      #
      def inspect
        type = by_reference? ? BY_REFERENCE : value_type
        "#<#{self.class} #{type || 'unknown'} path=#{path ? path.join('.') : 'detached'}>"
      end

      alias_method :to_s, :inspect


      private


      # Applies a hash of content item attributes to this node (used when
      # creating new content items).
      def apply(attributes)
        attributes.each_pair do |key, value|
          case key
          when :value_type then self.value_type = value
          when :relationship_type then self.relationship_type = value
          when :concept_name then self.concept_name = value
          when :continuity then self.continuity = value
          when :text then self.text = value
          when :code then self.code = value
          when :numeric_value then self.numeric_value = value
          when :unit then self.unit = value
          when :referenced_sop then self.referenced_sop = value
          when :graphic_type then self.graphic_type = value
          when :graphic_data then self.graphic_data = value
          when :target then # handled by the tree, after references have been rebound
          else
            raise ArgumentError, "Unknown content item attribute: #{key.inspect}"
          end
        end
      end

      # Reads the value of a child element of the content item.
      def element_value(tag)
        item.value(tag)
      end

      # Normalizes a (possibly multi-valued) element value to an array.
      # Handles the backslash-separated string representation that the
      # library produces for multi-valued elements read from a binary source.
      def multi_value(value)
        case value
        when nil then nil
        when Array then value
        when String then value.split("\\")
        else [value]
        end
      end

      # Creates or updates a child element of the content item.
      def set_element(tag, value)
        set_on_item(item, tag, value)
      end

      # Creates or updates a child element of the given parent item.
      def set_on_item(parent_item, tag, value)
        if value.nil?
          parent_item.delete(tag) if parent_item.exists?(tag)
        elsif parent_item.exists?(tag)
          parent_item[tag].value = value
        else
          Element.new(tag, value, :parent => parent_item)
        end
      end

      # Sets the Referenced Content Item Identifier (0040,DB73) of a
      # by-reference content item.
      def reference_path=(path)
        set_element(REFERENCED_CONTENT_ITEM_TAG, path && path.map { |position| position.to_i })
      end

      # Reads a code (Code Value, Coding Scheme Designator, Code Meaning)
      # from the first item of the given sequence of the content item.
      def read_code(sequence_tag)
        read_code_from(item, sequence_tag)
      end

      # Reads a code from the first item of the given sequence of the given
      # parent item.
      def read_code_from(parent_item, sequence_tag)
        sequence = parent_item[sequence_tag]
        code_item = sequence && sequence.items.first
        return nil unless code_item
        {
          :code_value => code_item.value(CODE_VALUE_TAG),
          :coding_scheme_designator => code_item.value(CODING_SCHEME_DESIGNATOR_TAG),
          :code_meaning => code_item.value(CODE_MEANING_TAG)
        }
      end

      # Writes a code hash to the first item of the given sequence of the
      # content item.
      def write_code(sequence_tag, code)
        write_code_to(item, sequence_tag, code)
      end

      # Writes a code hash to the first item of the given sequence of the
      # given parent item.
      def write_code_to(parent_item, sequence_tag, code)
        if code.nil?
          parent_item.delete(sequence_tag) if parent_item.exists?(sequence_tag)
          return
        end
        sequence = parent_item[sequence_tag] || Sequence.new(sequence_tag, :parent => parent_item)
        code_item = sequence.items.first || sequence.add_item
        set_on_item(code_item, CODE_VALUE_TAG, code[:code_value])
        set_on_item(code_item, CODING_SCHEME_DESIGNATOR_TAG, code[:coding_scheme_designator])
        set_on_item(code_item, CODE_MEANING_TAG, code[:code_meaning])
      end

      # Returns the first item of the Measured Value Sequence, if present.
      def measured_value_item
        sequence = item[MEASURED_VALUE_TAG]
        sequence && sequence.items.first
      end

      # Returns (creating if necessary) the first item of the Measured Value
      # Sequence of the content item.
      def ensure_measured_value_item
        measured_value_item || begin
          sequence = Sequence.new(MEASURED_VALUE_TAG, :parent => item)
          sequence.add_item
        end
      end

    end

  end
end
