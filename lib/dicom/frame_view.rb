module DICOM

  # Error raised when an enhanced multi-frame DICOM object fails
  # structural validation (frame count, dimension index pointers or
  # per-frame sequence lengths). Error messages are localized to the
  # offending frame and/or tag whenever possible.
  #
  class FrameViewError < StandardError; end

  # The FrameView class provides a per-frame view of an enhanced multi-frame
  # DICOM object, giving convenient access to the functional group macros that
  # apply to a single frame, its Dimension Index coordinates, and the origin
  # (shared or per-frame) of each functional group.
  #
  # Only metadata is accessed; pixel data is never decoded, so this interface
  # works equally well for objects with compressed or absent pixel data.
  #
  # === Notes on functional group merging
  #
  # The functional groups of a frame are the union of the macros found in the
  # (single) item of the Shared Functional Groups Sequence (5200,9229) and the
  # macros found in the frame's own item of the Per-frame Functional Groups
  # Sequence (5200,9230). The DICOM standard forbids the same functional group
  # from appearing in both places, so the two levels are NOT combined with a
  # plain hash merge (which would silently let one level override the other).
  # Instead, a duplicate functional group raises a FrameViewError.
  #
  class FrameView

    # The DObject instance that this frame view belongs to.
    attr_reader :dcm
    # The (zero-based) index of the frame that this instance represents.
    attr_reader :index

    # Tag of the Number of Frames element.
    NUMBER_OF_FRAMES = '0028,0008'
    # Tag of the Frame Content Sequence functional group.
    FRAME_CONTENT = '0020,9111'
    # Tag of the Dimension Index Values element.
    DIMENSION_INDEX_VALUES = '0020,9157'
    # Tag of the Dimension Index Pointer element.
    DIMENSION_INDEX_POINTER = '0020,9165'
    # Tag of the Functional Group Pointer element.
    FUNCTIONAL_GROUP_POINTER = '0020,9167'
    # Tag of the Dimension Index Sequence.
    DIMENSION_INDEX = '0020,9222'
    # Tag of the Dimension Description Label element.
    DIMENSION_DESCRIPTION_LABEL = '0020,9421'
    # Tag of the Shared Functional Groups Sequence.
    SHARED_FUNCTIONAL_GROUPS = '5200,9229'
    # Tag of the Per-frame Functional Groups Sequence.
    PER_FRAME_FUNCTIONAL_GROUPS = '5200,9230'

    # Creates a FrameView instance for the given frame of an enhanced
    # multi-frame DICOM object.
    #
    # @note The structural validity of the object (frame count, shared item
    #   count, dimension index pointers and this frame's dimension index
    #   values) is verified upon creation, and a FrameViewError is raised
    #   if the object is invalid.
    # @param [DObject] dcm an enhanced multi-frame DICOM object
    # @param [Integer] index the zero-based index of the frame
    # @return [FrameView] the created FrameView instance
    # @example Create a view for the first frame of an enhanced multi-frame object
    #   view = DICOM::FrameView.new(dcm, 0)
    #
    def initialize(dcm, index)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DObject)
      raise ArgumentError, "Invalid argument 'index'. Expected Integer, got #{index.class}." unless index.is_a?(Integer)
      @dcm = dcm
      @index = index
      validate!
    end

    # Creates FrameView instances for all frames of an enhanced multi-frame
    # DICOM object (validating every frame in the process).
    #
    # @param [DObject] dcm an enhanced multi-frame DICOM object
    # @return [Array<FrameView>] frame views for all frames of the object
    # @example Get the dimension coordinates of all frames
    #   DICOM::FrameView.all(dcm).collect(&:dimension_coordinates)
    #
    def self.all(dcm)
      first = new(dcm, 0)
      (0...first.send(:per_frame_count)).collect { |i| i == 0 ? first : new(dcm, i) }
    end

    # Checks if the given DICOM object carries the Per-frame Functional Groups
    # Sequence, i.e. whether it can be viewed as an enhanced multi-frame object.
    #
    # @param [DObject] dcm a DICOM object
    # @return [Boolean] true if the object contains per-frame functional groups
    #
    def self.supported?(dcm)
      dcm.is_a?(DObject) && dcm[PER_FRAME_FUNCTIONAL_GROUPS].is_a?(Sequence)
    end

    # Retrieves the functional group sequence (macro) matching the given tag,
    # looking in both the shared and the per-frame functional groups.
    #
    # @param [String] tag a ruby-dicom tag string identifying the functional group
    # @return [Sequence, NilClass] the matched functional group sequence (or nil)
    # @example Extract the Plane Position Sequence that applies to this frame
    #   view['0020,9113']
    #
    def [](tag)
      functional_groups[tag.is_a?(String) ? tag.upcase : tag]
    end

    # Gives the Dimension Index coordinates of this frame, as a hash mapping
    # each Dimension Index Pointer tag to its (one-based) coordinate value.
    #
    # @return [Hash] a hash of pointer tag => coordinate pairs
    # @example Get the coordinates of a frame
    #   view.dimension_coordinates # => {'0020,0032' => 1, '0018,1069' => 3}
    #
    def dimension_coordinates
      coordinates = {}
      dimensions.each do |dimension|
        coordinates[dimension[:pointer]] = dimension[:coordinate]
      end
      coordinates
    end

    # Gives the Dimension Index Values of this frame (the frame's coordinates
    # along each dimension defined by the Dimension Index Sequence).
    #
    # @return [Array<Integer>] the dimension index values (empty if undefined)
    #
    def dimension_index_values
      frame_content = self[FRAME_CONTENT]
      return [] unless frame_content
      item = frame_content[0]
      return [] unless item
      values = item.value(DIMENSION_INDEX_VALUES)
      values.nil? ? [] : (values.is_a?(Array) ? values : [values])
    end

    # Describes each dimension of the Dimension Index Sequence, along with
    # this frame's coordinate and (when resolvable) the value of the pointed
    # attribute for this frame.
    #
    # @return [Array<Hash>] one hash per dimension, with keys :pointer,
    #   :functional_group, :label, :coordinate and :value
    # @example Print the position of a frame along each dimension
    #   view.dimensions.each { |d| puts "#{d[:label] || d[:pointer]}: #{d[:coordinate]} (#{d[:value]})" }
    #
    def dimensions
      values = dimension_index_values
      dimension_index_items.each_with_index.collect do |item, i|
        pointer = item.value(DIMENSION_INDEX_POINTER)
        {
          :pointer => pointer,
          :functional_group => item.value(FUNCTIONAL_GROUP_POINTER),
          :label => item.value(DIMENSION_DESCRIPTION_LABEL),
          :coordinate => values[i],
          :value => pointed_value(pointer, item.value(FUNCTIONAL_GROUP_POINTER))
        }
      end
    end

    # Returns the merged functional groups of this frame (shared + per-frame).
    #
    # @note This is NOT a plain hash merge: The DICOM standard forbids a
    #   functional group from occurring in both the shared and the per-frame
    #   functional groups, and a FrameViewError is raised if such a duplicate
    #   is encountered (rather than silently letting one level win).
    # @return [Hash] a hash of functional group tag => Sequence
    #
    def functional_groups
      unless @functional_groups
        @functional_groups = {}
        @functional_group_sources = {}
        shared_item = shared_functional_groups_item
        if shared_item
          shared_item.sequences.each do |sequence|
            @functional_groups[sequence.tag] = sequence
            @functional_group_sources[sequence.tag] = :shared
          end
        end
        per_frame_item.sequences.each do |sequence|
          if @functional_groups.key?(sequence.tag)
            raise FrameViewError, "Frame #{@index}: Functional group #{sequence.tag} occurs in both the Shared Functional Groups Sequence (#{SHARED_FUNCTIONAL_GROUPS}) and the Per-frame Functional Groups Sequence (#{PER_FRAME_FUNCTIONAL_GROUPS}). The DICOM standard does not permit a functional group to occur in both."
          end
          @functional_groups[sequence.tag] = sequence
          @functional_group_sources[sequence.tag] = :per_frame
        end
      end
      @functional_groups
    end

    # Gives the tags of all functional groups that apply to this frame.
    #
    # @return [Array<String>] the functional group tags
    #
    def functional_group_tags
      functional_groups.keys
    end

    # Checks if the given functional group is defined per-frame for this frame.
    #
    # @param [String] tag a ruby-dicom tag string identifying the functional group
    # @return [Boolean] true if the functional group comes from the per-frame item
    #
    def per_frame?(tag)
      source(tag) == :per_frame
    end

    # Checks if the given functional group is shared by all frames.
    #
    # @param [String] tag a ruby-dicom tag string identifying the functional group
    # @return [Boolean] true if the functional group comes from the shared item
    #
    def shared?(tag)
      source(tag) == :shared
    end

    # Tells where the given functional group is defined for this frame.
    #
    # @param [String] tag a ruby-dicom tag string identifying the functional group
    # @return [Symbol, NilClass] :shared, :per_frame, or nil if not present
    # @example Check the origin of the Plane Position Sequence
    #   view.source('0020,9113') # => :shared
    #
    def source(tag)
      functional_groups
      @functional_group_sources[tag.is_a?(String) ? tag.upcase : tag]
    end

    # Extracts the value of a data element contained in (the first item of)
    # one of this frame's functional groups.
    #
    # @param [String] group_tag tag of the functional group sequence
    # @param [String] element_tag tag of the element inside the functional group item
    # @return [String, Integer, Float, Array, NilClass] the element value (or nil)
    # @example Extract the Slice Thickness from the Pixel Measures Sequence
    #   view.value('0028,9110', '0018,0050')
    #
    def value(group_tag, element_tag)
      group = self[group_tag]
      return nil unless group
      item = group[0]
      item ? item.value(element_tag) : nil
    end


    private


    # Gives the items of the Dimension Index Sequence (empty array if undefined).
    #
    # @return [Array<Item>] the dimension index items
    #
    def dimension_index_items
      sequence = @dcm[DIMENSION_INDEX]
      sequence.is_a?(Sequence) ? sequence.items : []
    end

    # Gives the number of frames declared by the Number of Frames element.
    #
    # @return [Integer] the declared number of frames
    #
    def number_of_frames
      element = @dcm[NUMBER_OF_FRAMES]
      unless element.is_a?(Element)
        raise FrameViewError, "Number of Frames (#{NUMBER_OF_FRAMES}) is missing: Unable to determine the expected frame count of this (enhanced multi-frame) object."
      end
      element.value.to_i
    end

    # Gives the number of items in the Per-frame Functional Groups Sequence.
    #
    # @return [Integer] the per-frame item count
    #
    def per_frame_count
      per_frame_sequence.items.length
    end

    # Gives this frame's item of the Per-frame Functional Groups Sequence.
    #
    # @return [Item] the per-frame item of this frame
    #
    def per_frame_item
      per_frame_sequence[@index]
    end

    # Gives the Per-frame Functional Groups Sequence of the DICOM object.
    #
    # @return [Sequence] the per-frame functional groups sequence
    #
    def per_frame_sequence
      sequence = @dcm[PER_FRAME_FUNCTIONAL_GROUPS]
      unless sequence.is_a?(Sequence)
        raise FrameViewError, "Not an enhanced multi-frame object: The Per-frame Functional Groups Sequence (#{PER_FRAME_FUNCTIONAL_GROUPS}) is missing."
      end
      sequence
    end

    # Resolves the value of the attribute pointed to by a Dimension Index
    # Pointer, searching the functional groups of this frame.
    #
    # @param [String] pointer the tag of the pointed attribute
    # @param [String, NilClass] group_pointer tag of the functional group containing the attribute (if specified)
    # @return [String, Integer, Float, Array, NilClass] the pointed value (nil if unresolvable)
    #
    def pointed_value(pointer, group_pointer)
      return nil unless pointer.is_a?(String) && pointer.tag?
      if group_pointer.is_a?(String) && group_pointer.tag?
        return value(group_pointer, pointer)
      end
      functional_groups.each_key do |group_tag|
        result = value(group_tag, pointer)
        return result unless result.nil?
      end
      nil
    end

    # Gives the (single) item of the Shared Functional Groups Sequence.
    #
    # @return [Item, NilClass] the shared functional groups item (nil if none)
    #
    def shared_functional_groups_item
      sequence = @dcm[SHARED_FUNCTIONAL_GROUPS]
      sequence.is_a?(Sequence) ? sequence[0] : nil
    end

    # Validates the structural integrity of the enhanced multi-frame object
    # as far as this frame view is concerned: Frame count vs. per-frame
    # sequence length, shared item count, dimension index pointers, and the
    # length of this frame's Dimension Index Values.
    #
    def validate!
      # The object must carry per-frame functional groups:
      count = per_frame_count
      # The declared frame count must match the per-frame sequence length:
      declared = number_of_frames
      if count != declared
        raise FrameViewError, "Frame count mismatch: Number of Frames (#{NUMBER_OF_FRAMES}) is #{declared}, but the Per-frame Functional Groups Sequence (#{PER_FRAME_FUNCTIONAL_GROUPS}) contains #{count} item(s)."
      end
      # The Shared Functional Groups Sequence, if present, must contain exactly one item:
      shared = @dcm[SHARED_FUNCTIONAL_GROUPS]
      if shared
        shared_count = shared.is_a?(Sequence) ? shared.items.length : nil
        unless shared_count == 1
          raise FrameViewError, "The Shared Functional Groups Sequence (#{SHARED_FUNCTIONAL_GROUPS}) must contain exactly one item (found #{shared_count || 'none'})."
        end
      end
      # The frame index must be within range:
      unless (0...count).include?(@index)
        raise FrameViewError, "Frame #{@index} is out of range: The Per-frame Functional Groups Sequence (#{PER_FRAME_FUNCTIONAL_GROUPS}) contains #{count} item(s)."
      end
      # Every dimension must have a valid Dimension Index Pointer (and Functional Group Pointer, if present):
      dimension_index_items.each_with_index do |item, i|
        pointer = item.value(DIMENSION_INDEX_POINTER)
        unless pointer.is_a?(String) && pointer.tag?
          raise FrameViewError, "Dimension Index Sequence (#{DIMENSION_INDEX}) item #{i}: Missing or invalid Dimension Index Pointer (#{DIMENSION_INDEX_POINTER}): #{pointer.inspect}"
        end
        group_pointer = item.value(FUNCTIONAL_GROUP_POINTER)
        if group_pointer && !(group_pointer.is_a?(String) && group_pointer.tag?)
          raise FrameViewError, "Dimension Index Sequence (#{DIMENSION_INDEX}) item #{i}: Invalid Functional Group Pointer (#{FUNCTIONAL_GROUP_POINTER}): #{group_pointer.inspect}"
        end
      end
      # If dimensions are defined, this frame must carry a matching number of Dimension Index Values:
      dimensions = dimension_index_items.length
      if dimensions > 0
        values = dimension_index_values
        if values.length != dimensions
          raise FrameViewError, "Frame #{@index}: Dimension Index Values (#{DIMENSION_INDEX_VALUES}) contains #{values.length} value(s), but the Dimension Index Sequence (#{DIMENSION_INDEX}) defines #{dimensions} dimension(s)."
        end
      end
    end

  end


  class DObject

    # Creates a frame view for the given frame of this (enhanced multi-frame)
    # DICOM object. Only metadata is accessed; pixel data is never decoded.
    #
    # @param [Integer] index the zero-based index of the frame
    # @return [FrameView] a view of the specified frame
    # @example Get the dimension coordinates of the second frame
    #   dcm.frame_view(1).dimension_coordinates
    #
    def frame_view(index)
      FrameView.new(self, index)
    end

    # Creates frame views for all frames of this (enhanced multi-frame)
    # DICOM object.
    #
    # @return [Array<FrameView>] frame views for all frames of the object
    # @example List the origin of the Plane Position Sequence for all frames
    #   dcm.frame_views.collect { |view| view.source('0020,9113') }
    #
    def frame_views
      FrameView.all(self)
    end

  end

end

