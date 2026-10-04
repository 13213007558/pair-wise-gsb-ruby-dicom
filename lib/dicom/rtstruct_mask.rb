# frozen_string_literal: true

module DICOM

  # Converts closed planar RTSTRUCT contours to a binary target image grid.
  #
  # Target geometry is always supplied explicitly as patient coordinates. Slice
  # selection is based on contour coordinates only; Contour Image Sequence
  # references and item/instance order are not used to infer slices.
  #
  class RTSTRUCTMask

    # Holds the binary mask and contours which could not be assigned to a plane.
    #
    class Result
      attr_reader :mask, :out_of_tolerance_contours

      def initialize(mask, out_of_tolerance_contours)
        @mask = mask
        @out_of_tolerance_contours = out_of_tolerance_contours
      end

      def out_of_tolerance?
        @out_of_tolerance_contours.any?
      end
    end

    EPSILON = 1e-9

    # Converts patient-coordinate contours to a binary grid.
    #
    # @param [Array<Array<Array<Numeric>>>] contours closed planar contours as arrays of [x, y, z] points
    # @param [Integer] columns number of columns in the target grid
    # @param [Integer] rows number of rows in the target grid
    # @param [Integer] frames number of frames in the target grid
    # @param [Array<Numeric>] position Image Position Patient (patient coordinate of voxel column 0, row 0, frame 0)
    # @param [Array<Numeric>] orientation Image Orientation Patient, ordered [row_x, row_y, row_z, column_x, column_y, column_z]
    # @param [Array<Numeric>] spacing voxel spacing in millimetres, ordered [column, row, frame]
    # @param [Numeric] tolerance maximum allowed point-to-target-plane distance in millimetres
    # @return [RTSTRUCTMask::Result]
    #
    def self.convert(contours, options={})
      new(options).convert(contours)
    end

    define_singleton_method(:to_mask, method(:convert))

    # Extracts closed planar contours from an RTSTRUCT DObject and converts them.
    #
    # @param [DObject] rtstruct an RTSTRUCT DICOM object
    # @option options [Object] :roi_number optional Referenced ROI Number to convert
    # @return [RTSTRUCTMask::Result]
    #
    def self.from_rtstruct(rtstruct, options={})
      options = options.dup
      roi_number = options.delete(:roi_number)
      new(options).convert(extract_contours(rtstruct, roi_number))
    end

    def initialize(options={})
      @columns = validate_dimension(fetch_option(options, :columns), 'columns')
      @rows = validate_dimension(fetch_option(options, :rows), 'rows')
      @frames = validate_dimension(fetch_option(options, :frames), 'frames')
      @position = validate_vector(fetch_option(options, :position), 3, 'position')
      @row_direction, @column_direction = validate_orientation(fetch_option(options, :orientation))
      @column_spacing, @row_spacing, @frame_spacing = validate_spacing(fetch_option(options, :spacing))
      @tolerance = validate_positive_number(options.fetch(:tolerance, 0.5), 'tolerance', allow_zero: true)
      @frame_direction = cross_product(@row_direction, @column_direction)
    end

    def convert(contours)
      contours = Array(contours)
      validate_contours(contours)
      contours = contours.map { |item| normalized_contour(item) }
      mask = Array.new(@frames) { Array.new(@rows) { Array.new(@columns, 0) } }
      out_of_tolerance = []

      contours.group_by { |contour| contour.is_a?(Hash) ? contour[:roi_number] : nil }.each do |roi_number, roi_contours|
        roi_mask = Array.new(@frames) { Array.new(@rows) { Array.new(@columns, 0) } }
        roi_contours.each_with_index do |contour, contour_index|
          projected = project_contour(contour)
          nearest_frame = nearest_frame(projected)
          nearest_distance = projected.map { |point| (point[:frame] - nearest_frame).abs * @frame_spacing }.max

          if !nearest_frame.between?(0, @frames - 1) || nearest_distance > @tolerance + EPSILON
            report = {
              contour_index: contour.is_a?(Hash) && contour.key?(:contour_index) ? contour[:contour_index] : contour_index,
              roi_number: roi_number,
              contour_number: contour.is_a?(Hash) ? contour[:contour_number] : nil,
              nearest_frame: nearest_frame,
              distance: nearest_distance
            }.reject { |_key, value| value.nil? }
            out_of_tolerance << report
          else
            rasterize(projected, nearest_frame, roi_mask)
          end
        end
        combine_masks(mask, roi_mask)
      end

      Result.new(mask, out_of_tolerance)
    end

    alias_method :to_mask, :convert

    def self.extract_contours(rtstruct, selected_roi_number = nil)
      selected_roi_number = selected_roi_number.to_s if selected_roi_number
      contours = []
      roi_contour_sequence = rtstruct['3006,0039']
      return contours unless roi_contour_sequence

      roi_contour_sequence.children.each do |roi_item|
        referenced_number = roi_item['3006,0084']
        roi_number = referenced_number ? referenced_number.value.to_s : nil
        next if selected_roi_number && roi_number != selected_roi_number

        contour_sequence = roi_item['3006,0040']
        next unless contour_sequence

        contour_sequence.children.each_with_index do |contour_item, contour_index|
          type_item = contour_item['3006,0042']
          next unless type_item && type_item.value == 'CLOSED_PLANAR'

          data_item = contour_item['3006,0050']
          next unless data_item
          points = parse_contour_data(data_item.value)
          next unless valid_points?(points)

          contours << {
            roi_number: roi_number,
            contour_number: contour_item['3006,0048'] ? contour_item['3006,0048'].value : nil,
            contour_index: contour_index,
            points: points
          }
        end
      end
      contours
    end

    def self.valid_points?(points)
      points.is_a?(Array) && points.length >= 3 && points.all? do |point|
        point.is_a?(Array) && point.length == 3 && point.all? { |value| value.is_a?(Numeric) }
      end
    end

    private

    def normalized_contour(contour)
      points = contour.is_a?(Hash) ? contour[:points] : contour
      normalized_points = points.length > 1 && points.first == points.last ? points[0...-1] : points
      contour.is_a?(Hash) ? contour.merge(points: normalized_points) : normalized_points
    end

    def project_contour(contour)
      points = contour.is_a?(Hash) ? contour[:points] : contour
      points.map do |point|
        relative = vector_subtract(point, @position)
        {
          column: dot_product(relative, @column_direction) / @column_spacing,
          row: dot_product(relative, @row_direction) / @row_spacing,
          frame: dot_product(relative, @frame_direction) / @frame_spacing
        }
      end
    end

    def nearest_frame(projected)
      minimum_frame = projected.map { |point| point[:frame] }.min
      maximum_frame = projected.map { |point| point[:frame] }.max
      center = (minimum_frame + maximum_frame) / 2.0
      candidates = [center.floor, center.ceil, 0, @frames - 1].uniq.select do |candidate|
        candidate.between?(0, @frames - 1)
      end
      candidates.min_by do |candidate|
        projected.map { |point| (point[:frame] - candidate).abs }.max
      end
    end

    def rasterize(projected, frame, mask)
      frame_mask = mask[frame]
      min_row = projected.map { |point| point[:row] }.min.floor
      max_row = (projected.map { |point| point[:row] }.max - 0.5).floor
      min_row = 0 if min_row < 0
      max_row = @rows - 1 if max_row >= @rows

      min_row.upto(max_row) do |row|
        intersections = []
        projected.each_cons(2) do |first, second|
          next unless edge_crosses_row?(first[:row], second[:row], row)
          fraction = (row - first[:row]).to_f / (second[:row] - first[:row])
          intersections << first[:column] + fraction * (second[:column] - first[:column])
        end
        first_point = projected.first
        last_point = projected.last
        if edge_crosses_row?(last_point[:row], first_point[:row], row)
          fraction = (row - last_point[:row]).to_f / (first_point[:row] - last_point[:row])
          intersections << last_point[:column] + fraction * (first_point[:column] - last_point[:column])
        end

        intersections.sort!.each_slice(2) do |start_column, end_column|
          break unless end_column
          start_index = start_column.floor
          end_index = (end_column - 0.5).floor
          start_index = 0 if start_index < 0
          end_index = @columns - 1 if end_index >= @columns
          start_index.upto(end_index) { |column| frame_mask[row][column] ^= 1 }
        end
      end
    end

    def combine_masks(target, source)
      target.each_with_index do |frame, frame_index|
        frame.each_with_index do |row, row_index|
          row.each_index do |column|
            target[frame_index][row_index][column] |= source[frame_index][row_index][column]
          end
        end
      end
    end

    # Voxel centers are tested. Exact boundaries are half-open: minimum-row and
    # interval-start boundaries are covered, while maximum-row and interval-end
    # boundaries are not.
    def edge_crosses_row?(first_row, second_row, row)
      return false if first_row == second_row
      if first_row < second_row
        first_row <= row && row < second_row
      else
        second_row <= row && row < first_row
      end
    end

    def validate_contours(contours)
      raise ArgumentError, "Expected an Array of contours, got #{contours.class}." unless contours.is_a?(Array)
      contours.each_with_index do |contour, index|
        points = contour.is_a?(Hash) ? contour[:points] : contour
        unless contour.is_a?(Array) || (contour.is_a?(Hash) && contour.key?(:points))
          raise ArgumentError, "Contour #{index} must be an Array of points or a Hash containing a :points Array."
        end
        unless self.class.valid_points?(points)
          raise ArgumentError, "Contour #{index} must contain at least three [x, y, z] numeric points."
        end
      end
      contours
    end

    def validate_dimension(value, name)
      value = value.to_i if value.is_a?(String) && value =~ /\A\d+\z/
      raise ArgumentError, "Expected #{name} to be a positive Integer, got #{value.inspect}." unless value.is_a?(Integer) && value > 0
      value
    end

    def fetch_option(options, key)
      raise ArgumentError, "Missing required option :#{key}." unless options.key?(key)
      options[key]
    end

    def validate_spacing(value)
      spacing = validate_vector(value, 3, 'spacing')
      spacing.each_with_index do |item, index|
        unless item.is_a?(Numeric) && item > 0
          raise ArgumentError, "spacing[#{index}] must be greater than zero, got #{item.inspect}."
        end
      end
      spacing
    end

    def validate_positive_number(value, name, allow_zero: false)
      valid = value.is_a?(Numeric) && (allow_zero ? value >= 0 : value > 0)
      raise ArgumentError, "Expected #{name} to be a non-negative number, got #{value.inspect}." unless valid
      value.to_f
    end

    def validate_vector(value, length, name)
      unless value.is_a?(Array) && value.length == length && value.all? { |item| item.is_a?(Numeric) }
        raise ArgumentError, "Expected #{name} to be an Array of #{length} numbers, got #{value.inspect}."
      end
      value.map(&:to_f)
    end

    def validate_orientation(value)
      values = validate_vector(value, 6, 'orientation')
      row = values[0, 3]
      column = values[3, 3]
      unless unit_vector?(row) && unit_vector?(column)
        raise ArgumentError, "orientation row and column vectors must be unit vectors, got #{value.inspect}."
      end
      if dot_product(row, column).abs > EPSILON
        raise ArgumentError, "orientation row and column vectors must be perpendicular, got #{value.inspect}."
      end
      [row, column]
    end

    def unit_vector?(vector)
      (Math.sqrt(dot_product(vector, vector)) - 1.0).abs < 1e-6
    end

    def self.parse_contour_data(value)
      values = value.is_a?(Array) ? value.map(&:to_s) : value.to_s.split('\\').map(&:strip)
      values.each_slice(3).map { |point| point.map { |number| Float(number) } }
    rescue ArgumentError, TypeError
      []
    end

    def vector_subtract(first, second)
      [first[0] - second[0], first[1] - second[1], first[2] - second[2]]
    end

    def dot_product(first, second)
      first[0] * second[0] + first[1] * second[1] + first[2] * second[2]
    end

    def cross_product(first, second)
      [
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0]
      ]
    end

  end
end
