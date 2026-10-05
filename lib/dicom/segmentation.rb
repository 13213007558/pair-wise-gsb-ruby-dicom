module DICOM

  class Segmentation

    SEGMENTATION_SOP_CLASS_UID = '1.2.840.10008.5.1.4.1.1.66.4'

    BINARY = 'BINARY'
    FRACTIONAL = 'FRACTIONAL'
    OPAQUE = 'OPAQUE'
    PROBABILITY = 'PROBABILITY'

    TAGS = {
      :frame_type => '0008,9007',
      :source_image_sequence => '0008,2112',
      :source_image_evidence_sequence => '0008,9154',
      :referenced_sop_class_uid => '0008,1150',
      :referenced_sop_instance_uid => '0008,1155',
      :referenced_frame_number => '0008,1160',
      :referenced_series_sequence => '0008,1115',
      :referenced_instance_sequence => '0008,1199',
      :frame_of_reference_uid => '0020,0052',
      :plane_position_sequence => '0020,9113',
      :plane_orientation_sequence => '0020,9116',
      :image_position => '0020,0032',
      :image_orientation => '0020,0037',
      :pixel_measures_sequence => '0028,9110',
      :pixel_spacing => '0028,0030',
      :slice_thickness => '0018,0050',
      :spacing_between_slices => '0018,0088',
      :shared_functional_groups => '5200,9229',
      :per_frame_functional_groups => '5200,9230',
      :segment_identification_sequence => '0062,000A',
      :referenced_segment_number => '0062,000B',
      :segmentation_type => '0062,0001',
      :segment_sequence => '0062,0002',
      :segment_number => '0062,0004',
      :segment_label => '0062,0005',
      :segment_description => '0062,0006',
      :segment_algorithm_type => '0062,0008',
      :segment_algorithm_name => '0062,0009',
      :maximum_fractional_value => '0062,000E',
      :segmentation_fractional_type => '0062,0010',
      :content_label => '0070,0080',
      :content_description => '0070,0081',
      :pixel_data => '7FE0,0010'
    }

    attr_reader :columns
    attr_reader :fractional_type
    attr_reader :frames
    attr_reader :maximum_fractional_value
    attr_reader :options
    attr_reader :reference_resolver
    attr_reader :references
    attr_reader :rows
    attr_reader :segments
    attr_reader :source
    attr_reader :type

    def self.build(frames, options={})
      new(nil, frames, options)
    end
    class << self
      alias_method :create, :build
    end

    def self.parse(data, options={})
      dcm = data.respond_to?(:to_dcm) ? data.to_dcm : DObject.parse(data)
      new(dcm, nil, options)
    end

    def self.read(file, options={})
      new(DObject.read(file), nil, options)
    end
    class << self
      alias_method :from_dcm, :parse
      alias_method :from_file, :read
    end

    def initialize(source=nil, frames=nil, options={})
      if source.is_a?(Array) || source.is_a?(SegmentationFrame) || frame_hash?(source)
        source = [source] unless source.is_a?(Array)
        initialize(nil, source, frames || {})
        return
      end
      @source = source.respond_to?(:to_dcm) ? source.to_dcm : source
      @options = options.dup
      @reference_resolver = @options[:reference_resolver] || @options[:references]
      @frames = []
      @segments = {}
      @references = []
      if @source
        parse_source
      else
        build_from_frames(frames || [], @options)
      end
    end

    def [](segment_number)
      frames_for(segment_number)
    end

    def binary_mask(segment_number, index=0)
      values = mask(segment_number, index)
      values && values.map { |value| value != 0 }
    end

    def binary_masks(segment_number)
      masks(segment_number).map { |values| values.map { |value| value != 0 } }
    end

    def add_frame(frame)
      frame = frame.is_a?(SegmentationFrame) ? frame : SegmentationFrame.new(frame[:segment_number], frame[:mask], frame)
      complete_frame(frame)
      @frames << frame
      register_frame(frame)
      self
    end
    alias_method :add, :add_frame

    def binary?
      @type == BINARY
    end

    def columns=(value)
      @columns = value.to_i
      validate_dimensions
    end

    def rows=(value)
      @rows = value.to_i
      validate_dimensions
    end

    def frame(segment_number, index=0)
      segment_data = @segments[number(segment_number)]
      segment_data && segment_data[:frames][index]
    end

    def frame_count(segment_number=nil)
      segment_number ? frames_for(segment_number).length : @frames.length
    end
    alias_method :size, :frame_count
    alias_method :length, :frame_count

    def each_segment
      return enum_for(:each_segment) unless block_given?
      segment_numbers.each { |number| yield(number, @segments[number]) }
    end

    def frames_for(segment_number)
      @segments.fetch(number(segment_number), { :frames => [] })[:frames]
    end
    alias_method :frames_for_segment, :frames_for

    def fraction(segment_number, index=0)
      selected = frame(segment_number, index)
      return nil unless selected
      selected.mask.map { |value| value.to_f / @maximum_fractional_value }
    end
    alias_method :probabilities, :fraction
    alias_method :fractions, :fraction

    def fractional?
      @type == FRACTIONAL
    end

    def frames(segment_number=nil)
      segment_number ? frames_for(segment_number) : @frames
    end

    def mask(segment_number, index=0)
      selected = frame(segment_number, index)
      selected && selected.mask
    end
    alias_method :frame_mask, :mask
    alias_method :pixels, :mask

    def masks(segment_number)
      frames_for(segment_number).map(&:mask)
    end
    alias_method :frame_masks, :masks
    alias_method :values, :masks
    alias_method :scores, :masks

    def maximum_fraction(segment_number=nil)
      segment_number ? segment(segment_number)[:maximum_fractional_value] : @maximum_fractional_value
    end
    alias_method :max_fractional_value, :maximum_fraction

    def number(segment_number)
      segment_number.to_i
    end

    def reference_image(segment_number, index=0)
      selected = frame(segment_number, index)
      selected && resolve_reference(selected.reference)
    end

    def reference_images(segment_number)
      frames_for(segment_number).map { |selected| resolve_reference(selected.reference) }
    end
    alias_method :reference_images_for_segment, :reference_images

    def segment(segment_number)
      segment_data = @segments.fetch(number(segment_number)) { raise KeyError, "Unknown segment #{segment_number}." }
      segment_data.dup
    end

    def segment_numbers
      @segments.keys.sort
    end

    def segment_count
      @segments.length
    end

    alias_method :segmentation_type, :type
    alias_method :segmentation_fractional_type, :fractional_type

    def spatial_info(segment_number, index=0)
      selected = frame(segment_number, index)
      return nil unless selected
      {
        :rows => selected.rows,
        :columns => selected.columns,
        :pixel_spacing => selected.pixel_spacing,
        :image_position => selected.image_position,
        :image_orientation => selected.image_orientation,
        :slice_thickness => selected.slice_thickness,
        :spacing_between_slices => selected.spacing_between_slices
      }
    end
    alias_method :spatial_information, :spatial_info

    def spatial_infos(segment_number)
      frames_for(segment_number).each_with_index.map { |_, index| spatial_info(segment_number, index) }
    end
    alias_method :spatial_informations, :spatial_infos

    def to_binary
      Segmentation.new(nil, @frames.map { |frame| frame.to_h.merge(:mask => frame.mask.map { |value| value == 0 ? 0 : 1 }) }, @options.merge(:type => BINARY))
    end

    def to_fractional(options={})
      maximum = options[:maximum_fractional_value] || @maximum_fractional_value || 255
      fractional_type = options[:fractional_type] || @fractional_type || PROBABILITY
      Segmentation.new(nil, @frames.map(&:to_h), @options.merge(:type => FRACTIONAL, :maximum_fractional_value => maximum, :fractional_type => fractional_type))
    end

    def to_dcm
      write(DObject.new)
    end
    alias_method :to_dicom, :to_dcm

    def write(path_or_dcm=nil)
      if path_or_dcm.nil? || path_or_dcm.is_a?(String) || (defined?(Pathname) && path_or_dcm.is_a?(Pathname))
        dcm = to_dcm
        return dcm.write(path_or_dcm.to_s) if path_or_dcm
        dcm
      else
        populate_dcm(path_or_dcm.to_dcm)
      end
    end

    private

    def add_element(parent, tag, value, options={})
      parent.add(Element.new(tag, value, options))
    end

    def add_sequence(parent, tag)
      sequence = parent[tag] || Sequence.new(tag, :parent => parent)
      Item.new(:parent => sequence)
    end

    def all_same?(values)
      values.uniq.length == 1
    end

    def frame_hash?(value)
      value.is_a?(Hash) && (value.key?(:segment_number) || value.key?(:mask))
    end

    def build_from_frames(frames, options)
      @type = normalize_type(options[:type] || options[:segmentation_type] || infer_type(frames))
      @fractional_type = options[:fractional_type] || options[:segmentation_fractional_type]
      @maximum_fractional_value = integer_or_nil(options[:maximum_fractional_value] || options[:max_fractional_value])
      @rows = integer_or_nil(options[:rows])
      @columns = integer_or_nil(options[:columns])
      if @type == FRACTIONAL
        @fractional_type = normalize_fractional_type(@fractional_type || PROBABILITY)
        @maximum_fractional_value ||= frames.map { |frame| Array(frame[:mask] || frame[:pixels]).map { |value| value.to_i }.max }.compact.max || 255
        raise ArgumentError, 'Maximum fractional value must be positive.' unless @maximum_fractional_value > 0
      end
      @reference_resolver = options[:reference_resolver] || options[:references]
      Array(frames).each { |frame| add_frame(frame) }
      unless @rows && @columns
        frame_rows = @frames.map(&:rows).compact
        frame_columns = @frames.map(&:columns).compact
        @rows = frame_rows.first if all_same?(frame_rows)
        @columns = frame_columns.first if all_same?(frame_columns)
      end
      validate_dimensions
      apply_segment_options
    end

    def apply_segment_options
      configured = @options[:segments] || @options[:segment_metadata] || {}
      configured = configured.each_with_object({}) { |segment, result| result[segment[:number] || segment[:segment_number]] = segment } if configured.is_a?(Array)
      @segments.each do |number, segment_data|
        segment_options = configured[number] || configured[number.to_s] || {}
        { :label => :label, :description => :description, :algorithm_type => :algorithm_type,
          :algorithm_name => :algorithm_name }.each do |option_key, data_key|
          segment_data[data_key] = segment_options[option_key] || segment_options[data_key] || segment_data[data_key]
        end
      end
    end

    def complete_frame(frame)
      infer_frame_dimensions(frame)
      reference = resolve_reference(frame.reference)
      if reference
        frame.image_position ||= read_ds(reference, TAGS[:image_position])
        frame.image_orientation ||= read_ds(reference, TAGS[:image_orientation])
        frame.pixel_spacing ||= read_ds(reference, TAGS[:pixel_spacing])
        frame.slice_thickness ||= Array(read_ds(reference, TAGS[:slice_thickness])).first
        frame.spacing_between_slices ||= Array(read_ds(reference, TAGS[:spacing_between_slices])).first
        frame.reference_frame_number ||= 1
      end
      validate_frame(frame)
    end

    def copy_metadata(dcm)
      copy_source_metadata(dcm) if @source
      add_element(dcm, '0020,0052', frame_of_reference_uid) if !dcm.exists?('0020,0052') && frame_of_reference_uid
    end

    def copy_source_metadata(dcm)
      tags = %w(
        0008,0020 0008,0021 0008,0022 0008,0023 0008,0030 0008,0031 0008,0032 0008,0033
        0008,0050 0008,0070 0008,0080 0008,0081 0008,0090 0008,1010 0008,1030 0008,103E
        0010,0010 0010,0020 0010,0030 0010,0040 0020,000D 0020,0052
      )
      tags.each do |tag|
        next if dcm.exists?(tag) || !@source.exists?(tag)
        source_element = @source[tag]
        add_element(dcm, tag, source_element.value, :vr => source_element.vr)
      end
    end

    def effective_item(frame_item, tag)
      sequence_item(frame_item, tag) || sequence_item(shared_item, tag)
    end

    def frame_byte_length
      binary? ? ((@rows * @columns) / 8.0).ceil : @rows * @columns
    end

    def item(parent, tag, index=0)
      sequence = parent[tag]
      sequence && sequence[index]
    end

    def parse_frame(index, raw_frame, frame_item)
      segment_item = effective_item(frame_item, TAGS[:segment_identification_sequence])
      segment_number = segment_item.value(TAGS[:referenced_segment_number])
      mask = if binary?
        raw_frame.each_byte.flat_map { |byte| 7.downto(0).map { |bit| (byte >> bit) & 1 } }.first(@rows * @columns)
      else
        raw_frame.bytes.first(@rows * @columns)
      end
      position_item = effective_item(frame_item, TAGS[:plane_position_sequence])
      orientation_item = effective_item(frame_item, TAGS[:plane_orientation_sequence])
      measures_item = effective_item(frame_item, TAGS[:pixel_measures_sequence])
      source_item = item(frame_item, TAGS[:source_image_sequence]) || item(frame_item, TAGS[:source_image_evidence_sequence])
      reference = source_reference(source_item) if source_item
      SegmentationFrame.new(segment_number, mask, {
        :rows => @rows,
        :columns => @columns,
        :frame_number => index + 1,
        :reference => reference,
        :reference_frame_number => source_item && source_item.value(TAGS[:referenced_frame_number]) && source_item.value(TAGS[:referenced_frame_number]).to_i,
        :image_position => position_item && numeric_value(position_item.value(TAGS[:image_position])),
        :image_orientation => orientation_item && numeric_value(orientation_item.value(TAGS[:image_orientation])),
        :pixel_spacing => measures_item && numeric_value(measures_item.value(TAGS[:pixel_spacing])),
        :slice_thickness => measures_item && numeric_value(measures_item.value(TAGS[:slice_thickness])) && Array(numeric_value(measures_item.value(TAGS[:slice_thickness]))).first,
        :spacing_between_slices => measures_item && numeric_value(measures_item.value(TAGS[:spacing_between_slices])) && Array(numeric_value(measures_item.value(TAGS[:spacing_between_slices]))).first
      })
    end

    def parse_segments
      @source[TAGS[:segment_sequence]].children.each do |segment_item|
        number = segment_item.value(TAGS[:segment_number])
        @segments[number] = {
          :number => number,
          :label => segment_item.value(TAGS[:segment_label]),
          :description => segment_item.value(TAGS[:segment_description]),
          :algorithm_type => segment_item.value(TAGS[:segment_algorithm_type]),
          :algorithm_name => segment_item.value(TAGS[:segment_algorithm_name]),
          :maximum_fractional_value => segment_item.value(TAGS[:maximum_fractional_value]),
          :fractional_type => segment_item.value(TAGS[:segmentation_fractional_type]),
          :frames => []
        }
      end
    end

    def parse_source
      raise ArgumentError, 'Expected a DICOM Segmentation object.' unless @source.value(TAGS[:segmentation_type])
      @type = @source.value(TAGS[:segmentation_type]).to_s.upcase
      @rows = @source.num_rows
      @columns = @source.num_cols
      parse_segments
      @maximum_fractional_value = @segments.values.map { |segment| segment[:maximum_fractional_value] }.compact.max
      @fractional_type = normalize_fractional_type(@segments.values.map { |segment| segment[:fractional_type] }.compact.first) if fractional?
      pixel_bin = @source[TAGS[:pixel_data]].bin
      per_frame = @source[TAGS[:per_frame_functional_groups]]
      length = frame_byte_length
      per_frame.children.each_with_index do |frame_item, index|
        raw_frame = pixel_bin.byteslice(index * length, length).to_s
        frame = parse_frame(index, raw_frame, frame_item)
        @frames << frame
        @segments[frame.segment_number][:frames] << frame
      end
      @references = parse_references
      merge_parsed_references
      register_references
      self
    end

    def merge_parsed_references
      @frames.each do |frame|
        next unless frame.reference.is_a?(Hash)
        parsed_reference = @references.find do |reference|
          reference[:sop_instance_uid] == frame.reference[:sop_instance_uid]
        end
        if parsed_reference
          frame.reference = parsed_reference.merge(:reference_frame_number => frame.reference_frame_number)
        else
          frame.reference = frame.reference.merge(:reference_frame_number => frame.reference_frame_number)
        end
      end
    end

    def parse_references
      references = []
      sequence = @source[TAGS[:referenced_series_sequence]]
      return references unless sequence
      sequence.children.each do |series_item|
        series_uid = series_item.value('0020,000E')
        Array(series_item[TAGS[:referenced_instance_sequence]]).each do |instance_sequence|
          instance_sequence.children.each do |instance_item|
            references << {
              :series_instance_uid => series_uid,
              :sop_class_uid => instance_item.value(TAGS[:referenced_sop_class_uid]),
              :sop_instance_uid => instance_item.value(TAGS[:referenced_sop_instance_uid])
            }
          end
        end
      end
      references
    end

    def populate_dcm(dcm)
      validate_dimensions
      register_references
      copy_metadata(dcm)
      write_core_elements(dcm)
      write_segment_sequence(dcm)
      write_references(dcm)
      write_functional_groups(dcm)
      write_pixel_data(dcm)
      dcm.transfer_syntax = EXPLICIT_LITTLE_ENDIAN
      dcm
    end

    def ds(value)
      return nil if value.nil?
      Array(value).map { |number| number.to_s }.join('\\')
    end

    def first_frame_for_reference
      @frames.first
    end

    def frame_of_reference_uid
      reference = resolve_reference(first_frame_for_reference.reference)
      reference && reference.value(TAGS[:frame_of_reference_uid])
    end

    def infer_frame_dimensions(frame)
      frame.rows = @rows if frame.rows.nil? && @rows
      frame.columns = @columns if frame.columns.nil? && @columns
      unless frame.rows && frame.columns
        reference = resolve_reference(frame.reference)
        if reference
          frame.rows = reference.num_rows if frame.rows.nil? && reference.num_rows
          frame.columns = reference.num_cols if frame.columns.nil? && reference.num_cols
        end
      end
    end

    def infer_type(frames)
      frames.any? { |frame| Array(frame[:mask] || frame[:pixels]).any? { |value| value.to_i > 1 } } ? FRACTIONAL : BINARY
    end

    def integer_or_nil(value)
      value.nil? ? nil : value.to_i
    end

    def normalize_type(type)
      normalized = type.to_s.upcase
      unless [BINARY, FRACTIONAL].include?(normalized)
        raise ArgumentError, "Invalid segmentation type #{type.inspect}. Expected BINARY or FRACTIONAL."
      end
      normalized
    end

    def normalize_fractional_type(type)
      normalized = type.to_s.upcase
      unless [OPAQUE, PROBABILITY].include?(normalized)
        raise ArgumentError, "Invalid fractional type #{type.inspect}. Expected OPAQUE or PROBABILITY."
      end
      normalized
    end

    def numeric_value(value)
      return nil if value.nil?
      value.to_s.split('\\').map { |item| item.include?('.') ? item.to_f : item.to_i }
    end

    def read_ds(dcm, tag)
      numeric_value(dcm.value(tag))
    end

    def sequence_item(parent, tag)
      return nil unless parent && parent[tag]
      parent[tag][0]
    end

    def set(parent, tag, value, options={})
      parent.delete(tag) if parent.exists?(tag)
      add_element(parent, tag, value, options)
    end

    def set_ds(parent, tag, value)
      set(parent, tag, ds(value), :vr => 'DS')
    end

    def shared_item
      item(@source, TAGS[:shared_functional_groups])
    end

    def source_reference(source_item)
      uid = source_item.value(TAGS[:referenced_sop_instance_uid])
      reference = @options[:reference_resolver] || @options[:references]
      candidates = Array(reference)
      candidates.find { |candidate| candidate.respond_to?(:value) && candidate.value('0008,0018') == uid } || {
        :sop_class_uid => source_item.value(TAGS[:referenced_sop_class_uid]),
        :sop_instance_uid => uid,
        :reference_frame_number => source_item.value(TAGS[:referenced_frame_number])
      }
    end

    def write_core_elements(dcm)
      set(dcm, '0008,0016', SEGMENTATION_SOP_CLASS_UID, :vr => 'UI')
      set(dcm, '0008,0018', @options[:sop_instance_uid] || DICOM.generate_uid(UID_ROOT, 66), :vr => 'UI')
      set(dcm, '0008,0060', 'SEG', :vr => 'CS')
      set(dcm, '0008,0064', @options[:conversion_type] || 'WSD', :vr => 'CS')
      set(dcm, '0008,0008', 'DERIVED\\PRIMARY', :vr => 'CS')
      set(dcm, '0020,000E', @options[:series_instance_uid] || DICOM.generate_uid(UID_ROOT, 67), :vr => 'UI')
      set(dcm, '0020,0011', @options[:series_number] || 999, :vr => 'IS')
      set(dcm, '0020,0013', @options[:instance_number] || 1, :vr => 'IS')
      set(dcm, '0070,0080', @options[:content_label] || 'SEGMENTATION', :vr => 'CS')
      set(dcm, '0070,0081', @options[:content_description] || 'Segmentation', :vr => 'LO')
      set(dcm, '0008,103E', @options[:series_description] || 'Segmentation', :vr => 'LO')
      set(dcm, TAGS[:segmentation_type], @type, :vr => 'CS')
      set(dcm, '0028,0002', 1, :vr => 'US')
      set(dcm, '0028,0004', 'MONOCHROME2', :vr => 'CS')
      set(dcm, '0028,0008', @frames.length, :vr => 'IS')
      set(dcm, '0028,0010', @rows, :vr => 'US')
      set(dcm, '0028,0011', @columns, :vr => 'US')
      set(dcm, '0028,0100', binary? ? 1 : 8, :vr => 'US')
      set(dcm, '0028,0101', 1, :vr => 'US')
      set(dcm, '0028,0103', 0, :vr => 'US')
      set(dcm, '0028,2110', '00', :vr => 'CS')
    end

    def write_functional_groups(dcm)
      dcm.delete(TAGS[:per_frame_functional_groups]) if dcm.exists?(TAGS[:per_frame_functional_groups])
      sequence = Sequence.new(TAGS[:per_frame_functional_groups], :parent => dcm)
      @frames.each do |frame|
        frame_item = Item.new(:parent => sequence)
        set(frame_item, '0008,9007', 'DERIVED\\PRIMARY', :vr => 'CS')
        segment_item = add_sequence(frame_item, TAGS[:segment_identification_sequence])
        set(segment_item, TAGS[:referenced_segment_number], frame.segment_number, :vr => 'US')
        if frame.reference
          reference = resolve_reference(frame.reference) || frame.reference
          source_item = add_sequence(frame_item, TAGS[:source_image_sequence])
          reference_data = reference.is_a?(Hash) ? reference : reference_hash(reference)
          class_uid = reference_data[:sop_class_uid] || (reference.respond_to?(:value) ? reference.value('0008,0016') : nil)
          instance_uid = reference_data[:sop_instance_uid] || (reference.respond_to?(:value) ? reference.value('0008,0018') : nil)
          set(source_item, TAGS[:referenced_sop_class_uid], class_uid, :vr => 'UI')
          set(source_item, TAGS[:referenced_sop_instance_uid], instance_uid, :vr => 'UI')
          set(source_item, TAGS[:referenced_frame_number], (frame.reference_frame_number || 1).to_s, :vr => 'IS')
          purpose_item = add_sequence(source_item, '0040,A170')
          set(purpose_item, '0008,0100', '121322', :vr => 'SH')
          set(purpose_item, '0008,0102', 'DCM', :vr => 'SH')
          set(purpose_item, '0008,0104', 'Source image for image processing operation', :vr => 'LO')
        end
        if frame.image_position
          position_item = add_sequence(frame_item, TAGS[:plane_position_sequence])
          set_ds(position_item, TAGS[:image_position], frame.image_position)
        end
        if frame.image_orientation
          orientation_item = add_sequence(frame_item, TAGS[:plane_orientation_sequence])
          set_ds(orientation_item, TAGS[:image_orientation], frame.image_orientation)
        end
        measures_item = add_sequence(frame_item, TAGS[:pixel_measures_sequence])
        set_ds(measures_item, TAGS[:pixel_spacing], frame.pixel_spacing || [1, 1])
        set_ds(measures_item, TAGS[:slice_thickness], [frame.slice_thickness || 1])
        if frame.spacing_between_slices
          set_ds(measures_item, TAGS[:spacing_between_slices], [frame.spacing_between_slices])
        end
      end
    end

    def write_pixel_data(dcm)
      dcm.delete(TAGS[:pixel_data]) if dcm.exists?(TAGS[:pixel_data])
      bin = if binary?
        bytes = Array.new(frame_byte_length * @frames.length, 0)
        @frames.each_with_index do |frame, frame_index|
          frame_start = frame_index * frame_byte_length * 8
          frame.mask.each_with_index do |value, pixel_index|
            global_index = frame_start + pixel_index
            bytes[global_index / 8] |= (value & 1) << (7 - global_index % 8)
          end
        end
        bytes.pack('C*')
      else
        bin = @frames.flat_map(&:mask).pack('C*')
        bin += "\x00" if bin.length.odd?
        bin
      end
      Element.new(TAGS[:pixel_data], bin, :encoded => true, :vr => 'OB', :parent => dcm)
    end

    def write_references(dcm)
      dcm.delete(TAGS[:referenced_series_sequence]) if dcm.exists?(TAGS[:referenced_series_sequence])
      return if @references.empty?
      series_sequence = Sequence.new(TAGS[:referenced_series_sequence], :parent => dcm)
      @references.group_by { |reference| reference[:series_instance_uid] }.each do |series_uid, references|
        series_item = Item.new(:parent => series_sequence)
        set(series_item, '0020,000E', series_uid, :vr => 'UI') if series_uid
        instance_sequence = Sequence.new(TAGS[:referenced_instance_sequence], :parent => series_item)
        references.each do |reference|
          instance_item = Item.new(:parent => instance_sequence)
          set(instance_item, TAGS[:referenced_sop_class_uid], reference[:sop_class_uid], :vr => 'UI')
          set(instance_item, TAGS[:referenced_sop_instance_uid], reference[:sop_instance_uid], :vr => 'UI')
        end
      end
    end

    def write_segment_sequence(dcm)
      dcm.delete(TAGS[:segment_sequence]) if dcm.exists?(TAGS[:segment_sequence])
      dcm.delete(TAGS[:maximum_fractional_value]) if dcm.exists?(TAGS[:maximum_fractional_value])
      dcm.delete(TAGS[:segmentation_fractional_type]) if dcm.exists?(TAGS[:segmentation_fractional_type])
      sequence = Sequence.new(TAGS[:segment_sequence], :parent => dcm)
      @segments.keys.sort.each do |number|
        data = @segments[number]
        segment_item = Item.new(:parent => sequence)
        set(segment_item, TAGS[:segment_number], number, :vr => 'US')
        set(segment_item, TAGS[:segment_label], data[:label] || "Segment #{number}", :vr => 'LO')
        set(segment_item, TAGS[:segment_algorithm_type], data[:algorithm_type] || 'MANUAL', :vr => 'CS')
        if data[:algorithm_name]
          set(segment_item, TAGS[:segment_algorithm_name], data[:algorithm_name], :vr => 'LO')
        end
        if fractional?
          set(segment_item, TAGS[:maximum_fractional_value], data[:maximum_fractional_value] || @maximum_fractional_value, :vr => 'US')
          set(segment_item, TAGS[:segmentation_fractional_type], data[:fractional_type] || @fractional_type, :vr => 'CS')
        end
      end
    end

    def register_frame(frame)
      number = frame.segment_number
      segment_data = @segments[number] ||= {
        :number => number,
        :label => "Segment #{number}",
        :description => nil,
        :algorithm_type => 'MANUAL',
        :algorithm_name => nil,
        :frames => []
      }
      segment_data[:frames] << frame
      segment_data[:maximum_fractional_value] = @maximum_fractional_value if fractional?
      segment_data[:fractional_type] = @fractional_type if fractional?
    end

    def register_references
      @frames.each do |frame|
        next unless frame.reference
        resolved = resolve_reference(frame.reference)
        reference = resolved ? reference_hash(resolved) : reference_hash(frame.reference)
        @references << reference unless @references.any? { |existing| existing[:sop_instance_uid] == reference[:sop_instance_uid] }
      end
    end

    def reference_hash(reference)
      if reference.is_a?(Hash)
        {
          :sop_class_uid => reference[:sop_class_uid] || reference[:class_uid] || reference[:sop_class],
          :sop_instance_uid => reference[:sop_instance_uid] || reference[:instance_uid] || reference[:sop_instance],
          :series_instance_uid => reference[:series_instance_uid] || reference[:series_uid]
        }
      else
        dcm = reference
        {
          :sop_class_uid => dcm.value('0008,0016'),
          :sop_instance_uid => dcm.value('0008,0018'),
          :series_instance_uid => dcm.value('0020,000E')
        }
      end
    end

    def resolve_reference(reference)
      return nil if reference.nil?
      return reference if reference.respond_to?(:value)
      if reference.is_a?(Hash) && reference[:dcm]
        return reference[:dcm]
      end
      uid = reference.is_a?(Hash) ? (reference[:sop_instance_uid] || reference[:instance_uid] || reference[:sop_instance]) : reference
      candidates = Array(@reference_resolver)
      found = candidates.find { |candidate| candidate.respond_to?(:value) && candidate.value('0008,0018') == uid }
      found || candidates.find { |candidate| candidate.is_a?(Hash) && (candidate[:sop_instance_uid] == uid || candidate[:instance_uid] == uid) && candidate[:dcm] }
    end

    def validate_dimensions
      return if @frames.empty?
      @frames.each do |frame|
        frame.rows ||= @rows
        frame.columns ||= @columns
        raise ArgumentError, "Rows and columns are required for every segmentation frame." unless frame.rows && frame.columns
      end
      raise ArgumentError, "Frames have inconsistent rows." unless all_same?(@frames.map(&:rows))
      raise ArgumentError, "Frames have inconsistent columns." unless all_same?(@frames.map(&:columns))
      @rows = @frames.first.rows
      @columns = @frames.first.columns
      @frames.each { |frame| raise ArgumentError, "Mask has #{frame.mask.length} values, expected #{@rows * @columns}." unless frame.mask.length == @rows * @columns }
    end

    def validate_frame(frame)
      raise ArgumentError, "Segment number must be positive." unless frame.segment_number > 0
      if fractional?
        frame.mask.each do |value|
          raise ArgumentError, "Fractional mask values must be between 0 and #{@maximum_fractional_value}." unless value >= 0 && value <= @maximum_fractional_value
        end
      else
        frame.mask.each do |value|
          raise ArgumentError, "Binary mask values must be 0 or 1." unless value == 0 || value == 1
        end
      end
    end

  end

end
