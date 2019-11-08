# frozen_string_literal: true

require "spec_helper"
require "asm/network_configuration"

describe ASM::NetworkConfiguration::NicInfo do
  let(:logger) { stub(:debug => nil, :warn => nil, :info => nil) }
  let(:endpoint) { mock("rspec-endpoint") }
  let(:integrated_4x10gb_nic_views) do
    1.upto(4).map do |i|
      {"FQDD" => "NIC.Integrated.1-%d-1" % i,
       "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
       "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i,
       "VendorName" => "Broadcom",
       "ProductName" => "57840"}
    end
  end
  let(:integrated_2x10gb_partitioned_nic_views) do
    1.upto(2).map do |port|
      1.upto(4).map do |partition|
        {"FQDD" => "NIC.Integrated.1-%d-%d" % [port, partition],
         "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % port,
         "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % port,
         "VendorName" => "Broadcom",
         "ProductName" => "57810"}
      end
    end.flatten
  end
  let(:mezz_2x10gb_nic_views) do
    1.upto(2).map do |i|
      {"FQDD" => "NIC.Mezzanine.2B-%d-1" % i,
       "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
       "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i,
       "VendorName" => "Broadcom",
       "ProductName" => "57810"}
    end
  end

  describe "#ASM::NetworkConfiguration::NicInfo" do
    describe ".fetch" do
      it "should create NicInfo based on NicView and BiosEnumeration" do
        ASM::WsMan.expects(:get_nic_view).with(endpoint, logger).returns("rspec_nic_views")
        ASM::WsMan.expects(:get_bios_enumeration).with(endpoint, logger).returns("rspec_bios_info")
        ASM::NetworkConfiguration::NicInfo.expects(:create).with("rspec_nic_views", "rspec_bios_info", logger)
        ASM::NetworkConfiguration::NicInfo.fetch(endpoint, logger)
      end

      it "should parse DCIM_NICView with both 1B and 1C Mezzanine NICs" do
        nic_views_xml = SpecHelper.load_fixture("network_configuration/fab_b_fab_c_nic_view.xml")
        ASM::WsMan.expects(:invoke)
                  .with(endpoint, "enumerate", "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_NICView", :logger => logger)
                  .returns(nic_views_xml)
        ASM::WsMan.expects(:get_bios_enumeration).with(endpoint, logger).returns([])
        nic_infos = ASM::NetworkConfiguration::NicInfo.fetch(endpoint, logger)
        expect(nic_infos.size).to eq(3)
        nic_infos.each do |nic_info|
          expect(nic_info.nic_type).to eq("2x10Gb")
        end
        expect(nic_infos[0].card_prefix).to eq("NIC.Integrated.1")
        expect(nic_infos[1].card_prefix).to eq("NIC.Mezzanine.1B")
        expect(nic_infos[2].card_prefix).to eq("NIC.Mezzanine.1C")
      end

      it "should recognize Intel X520/I350 2x10Gb,2x1Gb combo card" do
        nic_views_xml = SpecHelper.load_fixture("network_configuration/x520_i350_nic_view.xml")
        ASM::WsMan.expects(:invoke)
                  .with(endpoint, "enumerate", "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_NICView", :logger => logger)
                  .returns(nic_views_xml)
        ASM::WsMan.expects(:get_bios_enumeration).with(endpoint, logger).returns([])
        nic_infos = ASM::NetworkConfiguration::NicInfo.fetch(endpoint, logger)
        expect(nic_infos.size).to eq(2)
        expect(nic_infos[0].nic_type).to eq("2x10Gb,2x1Gb")
        expect(nic_infos[1].nic_type).to eq("2x10Gb")
        expect(nic_infos[0].card_prefix).to eq("NIC.Integrated.1")
        expect(nic_infos[1].card_prefix).to eq("NIC.Slot.4")
      end

      it "should recognize Intel X520/I350 2x10Gb,2x1Gb combo card without LinkSpeed info" do
        nic_views_xml = SpecHelper.load_fixture("network_configuration/x520_i350_nic_view.xml").gsub("<n1:LinkSpeed>3</n1:LinkSpeed>", "<n1:LinkSpeed>0</n1:LinkSpeed>")
        ASM::WsMan.expects(:invoke)
                  .with(endpoint, "enumerate", "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_NICView", :logger => logger)
                  .returns(nic_views_xml)
        ASM::WsMan.expects(:get_bios_enumeration).with(endpoint, logger).returns([])
        nic_infos = ASM::NetworkConfiguration::NicInfo.fetch(endpoint, logger)
        expect(nic_infos.size).to eq(2)
        expect(nic_infos[0].nic_type).to eq("2x10Gb,2x1Gb")
        expect(nic_infos[1].nic_type).to eq("2x10Gb")
        expect(nic_infos[0].card_prefix).to eq("NIC.Integrated.1")
        expect(nic_infos[1].card_prefix).to eq("NIC.Slot.4")
      end

      it "should recognize Intel X710/I350 2x10Gb,2x1Gb combo card" do
        nic_views_xml = SpecHelper.load_fixture("network_configuration/x710_i350_nic_view.xml")
        ASM::WsMan.expects(:invoke)
                  .with(endpoint, "enumerate", "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_NICView", :logger => logger)
                  .returns(nic_views_xml)
        ASM::WsMan.expects(:get_bios_enumeration).with(endpoint, logger).returns([])
        nic_infos = ASM::NetworkConfiguration::NicInfo.fetch(endpoint, logger)
        expect(nic_infos.size).to eq(1)
        expect(nic_infos[0].nic_type).to eq("2x10Gb,2x1Gb")
        expect(nic_infos[0].card_prefix).to eq("NIC.Integrated.1")
      end

      it "should recognize Mellanox ConnectX-4 LX 25Gb slot card" do
        nic_views_xml = SpecHelper.load_fixture("network_configuration/mellanox_connect_x_4_lx_nic_view.xml")
        ASM::WsMan.expects(:invoke)
                  .with(endpoint, "enumerate", "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_NICView", :logger => logger)
                  .returns(nic_views_xml)
        ASM::WsMan.expects(:get_bios_enumeration).with(endpoint, logger).returns([])
        nic_infos = ASM::NetworkConfiguration::NicInfo.fetch(endpoint, logger)
        expect(nic_infos.size).to eq(2)
        expect(nic_infos[0].nic_type).to eq("2x25Gb")
        expect(nic_infos[0].card_prefix).to eq("NIC.Slot.1")
        expect(nic_infos[1].nic_type).to eq("2x25Gb")
        expect(nic_infos[1].card_prefix).to eq("NIC.Slot.2")
      end

      it "should recognize Mellanox ConnectX-5 EX 100Gb slot card" do
        nic_views_xml = SpecHelper.load_fixture("network_configuration/mellanox_connect_x_5_Ex_100_nic_view.xml")
        ASM::WsMan.expects(:invoke)
                  .with(endpoint, "enumerate", "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_NICView", :logger => logger)
                  .returns(nic_views_xml)
        ASM::WsMan.expects(:get_bios_enumeration).with(endpoint, logger).returns([])
        nic_infos = ASM::NetworkConfiguration::NicInfo.fetch(endpoint, logger)
        expect(nic_infos.size).to eq(2)
        expect(nic_infos[0].nic_type).to eq("2x100Gb")
        expect(nic_infos[0].card_prefix).to eq("NIC.Slot.2")
        expect(nic_infos[1].nic_type).to eq("2x100Gb")
        expect(nic_infos[1].card_prefix).to eq("NIC.Slot.3")
      end
    end

    describe ".create" do
      it "should create NicInfos in correct order" do
        nic_views = integrated_4x10gb_nic_views + mezz_2x10gb_nic_views
        nic_views.reverse
        ret = ASM::NetworkConfiguration::NicInfo.create(nic_views, [], logger)
        expect(ret.size).to eq(2)
        expect(ret[0].product).to eq("57840")
        expect(ret[1].product).to eq("57810")
      end
    end

    describe "#initialize" do
      let(:nic_views) { mezz_2x10gb_nic_views.map { |n| ASM::NetworkConfiguration::NicView.new(n) } }

      it "should validate_nic_view" do
        nic_views = mezz_2x10gb_nic_views.map { |n| ASM::NetworkConfiguration::NicView.new(n) }
        ASM::NetworkConfiguration::NicInfo.expects(:validate_nic_views).with(nic_views)
        ASM::NetworkConfiguration::NicInfo.new(nic_views, [], logger)
      end

      it "should set nic_status" do
        ASM::WsMan.expects(:nic_status).with(nic_views.first.fqdd, []).returns(true)
        info = ASM::NetworkConfiguration::NicInfo.new(nic_views, [], logger)
        expect(info.nic_status).to eq(true)
      end
    end

    describe "#validate_nic_views" do
      it "should fail if nic views from different nic cards" do
        fqdds = %w[NIC.Integrated.1-1-1 NIC.Slot.8-1-1]
        views = fqdds.map { |fqdd| ASM::NetworkConfiguration::NicView.new(fqdd) }
        expect do
          ASM::NetworkConfiguration::NicInfo.validate_nic_views(views)
        end.to raise_error("Cannot create single NicInfo for multiple cards: NIC.Integrated.1, NIC.Slot.8")
      end

      it "should fail if missing ports" do
        nic_views = integrated_4x10gb_nic_views.map do |nic_view|
          n = ASM::NetworkConfiguration::NicView.new(nic_view)
          n unless n.port == "3"
        end.compact

        expect do
          ASM::NetworkConfiguration::NicInfo.validate_nic_views(nic_views)
        end.to raise_error("Port out of order between NIC.Integrated.1-2-1 and NIC.Integrated.1-4-1")
      end

      it "should fail if missing partitions" do
        nic_views = integrated_2x10gb_partitioned_nic_views.map do |nic_view|
          n = ASM::NetworkConfiguration::NicView.new(nic_view)
          n unless n.port == "1" && n.partition_no == "3"
        end.compact

        expect do
          ASM::NetworkConfiguration::NicInfo.validate_nic_views(nic_views)
        end.to raise_error("Partition out of order between NIC.Integrated.1-1-2 and NIC.Integrated.1-1-4")
      end

      it "should fail if first partition is not 1" do
        nic_views = integrated_2x10gb_partitioned_nic_views.map do |nic_view|
          n = ASM::NetworkConfiguration::NicView.new(nic_view)
          n unless n.port == "2" && n.partition_no == "1"
        end.compact

        expect do
          ASM::NetworkConfiguration::NicInfo.validate_nic_views(nic_views)
        end.to raise_error("First partition for NIC.Integrated.1-2-2 should be 1 but got 2")
      end
    end

    def build_nic_info(nic_views)
      nic_views = nic_views.map { |n| ASM::NetworkConfiguration::NicView.new(n) }
      ASM::NetworkConfiguration::NicInfo.new(nic_views, [], logger)
    end

    describe "#disabled?" do
      let(:nic_info) { build_nic_info(integrated_2x10gb_partitioned_nic_views) }

      it "should return true if nic_status contains disabled" do
        nic_info.expects(:nic_status).returns("Disabled")
        expect(nic_info.disabled?).to eq(true)
      end

      it "should return true if all the PermanentMACAddress fields are nil" do
        raw_nic_views = integrated_2x10gb_partitioned_nic_views.map do |v|
          v["PermanentMACAddress"] = nil
          v
        end
        nic_info = build_nic_info(raw_nic_views)
        expect(nic_info.disabled?).to eq(true)
      end

      it "should return false otherwise" do
        nic_info.expects(:nic_status).returns("Enabled")
        expect(nic_info.disabled?).to eq(false)
      end
    end

    describe "#nic_type" do
      it "should recognize 2x100Gb" do
        nic_views = 1.upto(2).map do |i|
          {"FQDD" => "NIC.Slot.2-%d-1" % i,
           "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "LinkSpeed" => "8",
           "pci_device_id" => "1019"}
        end
        nic_info = build_nic_info(nic_views)
        expect(nic_info.nic_type).to eq("2x100Gb")
      end

      it "should recognize 2x10Gb" do
        nic_info = build_nic_info(integrated_2x10gb_partitioned_nic_views)
        expect(nic_info.nic_type).to eq("2x10Gb")
      end

      it "should recognize 2x1Gb" do
        1.upto(2).map do |i|
          {"FQDD" => "NIC.Embedded.1-%d-1" % i,
           "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "LinkSpeed" => "3"}
        end
        nic_info = build_nic_info(integrated_2x10gb_partitioned_nic_views)
        expect(nic_info.nic_type).to eq("2x10Gb")
      end

      it "should recognize 4x10Gb" do
        nic_info = build_nic_info(integrated_4x10gb_nic_views)
        expect(nic_info.nic_type).to eq("4x10Gb")
      end

      it "should recognize 2x10Gb,2x1Gb" do
        nic_views = 1.upto(4).map do |i|
          {"FQDD" => "NIC.Integrated.1-%d-1" % i,
           "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "LinkSpeed" => i < 3 ? "5" : "3"}
        end
        nic_info = build_nic_info(nic_views)
        expect(nic_info.nic_type).to eq("2x10Gb,2x1Gb")
      end

      it "should return unknown otherwise" do
        nic_views = 1.upto(2).map do |i|
          {"FQDD" => "NIC.Integrated.1-%d-1" % i,
           "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i}
        end
        nic_info = build_nic_info(nic_views)
        # unknown because no LinkSpeed or known vendor/model
        expect(nic_info.nic_type).to eq("unknown")
      end
    end

    describe "#split" do
      it "should split where the block returns true" do
        expect(ASM::NetworkConfiguration::NicInfo.split([2, 3, 4, 5, 6], &:odd?)).to eq([[2], [3, 4], [5, 6]])
      end

      it "should not start with an empty list when block returns true for 1st element" do
        expect(ASM::NetworkConfiguration::NicInfo.split([1, 2, 3, 4], &:odd?)).to eq([[1, 2], [3, 4]])
      end

      it "should not end with list of last element when block returns true for last element" do
        expect(ASM::NetworkConfiguration::NicInfo.split([1, 2, 3, 4, 5], &:odd?)).to eq([[1, 2], [3, 4], [5]])
      end
    end

    describe "#n_partitions" do
      it "should return 1 for 1Gb NICs" do
        nic_views = 1.upto(2).map do |i|
          {"FQDD" => "NIC.Slot.1-%d-1" % i,
           "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "LinkSpeed" => "3"}
        end
        nic_info = build_nic_info(nic_views)
        expect(nic_info.n_partitions).to eq(1)
      end

      it "should return 4 if all ports have 4 parititons" do
        nic_info = build_nic_info(integrated_2x10gb_partitioned_nic_views)
        expect(nic_info.n_partitions).to eq(4)
      end

      it "should return 2 for broadcom 57800" do
        nic_views = 1.upto(4).map do |i|
          {"FQDD" => "NIC.Integrated.1-%d-1" % i,
           "CurrentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "PermanentMACAddress" => "04:0A:F7:06:88:5%d" % i,
           "VendorName" => "Broadcom",
           "ProductName" => "57800"}
        end
        nic_info = build_nic_info(nic_views)
        expect(nic_info.n_partitions).to eq(2)
      end
    end

    describe "#<=>" do
      it "should order the cards" do
        integrated1 = build_nic_info(integrated_4x10gb_nic_views)
        mezz2 = build_nic_info(mezz_2x10gb_nic_views)
        expect(integrated1 <=> mezz2).to eq(-1)
        expect(mezz2 <=> integrated1).to eq(1)
        expect(mezz2 <=> mezz2.dup).to eq(0)
      end
    end
  end
end
