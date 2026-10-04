# encoding: ASCII-8BIT

require 'spec_helper'

module DICOM

  describe DeformableSpatialRegistration do

    ORIGIN = [1.0, 2.0, 3.0]
    SPACING = [2.0, 4.0, 8.0]
    DIMENSIONS = [2, 2, 2]
    AXIAL_ORIENTATION = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

    let(:registration) { DeformableSpatialRegistration.new(dcm) }

    describe '#transform_points' do
      context 'with constant displacement' do
        let(:dcm) do
          build_registration(:constant => [0.2, -0.3, 0.4])
        end

        it 'interpolates the same displacement for an interior point' do
          point = [2.0, 5.0, 7.0]
          result = registration.transform_points(point)
          expect(result).to be_close_to([2.2, 4.7, 7.4])
        end

        it 'keeps the points grouped as supplied' do
          points = [[2.0, 5.0, 7.0], [1.0, 2.0, 3.0]]
          result = registration.transform_points(points)
          expect(result).to be_close_to([[2.2, 4.7, 7.4], [1.2, 1.7, 3.4]])
        end
      end

      context 'with varying displacement' do
        let(:constant_dcm) { build_registration(:pre_matrix => rotation_z_90, :constant => [0.2, -0.3, 0.4]) }
        let(:dcm) do
          build_registration(:post_matrix => rotation_z_90, :displacement => varying_displacement)
        end

        it 'trilinearly interpolates displacement before applying post rotation' do
          point = [2.0, 5.0, 7.0]
          result = registration.transform_points(point)

          displacement = [5.0, 0.7, -2.0]
          displaced = [point[0] + displacement[0], point[1] + displacement[1], point[2] + displacement[2]]
          expected = [
            -displaced[1],
            displaced[0],
            displaced[2]
          ]
          expect(result).to be_close_to(expected)
        end

        it 'applies pre rotation before adding displacement' do
          point = [5.0, -2.0, 7.0]
          result = DeformableSpatialRegistration.new(constant_dcm).transform_points(point)
          rotated_point = [-point[1], point[0], point[2]]
          expect(result).to be_close_to([rotated_point[0] + 0.2, rotated_point[1] - 0.3, rotated_point[2] + 0.4])
          expect(result).not_to be_close_to([
            point[0] + 0.2,
            point[1] - 0.3,
            point[2] + 0.4
          ])
        end

        it 'differs from rotating the source point before adding displacement' do
          point = [2.0, 5.0, 7.0]
          result = registration.transform_points(point)

          rotated_point = [-point[1], point[0], point[2]]
          wrong_order = [
            rotated_point[0] + 5.0,
            rotated_point[1] + 0.7,
            rotated_point[2] - 2.0
          ]
          expect(result).not_to be_close_to(wrong_order)
        end
      end

      context 'outside the deformation grid' do
        let(:dcm) do
          build_registration(:constant => [0.2, -0.3, 0.4])
        end

        it 'raises by default' do
          expect { registration.transform_points([4.0, 2.0, 3.0]) }.to raise_error(RangeError)
        end

        it 'returns nil without extrapolating when asked for an undefined result' do
          result = registration.transform_points(
            [[2.0, 5.0, 7.0], [4.0, 2.0, 3.0]],
            :outside_grid => :nil
          )
          expect(result.first).to be_close_to([2.2, 4.7, 7.4])
          expect(result.last).to be_nil
        end

        it 'accepts the undefined policy as a string' do
          result = registration.transform_points([4.0, 2.0, 3.0], :outside_grid => 'undefined')
          expect(result).to be_nil
        end
      end

      context 'with a non-axis-aligned grid' do
        let(:dcm) do
          build_registration(
            :constant => [0.2, -0.3, 0.4],
            :orientation => [0.0, 1.0, 0.0, -1.0, 0.0, 0.0]
          )
        end

        it 'uses the grid origin, spacing and direction before displacement' do
          point = [-3.0, 3.0, 7.0]
          result = registration.transform_points(point)
          expect(result).to be_close_to([-2.8, 2.7, 7.4])
        end
      end
    end

    describe '::transform_points' do
      let(:dcm) do
        build_registration(:constant => [0.2, -0.3, 0.4])
      end

      it 'creates a registration and transforms the points' do
        result = DeformableSpatialRegistration.transform_points(dcm, [2.0, 5.0, 7.0])
        expect(result).to be_close_to([2.2, 4.7, 7.4])
      end
    end

    def build_registration(options={})
      dcm = DObject.new
      Sequence.new('0064,0002', :parent => dcm)
      registration_item = Item.new(:parent => dcm['0064,0002'])

      Sequence.new('0064,0005', :parent => registration_item)
      grid_item = Item.new(:parent => registration_item['0064,0005'])
      Element.new('0020,0032', ORIGIN.join('\\'), :parent => grid_item)
      Element.new('0020,0037', (options[:orientation] || AXIAL_ORIENTATION).join('\\'), :parent => grid_item)
      Element.new('0064,0007', DIMENSIONS, :parent => grid_item)
      Element.new('0064,0008', SPACING, :parent => grid_item)

      vectors = options[:displacement] || Array.new(8, options[:constant] || [0.0, 0.0, 0.0])
      Element.new('0064,0009', vectors.flatten, :parent => grid_item)

      add_matrix_sequence(registration_item, '0064,000F', options[:pre_matrix] || identity_matrix)
      add_matrix_sequence(registration_item, '0064,0010', options[:post_matrix] || identity_matrix)
      dcm
    end

    def add_matrix_sequence(registration_item, sequence_tag, matrix)
      Sequence.new(sequence_tag, :parent => registration_item)
      outer_item = Item.new(:parent => registration_item[sequence_tag])
      Sequence.new('0070,0309', :parent => outer_item)
      matrix_registration_item = Item.new(:parent => outer_item['0070,0309'])
      Sequence.new('0070,030A', :parent => matrix_registration_item)
      matrix_item = Item.new(:parent => matrix_registration_item['0070,030A'])
      Element.new('3006,00C6', matrix.join('\\'), :parent => matrix_item)
    end

    def identity_matrix
      [
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
      ]
    end

    def rotation_z_90
      [
        0.0, -1.0, 0.0, 0.0,
        1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
      ]
    end

    def varying_displacement
      vectors = []
      DIMENSIONS[2].times do |z|
        DIMENSIONS[1].times do |y|
          DIMENSIONS[0].times do |x|
            physical_x = ORIGIN[0] + x * SPACING[0]
            physical_y = ORIGIN[1] + y * SPACING[1]
            physical_z = ORIGIN[2] + z * SPACING[2]
            vectors << [physical_y, physical_z * 0.1, -physical_x]
          end
        end
      end
      vectors
    end

    RSpec::Matchers.define :be_close_to do |expected|
      match do |actual|
        return false unless actual
        values = actual.is_a?(Array) && actual.first.is_a?(Array) ? actual.zip(expected) : [[actual, expected]]
        values.all? do |actual_point, expected_point|
          actual_point.zip(expected_point).all? { |a, b| (a - b).abs < 1e-6 }
        end
      end
    end

  end
end
