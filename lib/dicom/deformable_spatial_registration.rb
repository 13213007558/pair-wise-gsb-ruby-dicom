module DICOM

  # Transforms points with a Deformable Spatial Registration object.
  #
  # The standard deformable transformation is:
  #   post_matrix * ((pre_matrix * point) + grid_displacement)
  #
  # The 16 matrix values are encoded in row-major order.
  # A 3-vector uses the 4x4 matrix as x' = M*x, so the last row is 0,0,0,1.
  #
  # Grid samples are ordered by Grid Dimensions (0064,0007), with the first
  # dimension varying fastest in Vector Grid Data (0064,0009). Each sample is
  # three consecutive OF floats giving a displacement in millimetres.
  # The grid starts at Image Position (Patient) (0020,0032). Image Orientation
  # (Patient) (0020,0037) gives the first two unit directions; the third is
  # their cross product. Grid Resolution (0064,0008) gives spacing along these
  # three directions.
  #
  class DeformableSpatialRegistration

    class PointOutsideGridError < RangeError; end

    GRID_ORIGIN_TAG = '0020,0032'
    GRID_ORIENTATION_TAG = '0020,0037'
    GRID_DIMENSIONS_TAG = '0064,0007'
    GRID_SPACING_TAG = '0064,0008'
    VECTOR_GRID_DATA_TAG = '0064,0009'
    REGISTRATION_SEQUENCE_TAG = '0064,0002'
    GRID_SEQUENCE_TAG = '0064,0005'
    PRE_MATRIX_SEQUENCE_TAG = '0064,000F'
    POST_MATRIX_SEQUENCE_TAG = '0064,0010'
    MATRIX_REGISTRATION_SEQUENCE_TAG = '0070,0309'
    MATRIX_SEQUENCE_TAG = '0070,030A'
    MATRIX_TAG = '3006,00C6'

    attr_reader :dimensions, :displacements, :origin, :orientation, :post_matrix, :pre_matrix, :spacing

    # @param [DObject] dcm a Deformable Spatial Registration object
    # @param [Integer] registration_index item index in Deformable Registration Sequence

    def initialize(dcm, registration_index=0)
      registration = registration_item(dcm, registration_index)
      grid = sequence_item(registration, GRID_SEQUENCE_TAG, 'Deformable Registration Grid Sequence')

      @origin = numeric_values(grid.value(GRID_ORIGIN_TAG), 3, 'Image Position (Patient)')
      @orientation = parse_orientation(grid)
      @dimensions = integer_values(grid.value(GRID_DIMENSIONS_TAG), 3, 'Grid Dimensions')
      @spacing = numeric_values(grid.value(GRID_SPACING_TAG), 3, 'Grid Resolution')
      unless spacing.all? { |value| value > 0.0 }
        raise ArgumentError, 'Grid Resolution must contain positive spacing values.'
      end
      @displacements = parse_displacements(grid)
      @pre_matrix = parse_affine_matrix(registration, PRE_MATRIX_SEQUENCE_TAG)
      @post_matrix = parse_affine_matrix(registration, POST_MATRIX_SEQUENCE_TAG)
    end

    def self.transform_points(dcm, points, options={})
      new(dcm, options.fetch(:registration_index, 0)).transform_points(points, options)
    end

    def transform_points(points, options={})
      outside_grid = options.fetch(:outside_grid, :raise)
      outside_grid = outside_grid.to_sym if outside_grid.respond_to?(:to_sym)
      validate_outside_grid_policy(outside_grid)
      return [] if points.is_a?(Array) && points.empty?
      single_point = !points.first.is_a?(Array)
      points = [points] if single_point

      transformed = points.map do |point|
        transformed_point = transform_point(point)
        transformed_point
      rescue PointOutsideGridError
        case outside_grid
        when :raise, :error then raise
        when :undefined, :nil then nil
        end
      end
      single_point ? transformed.first : transformed
    end

    def transform_point(point)
      transform_point_data(point)
    end

    private

    def registration_item(dcm, registration_index)
      sequence = dcm[REGISTRATION_SEQUENCE_TAG]
      unless sequence && sequence[registration_index]
        raise ArgumentError, "Deformable Registration Sequence item #{registration_index} is missing."
      end
      sequence[registration_index]
    end

    def sequence_item(parent, tag, description)
      sequence = parent[tag]
      unless sequence && sequence[0]
        raise ArgumentError, "#{description} is missing."
      end
      sequence[0]
    end

    def parse_orientation(grid)
      direction = numeric_values(grid.value(GRID_ORIENTATION_TAG), 6, 'Image Orientation (Patient)')
      row = direction[0..2]
      column = direction[3..5]
      normal = cross_product(row, column)
      direction_vectors = [row, column, normal]
      direction_vectors.each do |vector|
        unless approximately_one?(vector_length(vector))
          raise ArgumentError, 'Image Orientation (Patient) direction cosines must be unit vectors.'
        end
      end
      unless orthogonal?(row, column)
        raise ArgumentError, 'Image Orientation (Patient) row and column directions must be orthogonal.'
      end
      direction_vectors
    end

    def parse_displacements(grid)
      element = grid[VECTOR_GRID_DATA_TAG]
      raise ArgumentError, 'Vector Grid Data is missing.' unless element
      values = Stream.new(element.bin, element.endian).decode_all('OF')
      expected = dimensions.reduce(1, :*) * 3
      if values.length != expected
        raise ArgumentError, "Vector Grid Data has #{values.length} floats, expected #{expected}."
      end
      values.each_slice(3).to_a
    end

    def parse_affine_matrix(registration, sequence_tag)
      matrix_sequence = registration[sequence_tag]
      return identity_matrix unless matrix_sequence && matrix_sequence[0]

      matrix_registration = matrix_sequence[0]
      matrix_registration_sequence = matrix_registration[MATRIX_REGISTRATION_SEQUENCE_TAG]
      unless matrix_registration_sequence && matrix_registration_sequence[0]
        raise ArgumentError, "Matrix Registration Sequence is missing in #{sequence_tag}."
      end

      matrix_item = sequence_item(matrix_registration_sequence[0], MATRIX_SEQUENCE_TAG, 'Matrix Sequence')
      values = numeric_values(matrix_item.value(MATRIX_TAG), 16, 'Frame of Reference Transformation Matrix')
      unless values[12..14].all? { |value| value == 0.0 } && values[15] == 1.0
        raise ArgumentError, 'Frame of Reference Transformation Matrix must have a 0,0,0,1 last row.'
      end
      values.each_slice(4).to_a
    end

    def identity_matrix
      [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0]
      ]
    end

    def transform_point_data(point)
      point = numeric_values(point, 3, 'point')
      pre_point = multiply_point(pre_matrix, point)
      displacement = interpolate_displacement(pre_point)
      displaced = [
        pre_point[0] + displacement[0],
        pre_point[1] + displacement[1],
        pre_point[2] + displacement[2]
      ]
      multiply_point(post_matrix, displaced)
    end

    def interpolate_displacement(point)
      fractional = grid_coordinates(point)
      indices = Array.new(3)
      weights = Array.new(3)

      3.times do |axis|
        coordinate = fractional[axis]
        last_index = dimensions[axis] - 1
        unless coordinate >= -1e-9 && coordinate <= last_index + 1e-9
          raise PointOutsideGridError, "Point #{point.inspect} is outside the deformation grid."
        end
        coordinate = 0.0 if coordinate < 0.0
        coordinate = last_index.to_f if coordinate > last_index
        lower = coordinate.floor
        lower -= 1 if lower == last_index
        upper = lower + 1
        if dimensions[axis] == 1
          lower = 0
          upper = 0
        end
        fraction = dimensions[axis] == 1 ? 0.0 : coordinate - lower
        if lower < 0 || upper >= dimensions[axis] || fraction < 0.0 || fraction > 1.0
          raise PointOutsideGridError, "Point #{point.inspect} is outside the deformation grid."
        end
        fraction = 0.0 if fraction.abs < 1e-12
        fraction = 1.0 if (fraction - 1.0).abs < 1e-12
        indices[axis] = [lower, upper]
        weights[axis] = [1.0 - fraction, fraction]
      end

      result = [0.0, 0.0, 0.0]
      8.times do |corner|
        grid_index = Array.new(3) { |axis| indices[axis][corner[axis]] }
        weight = 3.times.map { |axis| weights[axis][corner[axis]] }.reduce(:*)
        vector = displacement_at(grid_index)
        3.times { |axis| result[axis] += vector[axis] * weight }
      end
      result
    end

    def grid_coordinates(point)
      offset = [point[0] - origin[0], point[1] - origin[1], point[2] - origin[2]]
      Array.new(3) do |axis|
        projection = 3.times.map { |component| offset[component] * orientation[axis][component] }.reduce(:+)
        projection / spacing[axis]
      end
    end

    def displacement_at(index)
      flat_index =
        index[0] +
        dimensions[0] * index[1] +
        dimensions[0] * dimensions[1] * index[2]
      displacements[flat_index]
    end

    def multiply_point(matrix, point)
      [
        matrix[0][0] * point[0] + matrix[0][1] * point[1] + matrix[0][2] * point[2] + matrix[0][3],
        matrix[1][0] * point[0] + matrix[1][1] * point[1] + matrix[1][2] * point[2] + matrix[1][3],
        matrix[2][0] * point[0] + matrix[2][1] * point[1] + matrix[2][2] * point[2] + matrix[2][3]
      ]
    end

    def cross_product(first, second)
      [
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0]
      ]
    end

    def vector_length(vector)
      Math.sqrt(vector.map { |value| value * value }.reduce(:+))
    end

    def approximately_one?(value)
      (value - 1.0).abs < 1e-6
    end

    def orthogonal?(first, second)
      dot_product = first.zip(second).map { |a, b| a * b }.reduce(:+)
      dot_product.abs < 1e-6
    end

    def validate_outside_grid_policy(policy)
      unless [:raise, :error, :undefined, :nil].include?(policy)
        raise ArgumentError, "Unknown outside grid policy #{policy.inspect}."
      end
    end

    def integer_values(value, count, description)
      numbers = numeric_values(value, count, description).map(&:to_i)
      numeric_source = numeric_values(value, count, description)
      unless numbers.all? { |number| number > 0 } && numeric_source.zip(numbers).all? { |number, integer| number == integer }
        raise ArgumentError, "#{description} must contain positive values."
      end
      numbers
    end

    def numeric_values(value, count, description)
      values =
        if value.is_a?(Array)
          value
        elsif value.is_a?(String)
          value.split('\\')
        elsif value.is_a?(Numeric)
          [value]
        else
          []
        end
      if values.length != count
        raise ArgumentError, "#{description} must contain #{count} values, got #{values.length}."
      end
      values.map { |item| Float(item) }
    end

  end
end
