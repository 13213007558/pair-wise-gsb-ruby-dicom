# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe RTSTRUCTMasker do

    it 'rasterizes a single tilted target plane from two-dimensional pixel spacing' do
      angle = Math::PI / 4
      cosine = Math.cos(angle)
      sine = Math.sin(angle)
      masker = RTSTRUCTMasker.new(
        :position => [0.5, -0.5, 0.0],
        :orientation => [cosine, sine, 0.0, -sine, cosine, 0.0],
        :spacing => [1.0, 1.0],
        :columns => 3,
        :rows => 3
      )
      row = [cosine, sine, 0.0]
      column = [-sine, cosine, 0.0]
      origin = [0.5, -0.5, 0.0]
      contour = [
        origin,
        origin.each_with_index.map { |value, index| value + 3.0 * column[index] },
        origin.each_with_index.map { |value, index| value + 3.0 * row[index] + 3.0 * column[index] },
        origin.each_with_index.map { |value, index| value + 3.0 * row[index] }
      ]

      result = masker.rasterize([contour])

      expect(result.mask).to eq([
        [1, 1, 1],
        [1, 1, 1],
        [1, 1, 1]
      ])
    end

    let(:masker) do
      RTSTRUCTMasker.new(
        :position => [-2.0, -2.0, -1.0],
        :orientation => [1, 0, 0, 0, 1, 0],
        :spacing => [1.0, 1.0, 2.0],
        :columns => 5,
        :rows => 5,
        :frames => 2
      )
    end

    describe '#rasterize' do

      it 'positions a synthetic contour on an explicitly specified oblique target plane' do
        angle = Math::PI / 6
        cosine = Math.cos(angle)
        sine = Math.sin(angle)
        row_direction = [cosine, sine, 0.0]
        column_direction = [-sine, cosine, 0.0]
        frame_direction = [0.0, 0.0, 1.0]
        position = [-1.5, -1.5, 3.0]
        oblique_masker = RTSTRUCTMasker.new(
          :position => position,
          :orientation => row_direction + column_direction + frame_direction,
          :spacing => [1.0, 1.0, 1.0],
          :columns => 4,
          :rows => 4,
          :frames => 2
        )

        def point(row_direction, column_direction, position, row, column, frame_offset)
          position
            .each_with_index.map { |_, index| position[index] + row * row_direction[index] + column * column_direction[index] + frame_offset[index] }
        end

        frame_offset = frame_direction.map { |component| component }
        rectangle = [
          point(row_direction, column_direction, position, 0.0, 0.0, frame_offset),
          point(row_direction, column_direction, position, 0.0, 3.0, frame_offset),
          point(row_direction, column_direction, position, 3.0, 3.0, frame_offset),
          point(row_direction, column_direction, position, 3.0, 0.0, frame_offset)
        ]

        result = oblique_masker.rasterize([rectangle])

        expect(result.mask[0]).to all(all(eq(0)))
        expect(result.mask[1]).to eq([
          [1, 1, 1, 1],
          [1, 1, 1, 1],
          [1, 1, 1, 1],
          [1, 1, 1, 1]
        ])
        expect(result.out_of_tolerance?).to be_falsey
      end

      it 'uses XOR semantics for a closed outer contour and a hole contour' do
        outer = [
          [-2.0, -2.0, -1.0],
          [4.0, -2.0, -1.0],
          [4.0, 4.0, -1.0],
          [-2.0, 4.0, -1.0]
        ]
        hole = [
          [-1.0, -1.0, -1.0],
          [1.0, -1.0, -1.0],
          [1.0, 1.0, -1.0],
          [-1.0, 1.0, -1.0]
        ]

        result = masker.rasterize([outer, hole])

        expect(result.mask[0]).to eq([
          [1, 1, 1, 1, 1],
          [1, 0, 0, 0, 1],
          [1, 0, 0, 0, 1],
          [1, 0, 0, 0, 1],
          [1, 1, 1, 1, 1]
        ])
      end

      it 'includes polygon boundary voxel centers and accepts contours within tolerance' do
        tolerance_masker = RTSTRUCTMasker.new(
          :position => [0.0, 0.0, 0.0],
          :orientation => [1, 0, 0, 0, 1, 0],
          :spacing => [1.0, 1.0, 1.0],
          :columns => 2,
          :rows => 2,
          :frames => 1,
          :tolerance => 0.5
        )
        boundary_contour = [
          [0.0, 0.0, 0.25],
          [1.0, 0.0, 0.25],
          [1.0, 1.0, 0.25],
          [0.0, 1.0, 0.25]
        ]

        result = tolerance_masker.rasterize([
          {
            :number => 7,
            :geometric_type => 'CLOSED_PLANAR',
            :points => boundary_contour
          }
        ])

        expect(result.mask[0]).to eq([
          [1, 1],
          [1, 1]
        ])
        expect(result.out_of_tolerance_contours).to be_empty
      end

      it 'covers a voxel center exactly on an outer contour edge' do
        outer = [
          [0.0, 0.0, 0.0],
          [3.0, 0.0, 0.0],
          [3.0, 3.0, 0.0],
          [0.0, 3.0, 0.0]
        ]
        hole = [
          [1.0, 1.0, 0.0],
          [2.0, 1.0, 0.0],
          [2.0, 2.0, 0.0],
          [1.0, 2.0, 0.0]
        ]
        boundary_masker = RTSTRUCTMasker.new(
          :position => [0.0, 0.0, 0.0],
          :orientation => [1, 0, 0, 0, 1, 0],
          :spacing => [1.0, 1.0],
          :columns => 4,
          :rows => 4
        )

        result = boundary_masker.rasterize([outer, hole])

        expect(result.mask).to eq([
          [1, 1, 1, 1],
          [1, 0, 0, 1],
          [1, 0, 0, 1],
          [1, 1, 1, 1]
        ])
      end

      it 'reports and skips a closed contour farther than tolerance from every target plane' do
        far_contour = [
          [-2.0, -2.0, 4.6],
          [2.0, -2.0, 4.6],
          [2.0, 2.0, 4.6],
          [-2.0, 2.0, 4.6]
        ]
        tolerance_masker = RTSTRUCTMasker.new(
          :position => [-2.0, -2.0, -1.0],
          :orientation => [1, 0, 0, 0, 1, 0],
          :spacing => [1.0, 1.0, 2.0],
          :columns => 5,
          :rows => 5,
          :frames => 2,
          :tolerance => 0.5
        )

        result = tolerance_masker.rasterize([
          {
            :number => 9,
            :geometric_type => 'CLOSED_PLANAR',
            :points => far_contour
          }
        ])

        expect(result.mask.flatten).to all(eq(0))
        expect(result.out_of_tolerance?).to be_truthy
        expect(result.out_of_tolerance_contours.first).to include(
          :number => 9,
          :frame => 3,
          :in_grid => false,
          :geometric_type => 'CLOSED_PLANAR'
        )
        expect(result.out_of_tolerance_contours.first[:distance]).to be_within(1e-12).of(3.6)
        expect(result.warnings.first).to include('3.6 mm', 'frame (3)', '0.5 mm')
      end

      it 'accepts flattened numeric-string contour data like DICOM Contour Data' do
        contour = ['0', '0', '-1', '3', '0', '-1', '3', '3', '-1', '0', '3', '-1']

        result = masker.rasterize([contour])

        expect(result.mask[0][0..1]).to all(all(eq(0)))
        expect(result.mask[0][2][0..3]).to eq([0, 0, 1, 1])
        expect(result.mask[0][3][0..3]).to eq([0, 0, 1, 1])
        expect(result.mask[0][4][0..1]).to eq([0, 0])
        expect(result.mask[0][4][2..4]).to eq([1, 1, 1])
      end

      it 'rejects geometry that is not closed planar' do
        contour = {
          :geometric_type => 'POINT',
          :points => [
            [0.0, 0.0, -1.0],
            [1.0, 0.0, -1.0],
            [1.0, 1.0, -1.0]
          ]
        }

        expect { masker.rasterize([contour]) }.to raise_error(ArgumentError, /Unsupported contour geometric type POINT/)
      end

      it 'requires unit orientation vectors' do
        expect do
          RTSTRUCTMasker.new(
            :position => [0.0, 0.0, 0.0],
            :orientation => [2.0, 0.0, 0.0, 0.0, 1.0, 0.0],
            :spacing => [1.0, 1.0],
            :columns => 2,
            :rows => 2
          )
        end.to raise_error(ArgumentError, /unit vector/)
      end

      it 'does not allow frame count with two-dimensional spacing' do
        expect do
          RTSTRUCTMasker.new(
            :position => [0.0, 0.0, 0.0],
            :orientation => [1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
            :spacing => [1.0, 1.0],
            :columns => 2,
            :rows => 2,
            :frames => 2
          )
        end.to raise_error(ArgumentError, /two-dimensional/)
      end

    end

  end

end
