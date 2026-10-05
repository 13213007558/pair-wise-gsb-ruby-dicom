module DICOM

  # The Segmentation class provides a structured interface to DICOM
  # Segmentation objects (Segmentation Storage, SOP Class UID
  # 1.2.840.10008.5.1.4.1.1.66.4).
  #
  # Both BINARY and FRACTIONAL segmentation types are supported. Frames are
  # mapped to segments through the Segment Identification Sequence of each
  # per-frame functional group item, so no assumptions are made about frames
  # being ordered by segment or by slice position.
  #
  # === Examples
  #
  #   # Wrap an existing DICOM object:
  #   seg = DICOM::Segmentation.new(dcm)
  #   seg.segment_numbers
  #   seg.masks(1)
  #   seg.referenced_images(1)
  #   seg.positions(1)
  #
  #   # Build a new segmentation from structured data:
  #   seg = DICOM::Segmentation.build(
  #     :type => 'BINARY',
  #     :rows => 3,
  #     :columns => 3,
  #     :segments => [{:number => 1, :label => 'Tumor'}],
  #     :frames => [{:segment => 1, :mask => [[0,1,0],[1,1,1],[0,1,0]]}]
  #   )
  #   seg.dcm.write('segmentation.dcm')
  #
  class Segmentation

    # The SOP Class UID of DICOM Segmentation Storage.
    SOP_CLASS_UID = '1.2.840.10008.5.1.4.1.1.66.4'
    # Segmentation type where each pixel is either inside or outside a segment (bit-packed pixel data).
    BINARY = 'BINARY'
    # Segmentation type where each pixel holds a fractional value (0..Maximum Fractional Value).
    FRACTIONAL = 'FRACTIONAL'

    # The DObject instance which holds the segmentation data set.
    attr_reader :dcm

    # Creates a Segmentation instance by wrapping an existing DICOM object.
    #
    # @param [DObject] dcm a DObject containing a DICOM Segmentation data set
    #
    def initialize(dcm)
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DObject)
      type = dcm.value('0062,0001')
      unless [BINARY, FRACTIONAL].include?(type)
        raise ArgumentError, "The given DICOM object is not a Segmentation (unexpected Segmentation Type (0062,0001): #{type.inspect})."
      end
      @dcm = dcm
    end

    # Creates a Segmentation instance by reading and parsing a DICOM file.
    #
    # @param [String] file a string which specifies the path of the DICOM segmentation file to be loaded
    # @return [Segmentation] the created segmentation instance
    #
    def self.read(file)
      self.new(DObject.read(file))
    end

    # Builds a new DICOM Segmentation data set from structured segment & frame data.
    #
    # The frames of the data set are written in the order given by the :frames
    # option; each frame is linked to its segment through the Segment
    # Identification Sequence of its per-frame functional group item.
    #
    # @param [Hash] options the options to use for building the segmentation
    # @option options [String] :type the segmentation type, 'BINARY' (default) or 'FRACTIONAL'
    # @option options [Integer] :rows the number of rows in the frame masks (required)
    # @option options [Integer] :columns the number of columns in the frame masks (required)
    # @option options [Array<Hash>] :segments segment definitions, each with :number and optionally :label & :algorithm_type (required)
    # @option options [Array<Hash>] :frames frame definitions in file order, each with :segment, :mask (a rows x columns array) and optionally :position, :orientation & :referenced (required)
    # @option options [Integer] :maximum_fractional_value the maximum fractional pixel value (required for FRACTIONAL)
    # @option options [String] :fractional_type the segmentation fractional type, e.g. 'PROBABILITY' or 'OCCUPANCY' (required for FRACTIONAL)
    # @option options [Integer] :bits_allocated the bit depth of fractional pixel data, 8 (default) or 16
    # @option options [Array<Float>] :pixel_spacing the [row, column] pixel spacing (in mm) shared by all frames
    # @option options [Float] :slice_thickness the slice thickness (in mm) shared by all frames
    # @option options [Array<Float>] :orientation the image orientation (patient) shared by all frames
    # @option options [String] :sop_instance_uid the SOP Instance UID of the segmentation (generated if not specified)
    # @option options [String] :study_instance_uid the Study Instance UID (generated if not specified)
    # @option options [String] :series_instance_uid the Series Instance UID (generated if not specified)
    # @option options [String] :frame_of_reference_uid the Frame of Reference UID (generated if not specified)
    # @option options [Integer] :series_number the Series Number (defaults to 1)
    # @option options [Integer] :instance_number the Instance Number (defaults to 1)
    # @return [Segmentation] the created segmentation instance
    #
    def self.build(options={})
      type = options[:type] ? options[:type].to_s.upcase : BINARY
      raise ArgumentError, "Invalid option :type. Expected '#{BINARY}' or '#{FRACTIONAL}', got #{type.inspect}." unless [BINARY, FRACTIONAL].include?(type)
      segments = options[:segments]
      raise ArgumentError, "Missing option :segments. Expected a non-empty Array of segment definition hashes." unless segments.is_a?(Array) && segments.length > 0
      frames = options[:frames]
      raise ArgumentError, "Missing option :frames. Expected a non-empty Array of frame hashes." unless frames.is_a?(Array) && frames.length > 0
      rows = options[:rows]
      columns = options[:columns]
      raise ArgumentError, "Missing/invalid option :rows. Expected a positive Integer, got #{rows.inspect}." unless rows.is_a?(Integer) && rows > 0
      raise ArgumentError, "Missing/invalid option :columns. Expected a positive Integer, got #{columns.inspect}." unless columns.is_a?(Integer) && columns > 0
      segment_numbers = segments.collect {|s| s[:number] }
      unless segment_numbers.compact.length == segments.length && segment_numbers.uniq.length == segments.length
        raise ArgumentError, "Invalid option :segments. Every segment must have a unique :number."
      end
      if type == FRACTIONAL
        raise ArgumentError, "Missing option :maximum_fractional_value (required for FRACTIONAL segmentations)." unless options[:maximum_fractional_value].is_a?(Integer)
        raise ArgumentError, "Missing option :fractional_type (required for FRACTIONAL segmentations)." unless options[:fractional_type]
      end
      bits_allocated = type == BINARY ? 1 : (options[:bits_allocated] || 8)
      unless type == BINARY || [8, 16].include?(bits_allocated)
        raise ArgumentError, "Invalid option :bits_allocated. Expected 8 or 16 for FRACTIONAL segmentations, got #{bits_allocated.inspect}."
      end
      frames.each_with_index do |frame, i|
        unless segment_numbers.include?(frame[:segment])
          raise ArgumentError, "Invalid frame #{i}: Its :segment (#{frame[:segment].inspect}) does not match any defined segment number."
        end
        mask = frame[:mask]
        unless mask.is_a?(Array) && mask.length == rows && mask.all? {|row| row.is_a?(Array) && row.length == columns }
          raise ArgumentError, "Invalid frame #{i}: Its :mask is not a #{rows}x#{columns} array."
        end
        flat = mask.flatten
        if type == BINARY
          raise ArgumentError, "Invalid frame #{i}: BINARY masks may only contain the values 0 and 1." unless flat.all? {|v| v == 0 || v == 1 }
        else
          unless flat.all? {|v| v.is_a?(Integer) && v >= 0 && v <= options[:maximum_fractional_value] }
            raise ArgumentError, "Invalid frame #{i}: FRACTIONAL mask values must be integers in the range 0..#{options[:maximum_fractional_value]}."
          end
        end
      end
      dcm = DObject.new
      # SOP common & general image/series modules:
      dcm.add_element('0008,0016', SOP_CLASS_UID)
      dcm.add_element('0008,0018', options[:sop_instance_uid] || DICOM.generate_uid)
      dcm.add_element('0008,0008', "DERIVED\\PRIMARY")
      dcm.add_element('0008,0060', 'SEG')
      dcm.add_element('0020,000D', options[:study_instance_uid] || DICOM.generate_uid)
      dcm.add_element('0020,000E', options[:series_instance_uid] || DICOM.generate_uid)
      dcm.add_element('0020,0052', options[:frame_of_reference_uid] || DICOM.generate_uid)
      dcm.add_element('0020,0011', (options[:series_number] || 1).to_s)
      dcm.add_element('0020,0013', (options[:instance_number] || 1).to_s)
      # Image pixel module:
      dcm.add_element('0028,0002', 1)
      dcm.add_element('0028,0004', 'MONOCHROME2')
      dcm.add_element('0028,0008', frames.length.to_s)
      dcm.add_element('0028,0010', rows)
      dcm.add_element('0028,0011', columns)
      dcm.add_element('0028,0100', bits_allocated)
      dcm.add_element('0028,0101', type == BINARY ? 1 : bits_allocated)
      dcm.add_element('0028,0102', (type == BINARY ? 1 : bits_allocated) - 1)
      dcm.add_element('0028,0103', 0)
      # Segmentation image module:
      dcm.add_element('0062,0001', type)
      if type == FRACTIONAL
        dcm.add_element('0062,000E', options[:maximum_fractional_value])
        dcm.add_element('0062,0010', options[:fractional_type].to_s.upcase)
      end
      segment_sequence = dcm.add_sequence('0062,0002')
      segments.each do |segment|
        item = Item.new(:parent => segment_sequence)
        item.add_element('0062,0004', segment[:number])
        item.add_element('0062,0005', segment[:label].to_s) if segment[:label]
        item.add_element('0062,0008', segment[:algorithm_type].to_s.upcase) if segment[:algorithm_type]
      end
      # Shared functional groups (pixel measures & plane orientation):
      shared_item = Item.new(:parent => dcm.add_sequence('5200,9229'))
      if options[:pixel_spacing] || options[:slice_thickness]
        measures_item = Item.new(:parent => shared_item.add_sequence('0028,9110'))
        measures_item.add_element('0028,0030', options[:pixel_spacing].join("\\")) if options[:pixel_spacing]
        measures_item.add_element('0018,0050', options[:slice_thickness].to_s) if options[:slice_thickness]
      end
      if options[:orientation]
        orientation_item = Item.new(:parent => shared_item.add_sequence('0020,9116'))
        orientation_item.add_element('0020,0037', options[:orientation].join("\\"))
      end
      # Per-frame functional groups:
      per_frame = dcm.add_sequence('5200,9230')
      frames.each do |frame|
        item = Item.new(:parent => per_frame)
        identification_item = Item.new(:parent => item.add_sequence('0062,000A'))
        identification_item.add_element('0062,000B', frame[:segment])
        if frame[:position]
          position_item = Item.new(:parent => item.add_sequence('0020,9113'))
          position_item.add_element('0020,0032', frame[:position].join("\\"))
        end
        if frame[:orientation]
          orientation_item = Item.new(:parent => item.add_sequence('0020,9116'))
          orientation_item.add_element('0020,0037', frame[:orientation].join("\\"))
        end
        if frame[:referenced]
          derivation_item = Item.new(:parent => item.add_sequence('0008,9124'))
          source_item = Item.new(:parent => derivation_item.add_sequence('0008,2112'))
          source_item.add_element('0008,1150', frame[:referenced][:sop_class_uid].to_s)
          source_item.add_element('0008,1155', frame[:referenced][:sop_instance_uid].to_s)
          source_item.add_element('0008,1160', frame[:referenced][:frame_number].to_s) if frame[:referenced][:frame_number]
        end
      end
      # Pixel data:
      if type == BINARY
        # Bit-packed pixel data. Each frame is padded to a whole number of
        # bytes (a frame does not necessarily fill an integral number of bytes):
        pixel_bin = frames.collect {|frame| [frame[:mask].flatten.join].pack('b*') }.join
      else
        pixel_bin = dcm.encode_pixels(frames.collect {|frame| frame[:mask].flatten }.flatten)
      end
      pixel_element = Element.new('7FE0,0010', nil, :parent => dcm)
      pixel_element.bin = pixel_bin
      self.new(dcm)
    end

    # Gives the segmentation type of the data set ('BINARY' or 'FRACTIONAL').
    #
    # @return [String] the segmentation type
    #
    def segmentation_type
      @dcm.value('0062,0001')
    end

    # Gives the segmentation fractional type (e.g. 'PROBABILITY' or 'OCCUPANCY').
    #
    # @return [String, NilClass] the fractional type, or nil for BINARY segmentations
    #
    def fractional_type
      @dcm.value('0062,0010')
    end

    # Gives the maximum fractional value of a FRACTIONAL segmentation.
    #
    # @return [Integer, NilClass] the maximum fractional value, or nil for BINARY segmentations
    #
    def maximum_fractional_value
      @dcm.value('0062,000E')
    end

    # Gives the number of rows in the frame masks.
    #
    # @return [Integer] the number of rows
    #
    def rows
      @dcm.num_rows
    end

    # Gives the number of columns in the frame masks.
    #
    # @return [Integer] the number of columns
    #
    def columns
      @dcm.num_cols
    end

    # Gives the number of frames in the segmentation.
    #
    # @return [Integer] the number of frames
    #
    def num_frames
      @dcm.num_frames
    end

    # Gives the segment numbers defined in the Segment Sequence, sorted ascending.
    #
    # @return [Array<Integer>] the segment numbers
    #
    def segment_numbers
      segment_items.collect {|item| item.value('0062,0004') }.sort
    end

    # Gives the label of the specified segment.
    #
    # @param [Integer] segment_number a segment number
    # @return [String, NilClass] the segment label (nil if no label is defined)
    #
    def segment_label(segment_number)
      segment_item(segment_number).value('0062,0005')
    end

    # Gives the frame indices (in file order) which belong to the specified segment.
    #
    # @param [Integer] segment_number a segment number
    # @return [Array<Integer>] the frame indices of the segment
    #
    def frames(segment_number)
      check_segment(segment_number)
      frame_map.each_index.select {|i| frame_map[i][:segment] == segment_number }
    end

    # Gives the mask of a single frame of the specified segment, as a
    # two-dimensional (rows x columns) array of pixel values.
    #
    # @param [Integer] segment_number a segment number
    # @param [Integer] frame a frame index (as given by the frames method)
    # @return [Array<Array<Integer>>] the frame mask
    #
    def mask(segment_number, frame)
      check_frame(segment_number, frame)
      decode_frame(frame)
    end

    # Gives the masks of all frames belonging to the specified segment (in file order).
    #
    # @param [Integer] segment_number a segment number
    # @return [Array<Array<Array<Integer>>>] the frame masks of the segment
    #
    def masks(segment_number)
      frames(segment_number).collect {|frame| decode_frame(frame) }
    end

    # Gives the referenced image of a single frame of the specified segment.
    #
    # @param [Integer] segment_number a segment number
    # @param [Integer] frame a frame index (as given by the frames method)
    # @return [Hash, NilClass] a hash with :sop_class_uid, :sop_instance_uid & :frame_number (nil if the frame has no image reference)
    #
    def referenced_image(segment_number, frame)
      check_frame(segment_number, frame)
      frame_map[frame][:referenced]
    end

    # Gives the referenced images of all frames belonging to the specified segment (in file order).
    #
    # @param [Integer] segment_number a segment number
    # @return [Array<Hash, NilClass>] the referenced images of the segment
    #
    def referenced_images(segment_number)
      frames(segment_number).collect {|frame| frame_map[frame][:referenced] }
    end

    # Gives the patient position ([x, y, z]) of a single frame of the specified segment.
    #
    # @param [Integer] segment_number a segment number
    # @param [Integer] frame a frame index (as given by the frames method)
    # @return [Array<Float>, NilClass] the image position (patient) of the frame
    #
    def position(segment_number, frame)
      check_frame(segment_number, frame)
      frame_map[frame][:position]
    end

    # Gives the patient positions of all frames belonging to the specified segment (in file order).
    #
    # @param [Integer] segment_number a segment number
    # @return [Array<Array<Float>, NilClass>] the image positions of the segment
    #
    def positions(segment_number)
      frames(segment_number).collect {|frame| frame_map[frame][:position] }
    end

    # Gives the orientation of a single frame of the specified segment. Falls
    # back to the shared orientation when the frame carries no orientation of its own.
    #
    # @param [Integer] segment_number a segment number
    # @param [Integer] frame a frame index (as given by the frames method)
    # @return [Array<Float>, NilClass] the image orientation (patient) of the frame
    #
    def orientation(segment_number, frame)
      check_frame(segment_number, frame)
      frame_map[frame][:orientation] || shared_orientation
    end

    # Gives the orientations of all frames belonging to the specified segment (in file order).
    #
    # @param [Integer] segment_number a segment number
    # @return [Array<Array<Float>, NilClass>] the image orientations of the segment
    #
    def orientations(segment_number)
      frames(segment_number).collect {|frame| orientation(segment_number, frame) }
    end

    # Gives the pixel spacing ([row spacing, column spacing]) shared by the frames.
    #
    # @return [Array<Float>, NilClass] the pixel spacing (nil if not defined)
    #
    def pixel_spacing
      item = shared_measures_item
      item && item.value('0028,0030') ? ds_array(item.value('0028,0030')) : nil
    end

    # Gives the slice thickness shared by the frames.
    #
    # @return [Float, NilClass] the slice thickness (nil if not defined)
    #
    def slice_thickness
      item = shared_measures_item
      item && item.value('0018,0050') ? item.value('0018,0050').to_f : nil
    end

    # Returns the DObject instance which holds the segmentation data set.
    #
    # @return [DObject] self's DObject
    #
    def to_dcm
      @dcm
    end

    # Writes the segmentation to file.
    #
    # @param [String] file_name the path of the DICOM file which is to be written to disk
    # @param [Hash] options the options to use for writing the file (see DObject#write)
    #
    def write(file_name, options={})
      @dcm.write(file_name, options)
    end


    private


    # Raises ArgumentError unless the given segment number is defined.
    #
    def check_segment(segment_number)
      unless segment_numbers.include?(segment_number)
        raise ArgumentError, "Invalid argument 'segment_number'. No segment ##{segment_number} is defined (defined segments: #{segment_numbers.join(', ')})."
      end
    end

    # Raises ArgumentError unless the given frame belongs to the given segment.
    #
    def check_frame(segment_number, frame)
      unless frames(segment_number).include?(frame)
        raise ArgumentError, "Invalid argument 'frame'. Frame #{frame} does not belong to segment ##{segment_number} (its frames: #{frames(segment_number).join(', ')})."
      end
    end

    # Decodes the pixel values of a single frame to a two-dimensional (rows x columns) array.
    #
    def decode_frame(frame)
      if segmentation_type == BINARY
        # Bit-packed pixel data. Each frame occupies a whole number of bytes
        # (the last byte of a frame may hold padding bits):
        bytes_per_frame = (rows * columns + 7) / 8
        bin = pixel_bin.slice(frame * bytes_per_frame, bytes_per_frame) || ''
        pixels = bin.unpack('b*').first.slice(0, rows * columns).chars.collect {|bit| bit.to_i }
      else
        bytes_per_frame = rows * columns * (@dcm.value('0028,0100').to_i / 8)
        bin = pixel_bin.slice(frame * bytes_per_frame, bytes_per_frame) || ''
        pixels = @dcm.decode_pixels(bin)
      end
      Array.new(rows) {|r| pixels[r * columns, columns] }
    end

    # Converts a backslash separated DS string to an array of floats.
    #
    def ds_array(string)
      string.to_s.split("\\").collect {|value| value.to_f }
    end

    # Maps each frame of the Per-frame Functional Groups Sequence to its
    # segment, spatial information and image reference (in file order).
    #
    def frame_map
      @frame_map ||= per_frame_items.collect do |item|
        map = {}
        identification = item['0062,000A']
        identification_item = identification && identification.items.first
        map[:segment] = identification_item ? identification_item.value('0062,000B').to_i : nil
        position = item['0020,9113']
        position_item = position && position.items.first
        map[:position] = position_item && position_item.value('0020,0032') ? ds_array(position_item.value('0020,0032')) : nil
        orientation = item['0020,9116']
        orientation_item = orientation && orientation.items.first
        map[:orientation] = orientation_item && orientation_item.value('0020,0037') ? ds_array(orientation_item.value('0020,0037')) : nil
        referenced = nil
        derivation = item['0008,9124']
        derivation_item = derivation && derivation.items.first
        source = derivation_item && derivation_item['0008,2112']
        source_item = source && source.items.first
        if source_item
          referenced = {
            :sop_class_uid => source_item.value('0008,1150'),
            :sop_instance_uid => source_item.value('0008,1155')
          }
          frame_number = source_item.value('0008,1160')
          referenced[:frame_number] = frame_number.to_i if frame_number
        end
        map[:referenced] = referenced
        map
      end
    end

    # Gives the items of the Per-frame Functional Groups Sequence.
    #
    def per_frame_items
      sequence = @dcm['5200,9230']
      sequence ? sequence.items : []
    end

    # Gives the binary string of the Pixel Data element.
    #
    def pixel_bin
      element = @dcm['7FE0,0010']
      raise "The DICOM object contains no Pixel Data element (7FE0,0010)." unless element.is_a?(Element)
      element.bin
    end

    # Gives the Segment Sequence item of the specified segment number.
    #
    def segment_item(segment_number)
      check_segment(segment_number)
      segment_items.find {|item| item.value('0062,0004') == segment_number }
    end

    # Gives the items of the Segment Sequence.
    #
    def segment_items
      sequence = @dcm['0062,0002']
      sequence ? sequence.items : []
    end

    # Gives the (first) item of the Shared Functional Groups Sequence.
    #
    def shared_item
      sequence = @dcm['5200,9229']
      sequence ? sequence.items.first : nil
    end

    # Gives the (first) Pixel Measures Sequence item of the shared functional groups.
    #
    def shared_measures_item
      measures = shared_item && shared_item['0028,9110']
      measures ? measures.items.first : nil
    end

    # Gives the image orientation (patient) of the shared functional groups.
    #
    def shared_orientation
      orientation = shared_item && shared_item['0020,9116']
      item = orientation && orientation.items.first
      item && item.value('0020,0037') ? ds_array(item.value('0020,0037')) : nil
    end

  end

end
