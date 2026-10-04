module DICOM

  # Converts closed RTSTRUCT planar contours to a binary mask on an explicitly
  # defined target image grid.
  #
  # The target grid is described in the DICOM patient coordinate system:
  # * +position+ is the center of the first voxel, as Image Position Patient
  #   (0020,0032) for frame zero.
  # * +orientation+ contains either the six Image Orientation Patient
  #   (0020,0037) direction cosines or nine values giving row, column and frame
  #   direction cosines. With six values the frame direction is row x column;
  #   pass nine values when frames run in the opposite direction.
  # * +spacing+ is [row spacing, column spacing] in millimetres for a single
  #   target plane, or [row spacing, column spacing, frame spacing] for a 3D
  #   target grid.
  #
  # A voxel is covered when its center is inside the XOR (even-odd) region of
  # the closed contours. A center exactly on a contour edge is counted as being
  # inside that contour; XOR then determines final coverage. For example, an
  # outer contour edge is covered, while an inner hole edge is toggled off.
  # Overlapping closed contours alternate between covered and uncovered, which
  # gives holes their standard XOR semantics without using contour orientation.
  #
  class RTSTRUCTMasker

    # Holds a rasterized mask and contours that could not be assigned to a
    # target plane within the requested tolerance.
    #
    class Result

      attr_reader :mask, :out_of_tolerance_contours, :warnings

      def initialize(mask, out_of_tolerance_contours, warnings)
        @mask = mask
        @out_of_tolerance_contours = out_of_tolerance_contours
        @warnings = warnings
      end

      def out_of_tolerance?
        @out_of_tolerance_contours.length > 0
      end

    end

    attr_reader :position, :row_direction, :column_direction, :frame_direction
    attr_reader :spacing, :columns, :rows, :frames, :tolerance

    # Creates a masker for one target image grid.
    #
    # @param [Array<Numeric>] position the first-frame, first-row, first-column voxel center in patient coordinates
    # @param [Array<Numeric>] orientation six or nine orthonormal direction cosines
    # @param [Array<Numeric>] spacing the row and column spacings, optionally followed by frame spacing in millimetres
    # @param [Integer] columns number of columns in the target grid
    # @param [Integer] rows number of rows in the target grid
    # @param [Integer] frames number of frames in the target grid (3D grids only)
    # @param [Numeric] tolerance maximum allowed perpendicular distance from a contour to a target plane
    #
    def initialize(position:, orientation:, spacing:, columns:, rows:, frames: nil, tolerance: 0.0)
      @position = validate_vector(position, 'position', 3)
      @spacing = validate_positive_vector(spacing, 'spacing', [2, 3])
      @columns = validate_dimension(columns, 'columns')
      @rows = validate_dimension(rows, 'rows')
      @volume = @spacing.length == 3
      if @volume
        @frames = validate_dimension(frames || 1, 'frames')
      else
        raise ArgumentError, 'frames cannot be specified for a two-dimensional target grid.' if frames && frames != 1
        @frames = 1
      end
      @tolerance = validate_tolerance(tolerance)
      @row_direction, @column_direction, @frame_direction = parse_orientation(orientation)
    end

    # Rasterizes an array of closed planar contours.
    #
    # A contour may be supplied as an array of [x, y, z] points, a flat array
    # of x/y/z values, or a hash containing +points+ (or +contour_data+) and
    # optionally +number+ and +geometric_type+. Only CLOSED_PLANAR contours are
    # filled. Points are positioned directly in patient coordinates; contour or
    # instance numbers are never used to infer a target slice.
    #
    # @param [Array] contours closed planar RTSTRUCT contours from one ROI
    # @return [Result] the binary mask and out-of-tolerance report
    #
    def rasterize(contours)
      raise ArgumentError, "Expected Array, got #{contours.class}." unless contours.is_a?(Array)
      mask = if @volume
        Array.new(@frames) { Array.new(@rows) { Array.new(@columns, 0) } }
      else
        Array.new(@rows) { Array.new(@columns, 0) }
      end
      grouped = Hash.new { |hash, key| hash[key] = [] }
      out_of_tolerance = []
      warnings = []

      contours.each_with_index do |contour, index|
        number, geometric_type, points = normalize_contour(contour, index)
        unless geometric_type.nil? || geometric_type == 'CLOSED_PLANAR'
          raise ArgumentError, "Unsupported contour geometric type #{geometric_type} for contour #{number || index}. Only CLOSED_PLANAR contours are supported."
        end

        frame_index, projected_points, distance = project_to_nearest_plane(points)
        if distance > @tolerance + EPSILON
          report = {
            :index => index,
            :number => number,
            :geometric_type => geometric_type || 'CLOSED_PLANAR',
            :frame => frame_index,
            :in_grid => frame_index >= 0 && frame_index < @frames,
            :distance => distance
          }
          out_of_tolerance << report
          message = "RTSTRUCT contour #{number || index} is #{format('%.6g', distance)} mm from the nearest target frame (#{frame_index}), which exceeds the tolerance of #{format('%.6g', @tolerance)} mm."
          warnings << message
          DICOM.logger.warn(message)
        else
          assigned_frame = [[frame_index, 0].max, @frames - 1].min
          grouped[assigned_frame] << projected_points
        end
      end

      if @volume
        grouped.each do |frame_index, frame_contours|
          rasterize_frame(mask[frame_index], frame_contours) if frame_index >= 0 && frame_index < @frames
        end
      else
        rasterize_frame(mask, grouped[0]) if grouped.key?(0)
      end
      Result.new(mask, out_of_tolerance, warnings)
    end
    alias_method :to_mask, :rasterize
    alias_method :convert, :rasterize

    private

    EPSILON = 1e-9

    def parse_orientation(orientation)
      values = validate_vector(orientation, 'orientation', [6, 9])
      row = normalize_direction(values[0..2], 'row orientation')
      column = normalize_direction(values[3..5], 'column orientation')
      ensure_orthogonal(row, column, 'row', 'column')

      if values.length == 9
        frame = normalize_direction(values[6..8], 'frame orientation')
        ensure_orthogonal(row, frame, 'row', 'frame')
        ensure_orthogonal(column, frame, 'column', 'frame')
      else
        frame = cross_product(row, column)
        frame = scale_vector(frame, 1.0 / vector_length(frame))
      end
      [row, column, frame]
    end

    def normalize_contour(contour, index)
      if contour.is_a?(Hash)
        number = contour[:number] || contour['number'] || contour[:contour_number] || contour['Contour Number']
        geometric_type = contour[:geometric_type] || contour['geometricType'] || contour['Contour Geometric Type']
        raw_points = contour[:points] || contour['points'] || contour[:contour_data] || contour['Contour Data']
        raise ArgumentError, "Contour #{index} contains no points." if raw_points.nil?
        normalized_type = geometric_type.nil? ? nil : geometric_type.to_s.upcase
        unless normalized_type.nil? || normalized_type == 'CLOSED_PLANAR'
          raise ArgumentError, "Unsupported contour geometric type #{normalized_type} for contour #{number || index}. Only CLOSED_PLANAR contours are supported."
        end
        points = normalize_points(raw_points, index)
        [number, normalized_type, points]
      elsif contour.is_a?(Array)
        [nil, nil, normalize_points(contour, index)]
      else
        raise ArgumentError, "Expected contour as Array or Hash, got #{contour.class}."
      end
    end

    def normalize_points(raw_points, contour_index)
      raw_points = raw_points.split('\\') if raw_points.is_a?(String)
      values = Array(raw_points).map do |value|
        if value.is_a?(Array)
          value.map { |coordinate| to_coordinate(coordinate, contour_index) }
        else
          to_coordinate(value, contour_index)
        end
      end.flatten
      raise ArgumentError, "Contour #{contour_index} must contain points in groups of three." unless values.length >= 9 && values.length % 3 == 0
      points = values.each_slice(3).to_a
      points.pop if points.length > 1 && points.first == points.last
      raise ArgumentError, "Contour #{contour_index} must contain at least three distinct points." if points.uniq.length < 3
      points
    end

    def to_coordinate(value, contour_index)
      Float(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "Contour #{contour_index} contains an invalid patient coordinate: #{value.inspect}."
    end

    def project_to_nearest_plane(points)
      center = points.reduce([0.0, 0.0, 0.0]) do |sum, point|
        add_vectors(sum, point)
      end
      center = scale_vector(center, 1.0 / points.length)
      center_offset = subtract_vectors(center, @position)
      if @volume
        frame_coordinate = dot_product(center_offset, @frame_direction) / @spacing[2]
        nearest_frame = (frame_coordinate + EPSILON).round
        assigned_frame = [[nearest_frame, 0].max, @frames - 1].min
      else
        nearest_frame = 0
        assigned_frame = 0
      end
      plane_origin = if @volume
        add_vectors(@position, scale_vector(@frame_direction, assigned_frame * @spacing[2]))
      else
        @position
      end

      projected = points.map do |point|
        signed_distance = dot_product(subtract_vectors(point, plane_origin), @frame_direction)
        projected_point = subtract_vectors(point, scale_vector(@frame_direction, signed_distance))
        to_grid_coordinates(projected_point, plane_origin)
      end
      distance = points.map do |point|
        dot_product(subtract_vectors(point, plane_origin), @frame_direction).abs
      end.max
      [nearest_frame, projected, distance]
    end

    def to_grid_coordinates(point, origin=@position)
      offset = subtract_vectors(point, origin)
      [
        dot_product(offset, @row_direction) / @spacing[0],
        dot_product(offset, @column_direction) / @spacing[1]
      ]
    end

    def rasterize_frame(frame_mask, contours)
      min_column = Float::INFINITY
      max_column = -Float::INFINITY
      min_row = Float::INFINITY
      max_row = -Float::INFINITY

      contours.each do |points|
        columns = points.map { |point| point[0] }
        rows = points.map { |point| point[1] }
        min_column = [min_column, (columns.min - EPSILON).floor].min
        max_column = [max_column, (columns.max + EPSILON).floor].max
        min_row = [min_row, (rows.min - EPSILON).floor].min
        max_row = [max_row, (rows.max + EPSILON).floor].max
      end

      min_column = [min_column, 0].max
      max_column = [max_column, @columns - 1].min
      min_row = [min_row, 0].max
      max_row = [max_row, @rows - 1].min

      return if min_column > max_column || min_row > max_row
      min_column.upto(max_column) do |column|
        min_row.upto(max_row) do |row|
          frame_mask[row][column] = 1 if inside_contours?(column.to_f, row.to_f, contours)
        end
      end
    end

    def inside_contours?(x, y, contours)
      contours.reduce(false) do |inside, points|
        inside ^ point_in_closed_contour?(x, y, points)
      end
    end

    def point_in_closed_contour?(x, y, points)
      inside = false
      boundary = false
      points.each_with_index do |point, index|
        x1, y1 = point
        x2, y2 = points[(index + 1) % points.length]
        boundary = true if point_on_segment?(x, y, x1, y1, x2, y2)
        next unless (y1 > y) != (y2 > y)
        intersection_x = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
        inside = !inside if x < intersection_x
      end
      return true if boundary
      inside
    end

    def point_on_segment?(x, y, x1, y1, x2, y2)
      cross = (x - x1) * (y2 - y1) - (y - y1) * (x2 - x1)
      coordinate_scale = 1.0 + [x.abs, y.abs, x1.abs, y1.abs, x2.abs, y2.abs].max
      edge_scale = 1.0 + (x2 - x1).abs + (y2 - y1).abs
      tolerance = 1e-12 * coordinate_scale * edge_scale
      return false unless cross.abs <= tolerance
      x.between?([x1, x2].min - tolerance, [x1, x2].max + tolerance) &&
        y.between?([y1, y2].min - tolerance, [y1, y2].max + tolerance)
    end

    def validate_vector(value, name, lengths)
      array = Array(value)
      valid_lengths = Array(lengths)
      raise ArgumentError, "#{name} must have #{valid_lengths.join(' or ')} values." unless valid_lengths.include?(array.length)
      array.map do |component|
        raise ArgumentError, "#{name} must contain numbers only." unless component.is_a?(Numeric)
        component.to_f
      end
    end

    def validate_positive_vector(value, name, length)
      vector = validate_vector(value, name, length)
      raise ArgumentError, "#{name} must contain positive values only." unless vector.all? { |component| component > 0 }
      vector
    end

    def validate_dimension(value, name)
      raise ArgumentError, "#{name} must be a positive Integer." unless value.is_a?(Integer) && value > 0
      value
    end

    def validate_tolerance(value)
      raise ArgumentError, "tolerance must be a non-negative Numeric." unless value.is_a?(Numeric) && value >= 0
      value.to_f
    end

    def normalize_direction(vector, name)
      length = vector_length(vector)
      raise ArgumentError, "#{name} must not be a zero vector." if length <= EPSILON
      normalized = scale_vector(vector, 1.0 / length)
      raise ArgumentError, "#{name} must be a unit vector." if (length - 1.0).abs > 1e-6
      normalized
    end

    def ensure_orthogonal(first, second, first_name, second_name)
      raise ArgumentError, "#{first_name} and #{second_name} orientation must be orthogonal." if dot_product(first, second).abs > 1e-6
    end

    def add_vectors(first, second)
      first.zip(second).map { |a, b| a + b }
    end

    def subtract_vectors(first, second)
      first.zip(second).map { |a, b| a - b }
    end

    def scale_vector(vector, scalar)
      vector.map { |component| component * scalar }
    end

    def dot_product(first, second)
      first.zip(second).map { |a, b| a * b }.reduce(0.0, :+)
    end

    def cross_product(first, second)
      [
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0]
      ]
    end

    def vector_length(vector)
      Math.sqrt(dot_product(vector, vector))
    end

    def volume?
      @volume
    end

  end
end
