module DICOM

  # The DeformableRegistration class reads a DICOM Deformable Spatial
  # Registration object and applies its transformation to points, i.e. it
  # transforms coordinates from the source frame of reference to the
  # registered (target) frame of reference.
  #
  # === Transformation model (per DICOM PS3.3, Deformable Spatial Registration Module)
  #
  # A point p (given in source frame of reference coordinates) is transformed as:
  #
  #   p' = M_post * (M_pre * p + D(M_pre * p))
  #
  # * M_pre:  Pre-Deformation Matrix (4x4 homogeneous, row major), applied before
  #   the deformation. Identity if the Pre Deformation Matrix Registration
  #   Sequence is absent.
  # * D(q):   Displacement vector interpolated (trilinearly) from the
  #   deformation grid at position q.
  # * M_post: Post-Deformation Matrix (4x4 homogeneous, row major), applied after
  #   the deformation. Identity if the Post Deformation Matrix Registration
  #   Sequence is absent.
  #
  # Note that matrix multiplication and displacement addition do not commute:
  # rotating before displacing gives a different result than displacing before
  # rotating. The pre/post matrices are therefore applied strictly in the order
  # defined by the standard.
  #
  # === Deformation grid
  #
  # The grid is a regular 3D grid of displacement vectors. Per the standard it
  # is anchored at the origin of the source frame of reference with its axes
  # aligned to the frame of reference axes; custom origin/direction may be
  # supplied as options if needed. Grid Resolution gives the spacing between
  # grid points along each axis (in mm). Vector Grid Data contains 3 floats
  # (x, y, z displacement components) per grid point, ordered with the x index
  # varying fastest, then y, then z.
  #
  # === Out of grid behaviour
  #
  # Points that fall outside the deformation grid are never extrapolated.
  # The caller chooses the behaviour with the :outside option:
  # * :raise (default) - an OutOfGridError is raised
  # * :undefined       - nil is returned for the out-of-grid point
  #
  # @example Transform points using a Deformable Spatial Registration object
  #   dcm = DObject.read("deformable_registration.dcm")
  #   reg = DICOM::DeformableRegistration.new(dcm)
  #   reg.transform_points([[10.0, 20.0, 30.0], [40.0, 50.0, 60.0]])
  # @example Return nil for points outside the grid instead of raising
  #   reg.transform_points([[10.0, 20.0, 30.0]], :outside => :undefined)
  #
  class DeformableRegistration

    # Raised when a point to be transformed falls outside the deformation grid.
    class OutOfGridError < StandardError; end

    # DICOM tags used by the Deformable Spatial Registration IOD, as defined in
    # the data dictionary of this library:
    DEFORMABLE_REGISTRATION_SEQUENCE = '0064,0002'
    DEFORMABLE_REGISTRATION_GRID_SEQUENCE = '0064,0005'
    GRID_DIMENSIONS = '0064,0007'
    GRID_RESOLUTION = '0064,0008'
    VECTOR_GRID_DATA = '0064,0009'
    PRE_DEFORMATION_MATRIX_SEQUENCE = '0064,000F'
    POST_DEFORMATION_MATRIX_SEQUENCE = '0064,0010'
    TRANSFORMATION_MATRIX = '3006,00C6'

    # Valid values for the :outside option.
    OUTSIDE_MODES = [:raise, :undefined].freeze

    # Number of grid points along each of the 3 grid axes (Array<Integer>).
    attr_reader :dimensions
    # Spacing between grid points along each grid axis, in mm (Array<Float>).
    attr_reader :resolution
    # Position of the first grid point in source frame of reference coordinates (Array<Float>).
    attr_reader :origin
    # Direction cosines of the grid axes (3 row vectors) in the source frame of reference.
    attr_reader :direction
    # Displacement vectors of the grid, as a flat array of floats (x fastest, then y, then z).
    attr_reader :vector_grid_data
    # 4x4 pre-deformation matrix (Array of 4 rows of 4 floats), or nil if not present.
    attr_reader :pre_deformation_matrix
    # 4x4 post-deformation matrix (Array of 4 rows of 4 floats), or nil if not present.
    attr_reader :post_deformation_matrix

    # Creates a DeformableRegistration instance from a DICOM object.
    #
    # @param [DObject] dcm a DICOM object containing a Deformable Registration Sequence
    # @param [Hash] options the options to use for the registration
    # @option options [Array<Float>] :origin position of the first grid point (defaults to the frame of reference origin, per the standard)
    # @option options [Array<Array<Float>>] :direction direction cosines of the grid x, y & z axes, as 3 row vectors (defaults to the identity matrix, per the standard)
    # @option options [Integer] :registration_index index of the item to use in the Deformable Registration Sequence (defaults to the first item)
    #
    def initialize(dcm, options={})
      raise ArgumentError, "Invalid argument 'dcm'. Expected DObject, got #{dcm.class}." unless dcm.is_a?(DObject)
      @origin = (options[:origin] || [0.0, 0.0, 0.0]).map(&:to_f)
      @direction = (options[:direction] || [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]).map { |axis| axis.map(&:to_f) }
      registration_index = options[:registration_index] || 0
      extract_registration(dcm, registration_index)
      validate_grid
    end

    # Transforms a single point from the source frame of reference to the
    # registered frame of reference.
    #
    # @param [Array<Numeric>] point a 3-element point (x, y, z) in source frame of reference coordinates
    # @param [Hash] options the options to use for the transformation
    # @option options [Symbol] :outside behaviour for points outside the grid (:raise (default) or :undefined)
    # @return [Array<Float>, NilClass] the transformed point, or nil if the point is outside the grid and :outside => :undefined
    #
    def transform_point(point, options={})
      outside = check_outside_option(options)
      raise ArgumentError, "Invalid argument 'point'. Expected a 3-element array, got #{point.inspect}." unless point.is_a?(Array) && point.length == 3
      # Apply the pre-deformation matrix (identity if absent):
      q = apply_matrix(@pre_deformation_matrix, point.map(&:to_f))
      # Interpolate the displacement vector at the (pre-deformed) position:
      displacement = interpolate_displacement(q)
      unless displacement
        if outside == :raise
          raise OutOfGridError, "The point #{point.inspect} (deformation grid position #{q.inspect}) is outside the deformation grid, and extrapolation is not supported."
        else
          return nil
        end
      end
      # Add the displacement, then apply the post-deformation matrix (identity if absent):
      deformed = [q[0] + displacement[0], q[1] + displacement[1], q[2] + displacement[2]]
      apply_matrix(@post_deformation_matrix, deformed)
    end

    # Transforms a set of points from the source frame of reference to the
    # registered frame of reference.
    #
    # @param [Array<Array<Numeric>>] points an array of 3-element points (x, y, z) in source frame of reference coordinates
    # @param [Hash] options the options to use for the transformation
    # @option options [Symbol] :outside behaviour for points outside the grid (:raise (default) or :undefined)
    # @return [Array] the transformed points (nil entries for out-of-grid points when :outside => :undefined)
    #
    def transform_points(points, options={})
      check_outside_option(options)
      raise ArgumentError, "Invalid argument 'points'. Expected Array, got #{points.class}." unless points.is_a?(Array)
      points.map { |point| transform_point(point, options) }
    end


    private


    # Applies a 4x4 homogeneous transformation matrix to a 3D point.
    # Returns the point unchanged if the matrix is nil.
    #
    # @param [Array<Array<Float>>, NilClass] matrix 4 rows of 4 numbers, or nil
    # @param [Array<Float>] point a 3-element point
    # @return [Array<Float>] the transformed point
    #
    def apply_matrix(matrix, point)
      return point.dup unless matrix
      (0..2).map do |row|
        matrix[row][0] * point[0] + matrix[row][1] * point[1] + matrix[row][2] * point[2] + matrix[row][3]
      end
    end

    # Checks the validity of the :outside option and returns its value.
    #
    # @param [Hash] options the transformation options
    # @return [Symbol] the :outside mode (:raise or :undefined)
    #
    def check_outside_option(options)
      outside = options[:outside] || :raise
      raise ArgumentError, "Invalid :outside option '#{outside.inspect}'. Valid options are #{OUTSIDE_MODES.inspect}." unless OUTSIDE_MODES.include?(outside)
      outside
    end

    # Extracts the deformation grid and the pre/post deformation matrices from
    # the given DICOM object.
    #
    # @param [DObject] dcm a DICOM object containing a Deformable Registration Sequence
    # @param [Integer] registration_index index of the Deformable Registration Sequence item to use
    #
    def extract_registration(dcm, registration_index)
      registration_sequence = dcm[DEFORMABLE_REGISTRATION_SEQUENCE]
      raise ArgumentError, "The DICOM object does not contain a Deformable Registration Sequence (#{DEFORMABLE_REGISTRATION_SEQUENCE})." unless registration_sequence.is_a?(Sequence)
      registration_item = registration_sequence[registration_index]
      raise ArgumentError, "The Deformable Registration Sequence does not contain an item with index #{registration_index}." unless registration_item
      grid_sequence = registration_item[DEFORMABLE_REGISTRATION_GRID_SEQUENCE]
      raise ArgumentError, "The registration item does not contain a Deformable Registration Grid Sequence (#{DEFORMABLE_REGISTRATION_GRID_SEQUENCE})." unless grid_sequence.is_a?(Sequence)
      grid_item = grid_sequence[0]
      raise ArgumentError, "The Deformable Registration Grid Sequence is empty." unless grid_item
      @dimensions = extract_numbers(grid_item, GRID_DIMENSIONS, 3).map(&:to_i)
      @resolution = extract_numbers(grid_item, GRID_RESOLUTION, 3).map(&:to_f)
      @vector_grid_data = extract_numbers(grid_item, VECTOR_GRID_DATA, 3 * @dimensions.inject(:*)).map(&:to_f)
      @pre_deformation_matrix = extract_matrix(registration_item, PRE_DEFORMATION_MATRIX_SEQUENCE)
      @post_deformation_matrix = extract_matrix(registration_item, POST_DEFORMATION_MATRIX_SEQUENCE)
    end

    # Extracts a 4x4 transformation matrix from a matrix registration sequence
    # item. Returns nil if the sequence is absent.
    #
    # @param [Item] item the registration sequence item
    # @param [String] tag tag of the matrix registration sequence
    # @return [Array<Array<Float>>, NilClass] 4 rows of 4 floats, or nil
    #
    def extract_matrix(item, tag)
      sequence = item[tag]
      return nil unless sequence.is_a?(Sequence)
      matrix_item = sequence[0]
      return nil unless matrix_item
      numbers = extract_numbers(matrix_item, TRANSFORMATION_MATRIX, 16).map(&:to_f)
      numbers.each_slice(4).to_a
    end

    # Extracts a numeric array of expected length from a data element of the
    # given parent. Multi-valued string elements (e.g. DS) are split on the
    # DICOM value separator (backslash). Binary value representations (e.g.
    # OF), for which ruby-dicom does not decode a value when reading from
    # file, are decoded from the element's binary string.
    #
    # @param [Item] parent the parent containing the data element
    # @param [String] tag tag of the data element
    # @param [Integer] expected_length the expected number of values
    # @return [Array<Numeric>] the extracted numbers
    #
    def extract_numbers(parent, tag, expected_length)
      element = parent[tag]
      raise ArgumentError, "The expected data element (#{tag}) is missing." unless element.is_a?(Element)
      value = element.value
      if value.nil? && element.bin.is_a?(String) && !element.bin.empty?
        # Binary value representation (e.g. OF) read from file: The value has
        # not been decoded, so decode it from the binary string:
        stream = element.stream
        stream.set_string(element.bin)
        numbers = stream.decode_all(element.vr)
      elsif value.is_a?(Array)
        numbers = value.dup
      elsif value.is_a?(String)
        numbers = value.split('\\')
      elsif value.nil?
        numbers = []
      else
        numbers = [value]
      end
      raise ArgumentError, "Data element (#{tag}) has #{numbers.length} values, expected #{expected_length}." unless numbers.length == expected_length
      numbers
    end

    # Gives the displacement vector of the grid node at the given integer indices.
    #
    # @param [Integer] ix grid index along the x axis
    # @param [Integer] iy grid index along the y axis
    # @param [Integer] iz grid index along the z axis
    # @return [Array<Float>] the 3-component displacement vector
    #
    def grid_vector(ix, iy, iz)
      offset = 3 * (ix + @dimensions[0] * (iy + @dimensions[1] * iz))
      @vector_grid_data[offset, 3]
    end

    # Interpolates the displacement vector at the given position using
    # trilinear interpolation of the 8 surrounding grid nodes.
    # Returns nil if the position is outside the grid (no extrapolation).
    #
    # @param [Array<Float>] point a 3-element position in source frame of reference coordinates
    # @return [Array<Float>, NilClass] the interpolated displacement vector, or nil if outside the grid
    #
    def interpolate_displacement(point)
      # Position in the grid's local coordinate system (origin offset, then
      # projection onto the grid axes), in units of grid spacing:
      relative = [point[0] - @origin[0], point[1] - @origin[1], point[2] - @origin[2]]
      index = (0..2).map do |axis|
        (@direction[axis][0] * relative[0] + @direction[axis][1] * relative[1] + @direction[axis][2] * relative[2]) / @resolution[axis]
      end
      # A position is inside the grid only if all continuous indices fall
      # within [0, dimension - 1]:
      return nil unless (0..2).all? { |axis| index[axis] >= 0.0 && index[axis] <= @dimensions[axis] - 1 }
      # Integer indices of the 8 surrounding nodes (clamped at the far boundary):
      low = index.map { |i| i.floor }
      high = (0..2).map { |axis| [low[axis] + 1, @dimensions[axis] - 1].min }
      fraction = (0..2).map { |axis| index[axis] - low[axis] }
      # Trilinear interpolation:
      displacement = [0.0, 0.0, 0.0]
      [0, 1].each do |dx|
        [0, 1].each do |dy|
          [0, 1].each do |dz|
            weight = (dx == 0 ? 1.0 - fraction[0] : fraction[0]) *
                     (dy == 0 ? 1.0 - fraction[1] : fraction[1]) *
                     (dz == 0 ? 1.0 - fraction[2] : fraction[2])
            vector = grid_vector(dx == 0 ? low[0] : high[0],
                                 dy == 0 ? low[1] : high[1],
                                 dz == 0 ? low[2] : high[2])
            displacement[0] += weight * vector[0]
            displacement[1] += weight * vector[1]
            displacement[2] += weight * vector[2]
          end
        end
      end
      displacement
    end

    # Validates the extracted grid attributes.
    #
    def validate_grid
      raise ArgumentError, "Invalid Grid Dimensions #{@dimensions.inspect}. All dimensions must be >= 2." unless @dimensions.all? { |d| d >= 2 }
      raise ArgumentError, "Invalid Grid Resolution #{@resolution.inspect}. All resolutions must be positive." unless @resolution.all? { |r| r > 0.0 }
    end

  end
end
