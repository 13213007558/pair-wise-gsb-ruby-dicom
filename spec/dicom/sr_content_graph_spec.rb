# encoding: UTF-8

require 'spec_helper'
require 'tempfile'

module DICOM

  describe SRContentGraph do

    let(:dcm) do
      DObject.new.tap do |object|
        object.add_element("0008,0005", "ISO_IR 192")
      end
    end

    let(:graph) { dcm.sr_content_graph }

    def build_small_sr(graph)
      root = graph.insert({
        :value_type => "CONTAINER",
        :concept_name => code("ROOT", "报告根节点")
      })
      finding = root.insert_child({
        :value_type => "TEXT",
        :relationship_type => "CONTAINS",
        :concept_name => code("FIND", "发现"),
        :value => "结节"
      })
      group = root.insert_child({
        :value_type => "CONTAINER",
        :relationship_type => "CONTAINS",
        :concept_name => code("GROUP", "测量组")
      })
      measurement = group.insert_child({
        :value_type => "NUM",
        :relationship_type => "CONTAINS",
        :concept_name => code("SIZE", "大小"),
        :value => {
          :numeric_value => 1.5,
          :unit => code("mm", "毫米", "UCUM")
        }
      })
      image = group.insert_child({
        :value_type => "IMAGE",
        :relationship_type => "SELECTED FROM",
        :value => {
          :sop_class_uid => "1.2.840.10008.5.1.4.1.1.2",
          :sop_instance_uid => "1.2.3.4",
          :frame_numbers => [1, 2]
        }
      })
      group.insert_child({
        :value_type => "SCOORD",
        :relationship_type => "SELECTED FROM",
        :value => {
          :graphic_type => "POINT",
          :coordinates => [[1.25, 2.5]],
          :image => {
            :sop_class_uid => "1.2.840.10008.5.1.4.1.1.2",
            :sop_instance_uid => "1.2.3.4"
          }
        }
      })
      reference = root.insert_child({
        :value_type => "CODE",
        :relationship_type => "INFERRED FROM",
        :reference_path => measurement.path
      })
      [root, finding, group, measurement, image, reference]
    end

    def code(value, meaning, scheme = "DCM")
      {
        :code_value => value,
        :coding_scheme_designator => scheme,
        :code_meaning => meaning
      }
    end

    it "round-trips common SR values and rebinds references after subtree movement" do
      root, finding, group, measurement, image, reference = build_small_sr(graph)
      file = Tempfile.new(["sr", ".dcm"]).path
      dcm.write(file)
      reloaded = DObject.read(file)
      edited = reloaded.sr_content_graph

      expect(edited.find([1,1]).value).to eql "结节"
      expect(edited.find([1,2,1]).value).to eql({
        :numeric_value => 1.5,
        :unit => {
          :code_value => "mm",
          :coding_scheme_designator => "UCUM",
          :code_meaning => "毫米"
        }
      })
      expect(edited.find([1,2,2]).value).to eql({
        :sop_class_uid => "1.2.840.10008.5.1.4.1.1.2",
        :sop_instance_uid => "1.2.3.4",
        :frame_numbers => [1, 2]
      })
      expect(edited.find([1,2,3]).value).to eql({
        :graphic_type => "POINT",
        :coordinates => [[1.25, 2.5]],
        :image => {
          :sop_class_uid => "1.2.840.10008.5.1.4.1.1.2",
          :sop_instance_uid => "1.2.3.4"
        }
      })
      expect(edited.find([1,3]).relationship_type).to eql "INFERRED FROM"
      expect(edited.find([1,3]).referenced_node.path).to eql [1,2,1]

      edited.find([1,2]).move_to(:parent => edited.find([1]), :index => 0)

      expect(edited.find([1,1,1]).value[:numeric_value]).to eql 1.5
      expect(edited.find([1,3]).reference_path).to eql [1,1,1]
      expect(edited.find([1,3]).referenced_node.path).to eql [1,1,1]

      second_file = Tempfile.new(["sr-edited", ".dcm"]).path
      reloaded.write(second_file)
      final = DObject.read(second_file).sr_content_graph
      expect(final.find([1,3]).reference_path).to eql [1,1,1]
      expect(final.find([1,3]).referenced_node.value).to eql({
        :numeric_value => 1.5,
        :unit => {
          :code_value => "mm",
          :coding_scheme_designator => "UCUM",
          :code_meaning => "毫米"
        }
      })
      expect(final.find([1,1,2]).value[:frame_numbers]).to eql [1, 2]
      expect(final.find([1,1,3]).value[:coordinates]).to eql [[1.25, 2.5]]
    end

    it "rejects deletion of referenced content and supports explicit cleanup" do
      build_small_sr(graph)

      expect { graph.delete([1,2,1]) }.to raise_error(
        SRReferenceError,
        /referenced by 1\.3/
      )

      expect(graph.delete([1,3], :strategy => :nullify)).to eql true
      expect(graph.find([1,2]).reference?).to eql false
      expect(graph.delete([1,2,1], :strategy => :cascade)).to eql true
    end

    it "accepts cross references supplied through string content item paths" do
      root = graph.insert({:value_type => "CONTAINER"})
      target = root.insert_child({
        :value_type => "TEXT",
        :relationship_type => "CONTAINS",
        :value => "target"
      })
      reference = root.insert_child({
        :value_type => "TEXT",
        :relationship_type => "INFERRED FROM",
        :reference_path => target.path.join(".")
      })

      expect(reference.reference_path).to eql [1,1]
      expect(reference.referenced_node.path).to eql target.path
      expect(reference.referenced_node.value).to eql "target"
    end

    it "keeps existing references bound after insertion and nested movement" do
      root = graph.insert({:value_type => "CONTAINER"})
      target = root.insert_child({
        :value_type => "TEXT",
        :relationship_type => "CONTAINS",
        :value => "target"
      })
      group = root.insert_child({
        :value_type => "CONTAINER",
        :relationship_type => "CONTAINS"
      })
      reference = group.insert_child({
        :value_type => "TEXT",
        :relationship_type => "INFERRED FROM",
        :reference_path => target.path
      })

      graph.insert({:value_type => "CONTAINER"}, :index => 0)

      expect(target.path).to eql [2,1]
      expect(reference.reference_path).to eql [2,1]

      moved_group = graph.find([2,2])
      moved_group.move_to(:parent => graph.find([2]), :index => 0)

      expect(graph.find([2,1,1]).reference_path).to eql [2,2]
      expect(graph.find([2,1,1]).referenced_node.path).to eql [2,2]
    end

  end

end
