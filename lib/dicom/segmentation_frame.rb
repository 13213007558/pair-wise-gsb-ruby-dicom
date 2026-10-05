module DICOM

  class SegmentationFrame

    attr_accessor :columns
    attr_reader :frame_number
    attr_accessor :image_orientation
    attr_accessor :image_position
    attr_reader :mask
    attr_accessor :pixel_spacing
    attr_accessor :reference
    attr_accessor :reference_frame_number
    attr_accessor :rows
    attr_reader :segment_number
    attr_accessor :slice_thickness
    attr_accessor :spacing_between_slices

    def initialize(segment_number, mask, options={})
      @segment_number = integer_option(:segment_number, segment_number)
      @mask = Array(mask).map { |value| value == true || value == false ? (value ? 1 : 0) : value.to_i }
      @rows = integer_option(:rows, options[:rows])
      @columns = integer_option(:columns, options[:columns])
      @frame_number = options[:frame_number]
      @reference_frame_number = options[:reference_frame_number] || options[:frame_of_reference_frame_number]
      @reference = options[:reference] || options[:reference_image] || options[:image]
      @pixel_spacing = numeric_option(options[:pixel_spacing])
      @image_position = numeric_option(options[:image_position] || options[:position])
      @image_orientation = numeric_option(options[:image_orientation] || options[:orientation])
      @slice_thickness = numeric_option(options[:slice_thickness])
      @spacing_between_slices = numeric_option(options[:spacing_between_slices])
      @slice_thickness = @slice_thickness.first if @slice_thickness
      @spacing_between_slices = @spacing_between_slices.first if @spacing_between_slices
      @frame_number = @frame_number.to_i if @frame_number
      @reference_frame_number = @reference_frame_number.to_i if @reference_frame_number
      validate
    end

    def binary?
      @mask.all? { |value| value == 0 || value == 1 }
    end

    def to_h
      {
        :segment_number => @segment_number,
        :frame_number => @frame_number,
        :reference_frame_number => @reference_frame_number,
        :rows => @rows,
        :columns => @columns,
        :mask => @mask.dup,
        :reference => @reference,
        :pixel_spacing => @pixel_spacing && @pixel_spacing.dup,
        :image_position => @image_position && @image_position.dup,
        :image_orientation => @image_orientation && @image_orientation.dup,
        :slice_thickness => @slice_thickness,
        :spacing_between_slices => @spacing_between_slices
      }
    end

    private

    def integer_option(name, value)
      return nil if value.nil?
      integer = value.to_i
      raise ArgumentError, "Invalid #{name}. Expected a positive integer, got #{value.inspect}." unless integer > 0
      integer
    end

    def numeric_option(value)
      return nil if value.nil?
      values = value.to_s.split('\\').map(&:strip) if value.is_a?(String)
      values ||= Array(value)
      values.map do |item|
        text = item.to_s
        text.include?('.') ? text.to_f : text.to_i
      end
    end

    def validate
      return unless @rows && @columns
      raise ArgumentError, "Mask has #{@mask.length} values, expected #{@rows * @columns}." unless @mask.length == @rows * @columns
    end

  end

end
