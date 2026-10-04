module DICOM

  SHARED_FUNCTIONAL_GROUPS_TAG = '5200,9229'
  PER_FRAME_FUNCTIONAL_GROUPS_TAG = '5200,9230'
  DIMENSION_INDEX_SEQUENCE_TAG = '0020,9222'
  DIMENSION_INDEX_POINTER_TAG = '0020,9165'
  FUNCTIONAL_GROUP_POINTER_TAG = '0020,9167'
  DIMENSION_INDEX_VALUES_TAG = '0020,9157'
  FRAME_CONTENT_SEQUENCE_TAG = '0020,9111'
  FRAME_LABEL_TAG = '0020,9453'

  class EnhancedMultiFrameError < ArgumentError
  end

  # Represents one functional group macro and records whether it came from
  # the shared or the per-frame functional groups item.
  FunctionalGroupView = Struct.new(:tag, :name, :item, :source) do
    def shared?
      source == :shared
    end

    def per_frame?
      source == :per_frame
    end

    def source_location
      source.to_s.gsub('_', '-')
    end

    def to_a
      [tag, item]
    end

    def value(group_tag)
      item.value(group_tag)
    end

    def [](tag)
      item[tag]
    end
  end

  DimensionIndex = Struct.new(:index, :pointer, :functional_group_pointer, :private_creator, :functional_group_private_creator)

  # Provides validated access to the macros and dimension coordinates of one frame.
  class FrameView
    attr_reader :index, :shared_item, :per_frame_item

    def initialize(index, shared_item, per_frame_item, dimension_indices)
      @index = index
      @shared_item = shared_item
      @per_frame_item = per_frame_item
      @dimension_indices = dimension_indices
      @shared_groups = extract_groups(shared_item, :shared)
      @per_frame_groups = extract_groups(per_frame_item, :per_frame)
      @functional_groups = Hash.new
      @shared_groups.each { |tag, group| @functional_groups[tag] = group }
      @per_frame_groups.each { |tag, group| @functional_groups[tag] = group }
    end

    def dimension_index
      dimension_index_values.map(&:last)
    end

    def dimension_index_coordinates
      Hash[dimension_index_values.map { |pointer, value| [pointer, value] }]
    end

    alias_method :coordinates, :dimension_index_coordinates

    def dimension_index_values
      values = numeric_values(frame_content_element(DIMENSION_INDEX_VALUES_TAG)) || Array.new
      @dimension_indices.map { |dimension| [dimension.pointer, values[dimension.index]] }
    end

    def frame_content_item
      functional_group(FRAME_CONTENT_SEQUENCE_TAG) do |group|
        group.item
      end
    end

    def frame_label
      item = frame_content_item
      item && item.value(FRAME_LABEL_TAG)
    end

    def function_group(tag)
      functional_group(tag)
    end

    def functional_group(tag)
      group = @functional_groups.fetch(tag.upcase) { return nil }
      block_given? ? yield(group) : group
    end

    alias_method :group, :functional_group

    def functional_group_content(tag)
      group = functional_group(tag)
      group && group.item
    end

    def functional_group_source(tag)
      source_for(tag)
    end

    def functional_groups
      @functional_groups.dup
    end

    def functional_group_tags
      @functional_groups.keys
    end

    def groups
      functional_groups
    end

    def source_for(tag)
      group = functional_group(tag)
      group && group.source
    end

    alias_method :source, :source_for

    def shared_functional_groups
      @shared_groups.dup
    end

    def per_frame_functional_groups
      @per_frame_groups.dup
    end

    def shared?(tag)
      source_for(tag) == :shared
    end

    def per_frame?(tag)
      source_for(tag) == :per_frame
    end

    def [](tag)
      functional_group(tag)
    end

    private

    def extract_groups(item, source)
      return Hash.new unless item
      groups = Hash.new
      item.sequences.each do |sequence|
        groups[sequence.tag] = FunctionalGroupView.new(sequence.tag, sequence.name, sequence.items.first, source)
      end
      groups
    end

    def frame_content_element(tag)
      item = frame_content_item
      item && item[tag]
    end

    def numeric_values(element)
      return nil unless element
      return element.value if element.value.is_a?(Array)
      Stream.new(element.bin, element.stream.str_endian).decode_all(element.vr)
    end
  end

  class EnhancedMultiFrame
    include Enumerable

    attr_reader :data_set, :frames

    # Builds a validated enhanced multi-frame view from a DICOM data set.
    #
    # @param [DObject, Item] data_set the data set containing functional group sequences
    # @return [EnhancedMultiFrame] the validated frame collection
    #
    def self.for(data_set)
      new(data_set)
    end

    # Creates and validates the frame views. Pixel data is not decoded.
    #
    # @param [DObject, Item] data_set the data set containing functional group sequences
    #
    def initialize(data_set)
      raise ArgumentError, "Expected a DICOM data set, got #{data_set.class}." unless data_set.respond_to?(:[])
      @data_set = data_set
      @shared_sequence = sequence(SHARED_FUNCTIONAL_GROUPS_TAG)
      @per_frame_sequence = sequence(PER_FRAME_FUNCTIONAL_GROUPS_TAG)
      validate_structure
      @shared_item = @shared_sequence.items.first
      @shared_tags = validate_functional_group_item(@shared_item, SHARED_FUNCTIONAL_GROUPS_TAG, 'shared item') if @shared_item
      @dimension_indices = validate_dimension_index_sequence
      @frames = build_frames
    end

    def each(&block)
      @frames.each(&block)
    end

    def frame(index)
      raise ArgumentError, "Expected Integer frame index, got #{index.class}." unless index.is_a?(Integer)
      raise EnhancedMultiFrameError, "Frame #{index} is out of range. Expected 0 to #{length - 1}." unless index >= 0 && index < length
      @frames[index]
    end

    alias_method :frame_view, :frame
    alias_method :[], :frame

    def length
      @frames.length
    end

    alias_method :size, :length
    alias_method :frame_count, :length

    def num_frames
      length
    end

    def dimension_indices
      @dimension_indices.dup
    end

    alias_method :dimension_index_pointers, :dimension_indices

    private

    def sequence(tag)
      element = @data_set[tag]
      return nil if element.nil?
      unless element.is_a?(Sequence)
        raise EnhancedMultiFrameError, "#{tag} (#{element.name}) must be a Sequence, got #{element.class}."
      end
      element
    end

    def validate_structure
      number_element = @data_set['0028,0008']
      unless number_element && number_element.respond_to?(:value)
        raise EnhancedMultiFrameError, "Number of Frames (0028,0008) is missing."
      end
      number_text = number_element.value.to_s.strip
      unless number_text.match(/\A[1-9]\d*\z/)
        raise EnhancedMultiFrameError, "Number of Frames (0028,0008) must be a positive integer, got #{number_text.inspect}."
      end
      @number_of_frames = number_text.to_i

      unless @per_frame_sequence
        raise EnhancedMultiFrameError, "Per-frame Functional Groups Sequence (#{PER_FRAME_FUNCTIONAL_GROUPS_TAG}) is missing."
      end
      if @shared_sequence && @shared_sequence.items.length != 1
        raise EnhancedMultiFrameError, "Shared Functional Groups Sequence (#{SHARED_FUNCTIONAL_GROUPS_TAG}) must contain exactly one item, got #{@shared_sequence.items.length}."
      end
      if @per_frame_sequence.items.length != @number_of_frames
        raise EnhancedMultiFrameError, "Per-frame Functional Groups Sequence (#{PER_FRAME_FUNCTIONAL_GROUPS_TAG}) has #{@per_frame_sequence.items.length} items but Number of Frames (0028,0008) is #{@number_of_frames}."
      end
      validate_item_indices(@shared_sequence, SHARED_FUNCTIONAL_GROUPS_TAG) if @shared_sequence
      validate_item_indices(@per_frame_sequence, PER_FRAME_FUNCTIONAL_GROUPS_TAG)
    end

    def validate_functional_group_item(item, sequence_tag, label)
      unless item
        raise EnhancedMultiFrameError, "#{sequence_tag} contains an empty item."
      end
      tags = Hash.new
      item.sequences.each do |functional_group|
        if functional_group.items.length != 1
          raise EnhancedMultiFrameError, "#{sequence_tag} #{label}: functional group #{functional_group.tag} (#{functional_group.name}) must contain exactly one item, got #{functional_group.items.length}."
        end
        tags[functional_group.tag] = functional_group.items.first
      end
      item.elements.each do |element|
        raise EnhancedMultiFrameError, "#{sequence_tag} #{label}: unexpected data element #{element.tag} (#{element.name}). Functional groups must be encoded as sequences."
      end
      tags
    end

    def validate_item_indices(sequence, sequence_tag)
      sequence.items.each_with_index do |item, expected_index|
        if item.index != expected_index
          raise EnhancedMultiFrameError, "#{sequence_tag} item index #{item.index} is out of sequence. Expected #{expected_index}."
        end
      end
    end

    def validate_dimension_index_sequence
      dimension_sequence = @data_set[DIMENSION_INDEX_SEQUENCE_TAG]
      return Array.new if dimension_sequence.nil?
      unless dimension_sequence.is_a?(Sequence)
        raise EnhancedMultiFrameError, "Dimension Index Sequence (#{DIMENSION_INDEX_SEQUENCE_TAG}) must be a Sequence, got #{dimension_sequence.class}."
      end
      if dimension_sequence.items.length.zero?
        raise EnhancedMultiFrameError, "Dimension Index Sequence (#{DIMENSION_INDEX_SEQUENCE_TAG}) must contain at least one item."
      end

      seen = Hash.new
      dimension_sequence.items.each_with_index.map do |dimension_item, index|
        unless dimension_item.is_a?(Item)
          raise EnhancedMultiFrameError, "Dimension Index Sequence item #{index} is invalid: expected Item, got #{dimension_item.class}."
        end
        pointer = required_tag_value(dimension_item, DIMENSION_INDEX_POINTER_TAG, "Dimension Index Sequence item #{index}")
        functional_group_pointer = required_tag_value(dimension_item, FUNCTIONAL_GROUP_POINTER_TAG, "Dimension Index Sequence item #{index}")
        private_creator = element_value(dimension_item['0020,9213'])
        functional_group_private_creator = element_value(dimension_item['0020,9238'])
        key = [pointer, functional_group_pointer, private_creator, functional_group_private_creator]
        if seen.key?(key)
          raise EnhancedMultiFrameError, "Dimension Index Sequence item #{index} duplicates the pointers from item #{seen[key]}."
        end
        seen[key] = index
        unless pointer.is_a?(String) && pointer.tag?
          raise EnhancedMultiFrameError, "Dimension Index Sequence item #{index}: Dimension Index Pointer (#{DIMENSION_INDEX_POINTER_TAG}) must identify a DICOM tag, got #{pointer.inspect}."
        end
        unless functional_group_pointer.is_a?(String) && functional_group_pointer.tag?
          raise EnhancedMultiFrameError, "Dimension Index Sequence item #{index}: Functional Group Pointer (#{FUNCTIONAL_GROUP_POINTER_TAG}) must identify a DICOM tag, got #{functional_group_pointer.inspect}."
        end
        DimensionIndex.new(index, pointer, functional_group_pointer, private_creator, functional_group_private_creator)
      end
    end

    def required_tag_value(item, tag, label)
      element = item[tag]
      unless element
        raise EnhancedMultiFrameError, "#{label}: #{tag} (#{LIBRARY.element(tag).name}) is missing."
      end
      unless element.is_a?(Element)
        raise EnhancedMultiFrameError, "#{label}: #{tag} (#{LIBRARY.element(tag).name}) must be a data element, got #{element.class}."
      end
      element.value
    end

    def element_value(element)
      element && element.value
    end

    def build_frames
      @per_frame_sequence.items.each_with_index.map do |per_frame_item, frame_index|
        per_frame_tags = validate_functional_group_item(per_frame_item, PER_FRAME_FUNCTIONAL_GROUPS_TAG, "frame #{frame_index}")
        overlap = @shared_tags && @shared_tags.keys & per_frame_tags.keys
        if overlap && overlap.any?
          tag = overlap.first
          raise EnhancedMultiFrameError, "Frame #{frame_index}: functional group #{tag} (#{LIBRARY.element(tag).name}) appears in both shared and per-frame functional groups."
        end
        frame = FrameView.new(frame_index, @shared_item, per_frame_item, @dimension_indices)
        validate_dimension_values(frame, per_frame_tags, frame_index)
        frame
      end
    end

    def validate_dimension_values(frame, per_frame_tags, frame_index)
      return if @dimension_indices.empty?

      frame_content = per_frame_tags[FRAME_CONTENT_SEQUENCE_TAG]
      unless frame_content
        raise EnhancedMultiFrameError, "Frame #{frame_index}: Frame Content Sequence (#{FRAME_CONTENT_SEQUENCE_TAG}) is required because Dimension Index values are present."
      end
      values_element = frame_content[DIMENSION_INDEX_VALUES_TAG]
      unless values_element
        raise EnhancedMultiFrameError, "Frame #{frame_index}: Dimension Index Values (#{DIMENSION_INDEX_VALUES_TAG}) is missing in Frame Content Sequence (#{FRAME_CONTENT_SEQUENCE_TAG})."
      end
      unless values_element.is_a?(Element)
        raise EnhancedMultiFrameError, "Frame #{frame_index}: Dimension Index Values (#{DIMENSION_INDEX_VALUES_TAG}) must be a data element, got #{values_element.class}."
      end
      values = decode_values(values_element)
      unless values.length == @dimension_indices.length
        raise EnhancedMultiFrameError, "Frame #{frame_index}: Dimension Index Values (#{DIMENSION_INDEX_VALUES_TAG}) has #{values.length} value(s) but Dimension Index Sequence (#{DIMENSION_INDEX_SEQUENCE_TAG}) has #{@dimension_indices.length} index pointer(s)."
      end

      @dimension_indices.each do |dimension|
        actual = values[dimension.index]
        group = frame.functional_group(dimension.functional_group_pointer)
        unless group
          raise EnhancedMultiFrameError, "Frame #{frame_index}: Functional Group Pointer #{dimension.functional_group_pointer} from Dimension Index Sequence item #{dimension.index} does not identify a functional group in this frame."
        end
        if group.shared?
          raise EnhancedMultiFrameError, "Frame #{frame_index}: Functional Group Pointer #{dimension.functional_group_pointer} from Dimension Index Sequence item #{dimension.index} identifies a shared functional group, but indexed dimensions must vary per frame."
        end
        target_element = group.item[dimension.pointer]
        unless target_element
          raise EnhancedMultiFrameError, "Frame #{frame_index}: Dimension Index Pointer #{dimension.pointer} from Dimension Index Sequence item #{dimension.index} is absent from functional group #{dimension.functional_group_pointer}."
        end
        unless target_element.is_a?(Element)
          raise EnhancedMultiFrameError, "Frame #{frame_index}: Dimension Index Pointer #{dimension.pointer} from Dimension Index Sequence item #{dimension.index} must identify a data element in functional group #{dimension.functional_group_pointer}, got #{target_element.class}."
        end
        target_values = decode_values(target_element)
        target_value = target_values.length == 1 ? target_values.first : target_values[dimension.index]
        unless target_value == actual
          raise EnhancedMultiFrameError, "Frame #{frame_index}: Dimension Index Pointer #{dimension.pointer} from Dimension Index Sequence item #{dimension.index} has value #{target_value.inspect}, but Dimension Index Values (#{DIMENSION_INDEX_VALUES_TAG}) has #{actual.inspect}."
        end
      end
    end

    def decode_values(element)
      value = element.value
      return value if value.is_a?(Array)
      case element.vr
      when 'UL', 'US', 'SL', 'SS', 'FL', 'FD'
        Stream.new(element.bin, element.stream.str_endian).decode_all(element.vr)
      else
        value.to_s.split('\\')
      end
    end
  end

end
