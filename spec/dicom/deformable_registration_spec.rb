# encoding: UTF-8

require 'spec_helper'


module DICOM

  describe DeformableRegistration do

    before :context do
      DICOM.logger.level = Logger::FATAL
    end

    # Rotation of 90 degrees about the z axis: [x, y, z] -> [-y, x, z]
    ROT_Z_90 = [[0, -1, 0, 0], [1, 0, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]

    # Builds a synthetic Deformable Spatial Registration DICOM object with the
    # given grid geometry, displacement vectors (x index varying fastest) and
    # optional pre/post deformation matrices (4x4, row major).
    def build_registration(dims, resolution, vectors, options={})
      dcm = DObject.new
      dcm.add(Sequence.new('0064,0002'))
      registration_item = Item.new
      dcm['0064,0002'].add_item(registration_item)
      if options[:pre]
        registration_item.add(Sequence.new('0064,000F'))
        matrix_item = Item.new
        registration_item['0064,000F'].add_item(matrix_item)
        matrix_item.add(Element.new('3006,00C6', options[:pre].flatten.join('\\')))
      end
      if options[:post]
        registration_item.add(Sequence.new('0064,0010'))
        matrix_item = Item.new
        registration_item['0064,0010'].add_item(matrix_item)
        matrix_item.add(Element.new('3006,00C6', options[:post].flatten.join('\\')))
      end
      registration_item.add(Sequence.new('0064,0005'))
      grid_item = Item.new
      registration_item['0064,0005'].add_item(grid_item)
      grid_item.add(Element.new('0064,0007', dims))
      grid_item.add(Element.new('0064,0008', resolution))
      grid_item.add(Element.new('0064,0009', vectors.flatten))
      dcm
    end

    # Repeats the given displacement vector for every node of the grid.
    def constant_vectors(dims, vector)
      Array.new(dims.inject(:*)) { vector.dup }
    end

    # Displacement vectors (x index varying fastest) for a linear displacement
    # field D(p) = A*p + b (A diagonal), sampled on the grid nodes.
    def linear_field_vectors(dims, spacing, a, b)
      vectors = []
      dims[2].times do |iz|
        dims[1].times do |iy|
          dims[0].times do |ix|
            vectors << [a[0] * (ix * spacing[0]) + b[0],
                        a[1] * (iy * spacing[1]) + b[1],
                        a[2] * (iz * spacing[2]) + b[2]]
          end
        end
      end
      vectors
    end


    context "with a constant displacement field" do

      before :example do
        @displacement = [1.5, -2.0, 3.25]
        dcm = build_registration([4, 4, 4], [10.0, 10.0, 10.0], constant_vectors([4, 4, 4], @displacement))
        @reg = DeformableRegistration.new(dcm)
      end

      it "displaces a grid node point by the constant vector" do
        expect(@reg.transform_point([0.0, 0.0, 0.0])).to eq [1.5, -2.0, 3.25]
      end

      it "displaces a point between grid nodes by the constant vector" do
        expect(@reg.transform_point([15.0, 25.0, 5.0])).to eq [16.5, 23.0, 8.25]
      end

      it "transforms multiple points with transform_points" do
        points = [[0.0, 0.0, 0.0], [10.0, 20.0, 30.0]]
        expect(@reg.transform_points(points)).to eq [[1.5, -2.0, 3.25], [11.5, 18.0, 33.25]]
      end

      it "accepts a point exactly on the far grid boundary" do
        expect(@reg.transform_point([30.0, 30.0, 30.0])).to eq [31.5, 28.0, 33.25]
      end

    end


    context "with a varying (linear) displacement field" do

      before :example do
        @a = [0.1, -0.2, 0.05]
        @b = [1.0, 2.0, -3.0]
        dims = [5, 4, 3]
        spacing = [8.0, 12.0, 5.0]
        vectors = linear_field_vectors(dims, spacing, @a, @b)
        @reg = DeformableRegistration.new(build_registration(dims, spacing, vectors))
      end

      def expect_linear_transform(point)
        expected = [point[0] + 0.1 * point[0] + 1.0,
                    point[1] - 0.2 * point[1] + 2.0,
                    point[2] + 0.05 * point[2] - 3.0]
        result = @reg.transform_point(point)
        3.times { |i| expect(result[i]).to be_within(1e-4).of(expected[i]) }
      end

      it "interpolates exactly at a fractional grid position (trilinear interpolation is exact for linear fields)" do
        expect_linear_transform([10.0, 6.0, 2.5])
      end

      it "interpolates exactly at another interior point" do
        expect_linear_transform([20.5, 30.7, 9.1])
      end

    end


    context "trilinear interpolation" do

      before :example do
        # 2x2x2 grid with spacing 10 and hand-picked corner vectors
        # v(ix, iy, iz) = [10*ix + iy, iz, ix + iy + iz]:
        vectors = []
        [0, 1].each do |iz|
          [0, 1].each do |iy|
            [0, 1].each do |ix|
              vectors << [(10 * ix + iy).to_f, iz.to_f, (ix + iy + iz).to_f]
            end
          end
        end
        @reg = DeformableRegistration.new(build_registration([2, 2, 2], [10.0, 10.0, 10.0], vectors))
      end

      it "averages the 8 corner vectors at the grid center" do
        # D = mean of corners = [5.5, 0.5, 1.5]
        expect(@reg.transform_point([5.0, 5.0, 5.0])).to eq [10.5, 5.5, 6.5]
      end

      it "weights the two nearest nodes along a grid edge" do
        # D = 0.75 * v(0,0,0) + 0.25 * v(1,0,0) = [2.5, 0.0, 0.25]
        expect(@reg.transform_point([2.5, 0.0, 0.0])).to eq [5.0, 0.0, 0.25]
      end

    end


    context "with pre and post deformation matrices" do

      before :example do
        # Constant displacement, grid covering [-50, 60] mm along each axis:
        @displacement = [10.0, 0.0, 0.0]
        dims = [11, 11, 11]
        vectors = constant_vectors(dims, @displacement)
        options = {:origin => [-50.0, -50.0, -50.0]}
        @reg_pre = DeformableRegistration.new(build_registration(dims, [10.0, 10.0, 10.0], vectors, :pre => ROT_Z_90), options)
        @reg_post = DeformableRegistration.new(build_registration(dims, [10.0, 10.0, 10.0], vectors, :post => ROT_Z_90), options)
      end

      it "applies the pre-deformation matrix before displacing (rotate, then displace)" do
        # R * [30,5,2] = [-5,30,2]; [-5,30,2] + [10,0,0] = [5,30,2]
        expect(@reg_pre.transform_point([30.0, 5.0, 2.0])).to eq [5.0, 30.0, 2.0]
      end

      it "applies the post-deformation matrix after displacing (displace, then rotate)" do
        # [30,5,2] + [10,0,0] = [40,5,2]; R * [40,5,2] = [-5,40,2]
        expect(@reg_post.transform_point([30.0, 5.0, 2.0])).to eq [-5.0, 40.0, 2.0]
      end

      it "gives different results for rotate-then-displace and displace-then-rotate" do
        point = [30.0, 5.0, 2.0]
        expect(@reg_pre.transform_point(point)).not_to eq @reg_post.transform_point(point)
      end

      it "applies pre translation and post rotation in pipeline order" do
        translation = [[1, 0, 0, 100], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
        displacement = [1.0, 2.0, 3.0]
        dims = [20, 10, 10]
        dcm = build_registration(dims, [10.0, 10.0, 10.0], constant_vectors(dims, displacement), :pre => translation, :post => ROT_Z_90)
        reg = DeformableRegistration.new(dcm)
        # [10,20,30] -> +[100,0,0] -> [110,20,30] -> +[1,2,3] -> [111,22,33] -> R -> [-22,111,33]
        expect(reg.transform_point([10.0, 20.0, 30.0])).to eq [-22.0, 111.0, 33.0]
      end

    end


    context "with custom grid origin and direction" do

      it "offsets the grid by the given origin" do
        displacement = [1.0, 1.0, 1.0]
        dcm = build_registration([3, 3, 3], [10.0, 10.0, 10.0], constant_vectors([3, 3, 3], displacement))
        reg = DeformableRegistration.new(dcm, :origin => [100.0, 200.0, 300.0])
        expect(reg.transform_point([105.0, 210.0, 300.0])).to eq [106.0, 211.0, 301.0]
        expect { reg.transform_point([0.0, 0.0, 0.0]) }.to raise_error(DeformableRegistration::OutOfGridError)
      end

      it "projects points onto the given grid direction axes" do
        # 2x2x2 grid, spacing 10, x/y axes swapped; v(ix, iy, iz) = [10*ix + iy, 0, 0]:
        vectors = []
        [0, 1].each do |iz|
          [0, 1].each do |iy|
            [0, 1].each do |ix|
              vectors << [(10 * ix + iy).to_f, 0.0, 0.0]
            end
          end
        end
        dcm = build_registration([2, 2, 2], [10.0, 10.0, 10.0], vectors)
        reg = DeformableRegistration.new(dcm, :direction => [[0, 1, 0], [1, 0, 0], [0, 0, 1]])
        # Point [0,5,0] -> grid index (0.5, 0, 0) -> D = 0.5*v(0,0,0) + 0.5*v(1,0,0) = [5,0,0]
        expect(reg.transform_point([0.0, 5.0, 0.0])).to eq [5.0, 5.0, 0.0]
      end

    end


    context "with points outside the deformation grid" do

      before :example do
        displacement = [1.0, 2.0, 3.0]
        dcm = build_registration([4, 4, 4], [10.0, 10.0, 10.0], constant_vectors([4, 4, 4], displacement))
        @reg = DeformableRegistration.new(dcm)
      end

      it "raises OutOfGridError by default (no extrapolation)" do
        expect { @reg.transform_point([1000.0, 0.0, 0.0]) }.to raise_error(DeformableRegistration::OutOfGridError)
      end

      it "raises for points just beyond the grid boundary" do
        expect { @reg.transform_point([30.0001, 5.0, 5.0]) }.to raise_error(DeformableRegistration::OutOfGridError)
        expect { @reg.transform_point([-0.0001, 5.0, 5.0]) }.to raise_error(DeformableRegistration::OutOfGridError)
      end

      it "returns nil for out-of-grid points when :outside => :undefined" do
        expect(@reg.transform_point([1000.0, 0.0, 0.0], :outside => :undefined)).to be_nil
      end

      it "returns nil entries mixed with transformed points when :outside => :undefined" do
        result = @reg.transform_points([[1000.0, 0.0, 0.0], [5.0, 5.0, 5.0]], :outside => :undefined)
        expect(result[0]).to be_nil
        expect(result[1]).to eq [6.0, 7.0, 8.0]
      end

      it "raises ArgumentError for an invalid :outside option" do
        expect { @reg.transform_point([5.0, 5.0, 5.0], :outside => :extrapolate) }.to raise_error(ArgumentError)
      end

    end


    context "when reading from a DICOM file" do

      it "gives the same transformation after a write/read round-trip" do
        translation = [[1, 0, 0, 100], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
        displacement = [1.0, 2.0, 3.0]
        dims = [20, 10, 10]
        dcm = build_registration(dims, [10.0, 10.0, 10.0], constant_vectors(dims, displacement), :pre => translation, :post => ROT_Z_90)
        file = DICOM::TMPDIR + 'deformable_registration.dcm'
        dcm.write(file)
        reg = DeformableRegistration.new(DObject.read(file))
        expect(reg.transform_point([10.0, 20.0, 30.0])).to eq [-22.0, 111.0, 33.0]
      end

    end


    context "with invalid input" do

      it "raises ArgumentError when the argument is not a DObject" do
        expect { DeformableRegistration.new("not a DObject") }.to raise_error(ArgumentError)
      end

      it "raises ArgumentError when the object has no Deformable Registration Sequence" do
        expect { DeformableRegistration.new(DObject.new) }.to raise_error(ArgumentError)
      end

      it "raises ArgumentError when the vector grid data does not match the grid dimensions" do
        dcm = build_registration([2, 2, 2], [10.0, 10.0, 10.0], constant_vectors([3, 3, 3], [0.0, 0.0, 0.0]))
        expect { DeformableRegistration.new(dcm) }.to raise_error(ArgumentError)
      end

    end


    context "attributes" do

      it "exposes the grid geometry and deformation matrices" do
        dcm = build_registration([4, 4, 4], [10.0, 20.0, 30.0], constant_vectors([4, 4, 4], [0.0, 0.0, 0.0]), :pre => ROT_Z_90)
        reg = DeformableRegistration.new(dcm)
        expect(reg.dimensions).to eq [4, 4, 4]
        expect(reg.resolution).to eq [10.0, 20.0, 30.0]
        expect(reg.pre_deformation_matrix).to eq ROT_Z_90
        expect(reg.post_deformation_matrix).to be_nil
      end

    end

  end
end
