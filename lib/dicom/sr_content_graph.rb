module DICOM

  class SRReferenceError < StandardError; end

  class SRContentGraph

    CONTENT_SEQUENCE_TAG = "0040,A730"
    RELATIONSHIP_TYPE_TAG = "0040,A010"
    VALUE_TYPE_TAG = "0040,A040"
    CONCEPT_NAME_TAG = "0040,A043"
    TEXT_VALUE_TAG = "0040,A160"
    CONCEPT_CODE_TAG = "0040,A168"
    MEASURED_VALUE_TAG = "0040,A300"
    NUMERIC_VALUE_TAG = "0040,A30A"
    MEASUREMENT_UNITS_TAG = "0040,08EA"
    NUMERIC_QUALIFIER_TAG = "0040,A301"
    REFERENCED_SOP_TAG = "0008,1199"
    REFERENCED_SOP_CLASS_TAG = "0008,1150"
    REFERENCED_SOP_INSTANCE_TAG = "0008,1155"
    REFERENCED_FRAME_TAG = "0008,1160"
    PURPOSE_OF_REFERENCE_TAG = "0040,A170"
    GRAPHIC_TYPE_TAG = "0070,0023"
    GRAPHIC_DATA_TAG = "0070,0022"
    REFERENCE_PATH_TAG = "0040,DB73"

    KNOWN_VALUE_TAGS = [
      TEXT_VALUE_TAG, CONCEPT_CODE_TAG, MEASURED_VALUE_TAG,
      REFERENCED_SOP_TAG, PURPOSE_OF_REFERENCE_TAG,
      GRAPHIC_TYPE_TAG, GRAPHIC_DATA_TAG
    ].freeze

    attr_reader :object

    def initialize(object)
      unless object.is_a?(DObject) || object.is_a?(Item) || object.is_a?(Sequence)
        raise ArgumentError, "Expected DObject, Item or Sequence, got #{object.class}."
      end
      if object.is_a?(Sequence) && object.tag != CONTENT_SEQUENCE_TAG
        raise ArgumentError, "Expected a Content Sequence (#{CONTENT_SEQUENCE_TAG}), got #{object.tag}."
      end
      @object = object
    end

    def content_sequence(options = {})
      sequence = if @object.is_a?(Sequence)
        @object
      elsif @object.is_a?(DObject)
        @object[CONTENT_SEQUENCE_TAG]
      elsif @object.is_a?(Item)
        @object[CONTENT_SEQUENCE_TAG]
      end
      if sequence.nil? && options[:create]
        sequence = if @object.is_a?(DObject) || @object.is_a?(Item)
          Sequence.new(CONTENT_SEQUENCE_TAG, :parent => @object)
        else
          @object
        end
      end
      sequence
    end

    def roots
      sequence = content_sequence
      sequence ? sequence.items.map { |item| SRContentNode.new(item, self) } : []
    end

    def each_node
      return enum_for(:each_node) unless block_given?
      walk_content(content_sequence) do |item, path|
        yield SRContentNode.new(item, self), path
      end
    end

    def find(path)
      item, parent_item = item_at(normalize_path(path))
      item ? SRContentNode.new(item, self) : nil
    end

    def parent_node(item)
      parent_item = parent_item(item)
      parent_item ? SRContentNode.new(parent_item, self) : nil
    end

    def children(item)
      sequence = item[CONTENT_SEQUENCE_TAG]
      sequence ? sequence.items.map { |child| SRContentNode.new(child, self) } : []
    end

    def insert(attributes, parent: nil, index: nil)
      attributes = normalize_attributes(attributes)
      parent_sequence = insertion_sequence(parent)
      index = normalize_insert_index(index, parent_sequence.items.length)
      captured = capture_item_paths
      inserted_items = []
      item = build_item(attributes, parent_sequence, inserted_items)
      remove_item(item)
      parent_sequence.add_item(item, :index => index)
      new_paths = capture_item_paths
      remap_references(captured, new_paths, inserted_items)
      rebind_inserted_references(inserted_items, captured, new_paths)
      validate_references
      SRContentNode.new(item, self)
    rescue
      remove_item(item) if item
      raise
    end

    def append_child(attributes, parent: nil)
      insert(attributes, :parent => parent, :index => -1)
    end

    def move(source, destination: nil, index: -1)
      source_item = locate_item(source)
      destination_sequence = insertion_sequence(destination)
      same_parent = source_item.parent.equal?(destination_sequence)
      raise ArgumentError, "Cannot move a content item into its own subtree." if descendant_destination?(source_item, destination_sequence)
      original_index = source_item.index if same_parent
      if index == -1
        target_index = destination_sequence.items.length - (same_parent ? 1 : 0)
      else
        target_index = normalize_insert_index(index, destination_sequence.items.length - (same_parent ? 1 : 0))
        target_index -= 1 if same_parent && original_index && original_index < target_index
      end
      captured = capture_item_paths
      remove_item(source_item)
      destination_sequence.add_item(source_item, :index => target_index)
      remap_references(captured, capture_item_paths)
      validate_references
      SRContentNode.new(source_item, self)
    end

    def delete(source, strategy: :reject)
      item = locate_item(source)
      target_subtree = subtree_items(item)
      referrers = external_referrers(target_subtree)
      case strategy.to_sym
      when :reject, :raise, :refuse, :error
        if referrers.any?
          paths = referrers.map { |referrer| path_for(referrer).join(".") }.sort
          raise SRReferenceError, "Cannot delete #{path_for(item).join(".")}: referenced by #{paths.join(", ")}."
        end
      when :nullify, :clear_references, :detach, :unlink
        referrers.each { |referrer| referrer.delete(REFERENCE_PATH_TAG) }
      when :cascade, :remove_referrers, :remove_references, :delete_referrers
        deletion_roots = referrers.map { |referrer| root_item(referrer) }.uniq
        deletion_roots.each { |root| remove_item(root) }
      else
        raise ArgumentError, "Unknown reference cleanup strategy: #{strategy}."
      end
      captured = capture_item_paths
      remove_item(item)
      cleanup_empty_content_sequences
      remap_references(captured, capture_item_paths)
      true
    end

    def to_a
      roots.map(&:to_h)
    end

    def path_for(item)
      path = []
      current = item
      while current.is_a?(Item)
        parent = current.parent
        break unless parent.is_a?(Sequence)
        path.unshift(current.index.to_i + 1)
        current = parent.parent
      end
      path
    end

    def reference_path(item)
      element = item[REFERENCE_PATH_TAG]
      return nil unless element
      stream = Stream.new(element.bin, item.stream.str_endian)
      values = stream.decode(element.bin.length, "UL")
      values = Array(values)
      values.empty? ? nil : values
    end

    def referenced_item(item)
      path = reference_path(item)
      path && item_at(path).first
    end

    def update_item(item, attributes)
      attributes = normalize_attributes(attributes)
      write_attributes(item, attributes)
      validate_references
      SRContentNode.new(item, self)
    end

    def value_for(item)
      return nil if reference_path(item)
      case item.value(VALUE_TYPE_TAG)
      when "TEXT" then item.value(TEXT_VALUE_TAG)
      when "CODE" then read_code(item[CONCEPT_CODE_TAG])
      when "NUM" then read_numeric(item)
      when "IMAGE" then read_image_reference(item[REFERENCED_SOP_TAG])
      when "SCOORD" then read_scoord(item)
      end
    end

    private

    def normalize_attributes(attributes)
      raise ArgumentError, "Expected Hash, got #{attributes.class}." unless attributes.is_a?(Hash)
      normalized = {}
      attributes.each do |key, value|
        normalized[key.to_s.tr("-", "_").to_sym] = value
      end
      normalized[:value_type] = normalized.delete(:type) if normalized.key?(:type)
      normalized[:value_type] = normalized[:value_type].to_s.upcase if normalized[:value_type]
      normalized[:relationship_type] = normalized.delete(:relationship) if normalized.key?(:relationship)
      normalized[:relationship_type] = normalized.delete(:relationship_type_name) if normalized.key?(:relationship_type_name)
      normalized[:relationship_type] = normalized[:relationship_type].to_s.upcase if normalized[:relationship_type]
      normalized[:reference_path] = normalize_path(normalized[:reference_path]) if normalized.key?(:reference_path) && normalized[:reference_path]
      normalized
    end

    def normalize_path(path)
      values = case path
      when Array then path
      when String then path.split(/[.\/]/)
      else
        raise ArgumentError, "Expected content item path, got #{path.class}."
      end
      values.map do |value|
        integer = Integer(value)
        raise ArgumentError, "Content item path components must be positive integers: #{path.inspect}." unless integer > 0
        integer
      end
    end

    def normalize_insert_index(index, length)
      return length if index.nil? || index == -1
      raise ArgumentError, "Expected Integer index, got #{index.class}." unless index.is_a?(Integer)
      raise ArgumentError, "Index out of range: #{index}." if index < 0 || index > length
      index
    end

    def insertion_sequence(parent)
      if parent.nil?
        content_sequence(:create => true)
      else
        parent_item = locate_item(parent)
        sequence = parent_item[CONTENT_SEQUENCE_TAG]
        sequence || Sequence.new(CONTENT_SEQUENCE_TAG, :parent => parent_item)
      end
    end

    def locate_item(source)
      return source.item if source.is_a?(SRContentNode)
      item, parent_item = item_at(normalize_path(source))
      raise ArgumentError, "No content item at path #{Array(source).join(".")}." unless item
      item
    end

    def item_at(path, sequence = content_sequence, parent_item = nil)
      return [nil, nil] unless sequence
      head, *rest = path
      item = sequence.items[head - 1]
      return [nil, nil] unless item
      if rest.empty?
        [item, parent_item]
      else
        item_at(rest, item[CONTENT_SEQUENCE_TAG], item)
      end
    end

    def parent_item(item)
      sequence = item.parent
      sequence && sequence.parent
    end

    def walk_content(sequence, path = [], &block)
      return unless sequence
      sequence.items.each_with_index do |item, index|
        item_path = path + [index + 1]
        block.call(item, item_path)
        walk_content(item[CONTENT_SEQUENCE_TAG], item_path, &block)
      end
    end

    def capture_item_paths
      mapping = {}
      walk_content(content_sequence) { |item, path| mapping[item] = path }
      mapping
    end

    def remap_references(old_mapping, new_mapping, skipped_items = [])
      skipped = skipped_items.each_with_object({}) { |item, map| map[item] = true }
      old_paths = old_mapping.invert
      walk_content(content_sequence) do |referrer, current_path|
        next if skipped[referrer]
        old_path = reference_path(referrer)
        next unless old_path
        target = old_paths[old_path]
        next unless target && new_mapping.key?(target)
        write_reference_path(referrer, new_mapping[target])
      end
    end

    def rebind_inserted_references(inserted_items, old_mapping, new_mapping)
      inserted = inserted_items.each_with_object({}) { |item, map| map[item] = true }
      old_paths = old_mapping.invert
      inserted_items.each do |referrer|
        old_path = reference_path(referrer)
        next unless old_path
        next if item_at(old_path).first
        target = old_paths[old_path]
        write_reference_path(referrer, new_mapping[target]) if target && new_mapping.key?(target)
      end
    end

    def validate_references
      walk_content(content_sequence) do |item, path|
        target_path = reference_path(item)
        next unless target_path
        target = item_at(target_path).first
        next if target
        raise SRReferenceError, "Invalid content reference #{target_path.join(".")} from #{path.join(".")}."
      end
    end

    def subtree_items(item)
      items = [item]
      sequence = item[CONTENT_SEQUENCE_TAG]
      walk_content(sequence) { |child, path| items << child }
      items
    end

    def external_referrers(subtree)
      target_set = subtree.each_with_object({}) { |item, map| map[item] = true }
      referrers = []
      walk_content(content_sequence) do |item, path|
        next if target_set[item]
        target = referenced_item(item)
        referrers << item if target && target_set[target]
      end
      referrers
    end

    def root_item(item)
      current = item
      current = parent_item(current) while parent_item(current)
      current
    end

    def descendant_destination?(source_item, destination_sequence)
      destination_item = destination_sequence.parent
      current = destination_item
      while current
        return true if current.equal?(source_item)
        current = parent_item(current)
      end
      false
    end

    def remove_item(item)
      sequence = item.parent
      return unless sequence
      sequence.delete(item.index, :no_follow => true)
      item.set_parent(nil)
      compact_sequence(sequence)
    end

    def compact_sequence(sequence)
      items = sequence.items
      sequence.instance_variable_set(:@tags, {})
      tags = sequence.instance_variable_get(:@tags)
      items.each_with_index do |item, index|
        tags[index] = item
        item.index = index
        item.set_parent(sequence)
      end
    end

    def cleanup_empty_content_sequences
      sequences = []
      walk_content(content_sequence) { |item, path| sequences << item[CONTENT_SEQUENCE_TAG] if item[CONTENT_SEQUENCE_TAG] }
      sequences.reverse.each do |sequence|
        parent = sequence.parent
        parent.delete(CONTENT_SEQUENCE_TAG) if parent.is_a?(Item) && sequence.items.empty?
      end
    end

    def build_item(attributes, parent, inserted_items = nil)
      item = Item.new
      parent.add_item(item, :index => parent.items.length)
      inserted_items << item if inserted_items
      write_attributes(item, attributes)
      Array(attributes[:children]).each do |child_attributes|
        child_sequence = item[CONTENT_SEQUENCE_TAG] || Sequence.new(CONTENT_SEQUENCE_TAG, :parent => item)
        build_item(normalize_attributes(child_attributes), child_sequence, inserted_items)
      end
      item
    end

    def write_attributes(item, attributes)
      write_element(item, VALUE_TYPE_TAG, attributes[:value_type], "CS")
      write_element(item, RELATIONSHIP_TYPE_TAG, attributes[:relationship_type], "CS")
      if attributes.key?(:concept_name)
        write_code_sequence(item, CONCEPT_NAME_TAG, attributes[:concept_name])
      end
      if attributes.key?(:reference_path)
        KNOWN_VALUE_TAGS.each { |tag| item.delete(tag) }
        item.delete(MEASUREMENT_UNITS_TAG)
        item.delete(NUMERIC_QUALIFIER_TAG)
        if attributes[:reference_path]
          write_reference_path(item, attributes[:reference_path])
        end
      elsif attributes.key?(:value)
        item.delete(REFERENCE_PATH_TAG)
        write_value(item, attributes[:value_type] || item.value(VALUE_TYPE_TAG), attributes[:value])
      end
    end

    def write_reference_path(item, path)
      values = normalize_path(path)
      Element.new(REFERENCE_PATH_TAG, values, :parent => item, :vr => "UL")
    end

    def write_element(item, tag, value, vr = nil)
      item.delete(tag)
      Element.new(tag, value, :parent => item, :vr => vr) unless value.nil?
    end

    def write_value(item, value_type, value)
      KNOWN_VALUE_TAGS.each { |tag| item.delete(tag) }
      item.delete(MEASUREMENT_UNITS_TAG)
      item.delete(NUMERIC_QUALIFIER_TAG)
      case value_type
      when "TEXT" then write_element(item, TEXT_VALUE_TAG, value, "UT")
      when "CODE" then write_code_sequence(item, CONCEPT_CODE_TAG, value)
      when "NUM" then write_numeric(item, value)
      when "IMAGE" then write_image_reference(item, value)
      when "SCOORD" then write_scoord(item, value)
      when nil then nil
      else raise ArgumentError, "Unsupported SR value type: #{value_type}."
      end
    end

    def write_numeric(item, value)
      if value.is_a?(Array)
        value = { :numeric_value => value }
      end
      numeric, unit, qualifier = numeric_parts(value)
      return if numeric.nil? && unit.nil? && qualifier.nil?
      measured = item[MEASURED_VALUE_TAG] || Sequence.new(MEASURED_VALUE_TAG, :parent => item)
      measured_item = measured.items.first || Item.new(:parent => measured)
      measured_item.delete(NUMERIC_VALUE_TAG)
      measured_item.delete(MEASUREMENT_UNITS_TAG)
      numeric_values = Array(numeric).map { |number| numeric_string(number) }
      write_element(measured_item, NUMERIC_VALUE_TAG, numeric_values.join("\\"), "DS") if numeric
      write_code_sequence(measured_item, MEASUREMENT_UNITS_TAG, unit) if unit
      item.delete(NUMERIC_QUALIFIER_TAG)
      write_code_sequence(item, NUMERIC_QUALIFIER_TAG, qualifier) if qualifier
    end

    def numeric_parts(value)
      if value.is_a?(Hash)
        normalized = symbolize_deep(value)
        numeric = normalized.fetch(:numeric_value, normalized.fetch(:value, nil))
        unit = normalized.fetch(:unit, normalized.fetch(:units, nil))
        qualifier = normalized[:qualifier]
        [numeric, unit, qualifier]
      else
        [value, nil, nil]
      end
    end

    def numeric_string(number)
      float = Float(number)
      integer = float.to_i
      integer == float ? integer.to_s : float.to_s
    rescue ArgumentError
      number.to_s
    end

    def write_image_reference(item, value)
      raise ArgumentError, "Expected Hash for IMAGE value." unless value.is_a?(Hash)
      image = symbolize_deep(value)
      sequence = Sequence.new(REFERENCED_SOP_TAG, :parent => item)
      reference_item = Item.new(:parent => sequence)
      write_element(reference_item, REFERENCED_SOP_CLASS_TAG, image[:sop_class_uid] || image[:sop_class] || image[:class_uid], "UI")
      write_element(reference_item, REFERENCED_SOP_INSTANCE_TAG, image[:sop_instance_uid] || image[:sop_instance] || image[:instance_uid], "UI")
      frames = Array(image[:frame_numbers] || image[:frames] || image[:frame_number] || image[:frame]).map(&:to_s)
      write_element(reference_item, REFERENCED_FRAME_TAG, frames.join("\\"), "IS") unless frames.empty?
      write_code_sequence(reference_item, PURPOSE_OF_REFERENCE_TAG, image[:purpose]) if image[:purpose]
    end

    def write_scoord(item, value)
      raise ArgumentError, "Expected Hash for SCOORD value." unless value.is_a?(Hash)
      scoord = symbolize_deep(value)
      write_element(item, GRAPHIC_TYPE_TAG, scoord[:graphic_type] || scoord[:type], "CS")
      coordinates = scoord[:coordinates] || scoord[:coords] || scoord[:points]
      if coordinates
        values = if coordinates.is_a?(Array) && coordinates.first.is_a?(Array)
          coordinates.flatten
        else
          Array(coordinates)
        end
        write_element(item, GRAPHIC_DATA_TAG, values.map(&:to_f), "FL")
      end
      write_image_reference(item, scoord[:image]) if scoord[:image]
      write_code_sequence(item, PURPOSE_OF_REFERENCE_TAG, scoord[:purpose]) if scoord[:purpose]
    end

    def write_code_sequence(item, tag, value)
      item.delete(tag)
      return unless value
      sequence = Sequence.new(tag, :parent => item)
      code_item = Item.new(:parent => sequence)
      code = symbolize_deep(value)
      write_element(code_item, "0008,0119", code[:long_code_value], "UC") if code[:long_code_value]
      write_element(code_item, "0008,0120", code[:urn_code_value], "UR") if code[:urn_code_value]
      write_element(code_item, "0008,0100", code[:code_value] || code[:code], "SH") unless code[:long_code_value] || code[:urn_code_value]
      write_element(code_item, "0008,0102", code[:coding_scheme_designator] || code[:scheme], "SH")
      write_element(code_item, "0008,0103", code[:coding_scheme_version], "SH")
      write_element(code_item, "0008,0104", code[:code_meaning] || code[:meaning], "LO")
      Array(code[:extra]).each do |extra_tag, extra_value|
        next if %w(0008,0100 0008,0102 0008,0103 0008,0104 0008,0119 0008,0120).include?(extra_tag)
        Element.new(extra_tag, extra_value, :parent => code_item)
      end
    end

    def read_code(sequence)
      return nil unless sequence && sequence.items.any?
      item = sequence.items.first
      code_value_tag = item["0008,0119"] ? "0008,0119" : item["0008,0120"] ? "0008,0120" : "0008,0100"
      result = {
        :code_value => item.value(code_value_tag),
        :coding_scheme_designator => item.value("0008,0102"),
        :coding_scheme_version => item.value("0008,0103"),
        :code_meaning => item.value("0008,0104")
      }.reject { |key, value| value.nil? }
      item.elements.each do |element|
        next if %w(0008,0100 0008,0102 0008,0103 0008,0104 0008,0119 0008,0120).include?(element.tag)
        result[element.tag] = element.value
      end
      result
    end

    def read_numeric(item)
      sequence = item[MEASURED_VALUE_TAG]
      return nil unless sequence && sequence.items.any?
      measured_item = sequence.items.first
      raw = measured_item.value(NUMERIC_VALUE_TAG)
      numbers = raw ? raw.split("\\").map { |value| parse_number(value) } : nil
      {
        :numeric_value => one_or_many(numbers),
        :unit => read_code(measured_item[MEASUREMENT_UNITS_TAG]),
        :qualifier => read_code(item[NUMERIC_QUALIFIER_TAG])
      }.reject { |key, value| value.nil? }
    end

    def read_image_reference(sequence, purpose_sequence = nil)
      return nil unless sequence && sequence.items.any?
      item = sequence.items.first
      frames = item.value(REFERENCED_FRAME_TAG)
      purpose = read_code(item[PURPOSE_OF_REFERENCE_TAG])
      result = {
        :sop_class_uid => item.value(REFERENCED_SOP_CLASS_TAG),
        :sop_instance_uid => item.value(REFERENCED_SOP_INSTANCE_TAG),
        :frame_numbers => frames ? frames.split("\\").map(&:to_i) : nil,
        :purpose => purpose
      }.reject { |key, value| value.nil? }
      result
    end

    def read_scoord(item)
      element = item[GRAPHIC_DATA_TAG]
      coordinates = if element
        values = element.bin.unpack(item.stream.str_endian ? "g*" : "e*")
        values.each_slice(2).to_a
      else
        nil
      end
      result = {
        :graphic_type => item.value(GRAPHIC_TYPE_TAG),
        :coordinates => coordinates,
        :image => read_image_reference(item[REFERENCED_SOP_TAG])
      }.reject { |key, value| value.nil? || (key == :image && value.empty?) }
      result
    end

    def parse_number(value)
      value.include?(".") || value.include?("e") || value.include?("E") ? Float(value) : Integer(value)
    end

    def one_or_many(values)
      values && values.length == 1 ? values.first : values
    end

    def symbolize_deep(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), result|
          result[key.to_s.tr("-", "_").to_sym] = symbolize_deep(nested_value)
        end
      when Array
        value.map { |item| symbolize_deep(item) }
      else
        value
      end
    end

  end

  class SRContentNode

    attr_reader :item, :graph

    def initialize(item, graph)
      @item = item
      @graph = graph
    end

    def path
      graph.path_for(item)
    end

    def value_type
      item.value(SRContentGraph::VALUE_TYPE_TAG)
    end

    def relationship_type
      item.value(SRContentGraph::RELATIONSHIP_TYPE_TAG)
    end

    def concept_name
      graph.send(:read_code, item[SRContentGraph::CONCEPT_NAME_TAG])
    end

    def value
      graph.value_for(item)
    end

    def reference_path
      graph.reference_path(item)
    end

    def reference?
      !reference_path.nil?
    end

    def referenced_node
      target = graph.referenced_item(item)
      target ? SRContentNode.new(target, graph) : nil
    end

    def parent
      graph.parent_node(item)
    end

    def children
      graph.children(item)
    end

    def root?
      parent.nil?
    end

    def ==(other)
      other.is_a?(SRContentNode) && item.equal?(other.item) && graph.equal?(other.graph)
    end

    alias_method :eql?, :==

    def hash
      item.hash
    end

    def to_s
      path.join(".")
    end

    def value_type=(value)
      update(:value_type => value)
    end

    def relationship_type=(value)
      update(:relationship_type => value)
    end

    def concept_name=(value)
      update(:concept_name => value)
    end

    def value=(value)
      update(:value => value)
    end

    def reference_path=(path)
      update(:reference_path => path)
    end

    def update(attributes)
      graph.update_item(item, attributes)
      self
    end

    def insert_child(attributes, index: -1)
      graph.insert(attributes, :parent => self, :index => index)
    end

    def move_to(parent: nil, index: -1)
      graph.move(self, :destination => parent, :index => index)
    end

    def delete(strategy: :reject)
      graph.delete(self, :strategy => strategy)
    end

    def to_h
      hash = {
        :path => path,
        :value_type => value_type,
        :relationship_type => relationship_type,
        :concept_name => concept_name,
        :value => value
      }.reject { |key, value| value.nil? }
      hash[:reference_path] = reference_path if reference?
      child_values = children.map(&:to_h)
      hash[:children] = child_values unless child_values.empty?
      hash
    end

  end
end
