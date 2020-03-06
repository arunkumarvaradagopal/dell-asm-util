# frozen_string_literal: true

require "asm/errors"
require "asm/wsman"
require "asm/translatable"
require "hashie"
require "asm/network_configuration/nic_view"
require "asm/network_configuration/nic_type"
require "asm/network_configuration/nic_info"

module ASM
  # The NetworkConfiguration class is a wrapper class to make it easier to work
  # with the networking data generated by the ASM GUI.
  #
  # The data format is different for blades and racks. Both cases contain
  # lists of interfaces (ports) and partitions. However in the blade case
  # the interfaces are contained in the fabrics field and in the rack case
  # there is another top-level field called interfaces (really cards) that
  # contains the inner # interfaces (ports).
  #
  # Some other oddities to note about this data:
  #
  # - fabrics are always present even for the rack server case. The fields
  #   are simply not populated with data.
  #
  # - partitions greater than one are present even when an interface is not
  #   partitioned.
  #
  # To make the data more uniform this class provides a virtual cards field
  # which can be used instead of fabrics or interfaces. It is populated for both
  # the rack and blade case and has irrelevant data (fabrics / interfaces that
  # are not enabled, partitions when the interface is not partitioned, etc.)
  # stripped out. All partitions can be uniformly iterated over with something
  # like:
  #
  # nc = ASM::NetworkConfiguration.new(params['network_configuration'])
  # nc.cards.each do |card|
  #   card.each do |interface|
  #     interface.each do |partition|
  #       networks = partion.networkObjects
  #       # ... do whatever
  #     end
  #   end
  # end
  #
  # See the add_nics! method for a way to tie the network configuration data
  # directly to the physical nics / ports / partitions.
  class NetworkConfiguration
    include Translatable

    attr_reader(:logger)
    attr_reader(:cards)

    def initialize(network_config_hash, logger=nil)
      @logger = logger
      mash = Hashie::Mash.new(network_config_hash)
      @hash = mash.to_hash
      @cards = build_cards(mash.interfaces)
    end

    def has_fc?
      !!@has_fc
    end

    def get_wsman_nic_info(endpoint)
      fqdd_to_mac = ASM::WsMan.get_mac_addresses(endpoint, logger)
      fqdd_to_mac.keys.map do |fqdd|
        nic = NicView.new(fqdd, logger)
        nic.mac_address = fqdd_to_mac[fqdd]
        nic
      end
    end

    def name_to_fabric(fabric_name)
      if fabric_name =~ /Fabric ([A-Z])/
        $1
      else
        raise(ArgumentError, "Invalid fabric name #{fabric_name}")
      end
    end

    def name_to_port(port_name)
      if port_name =~ /Port ([0-9]*)/
        $1.to_i
      else
        raise(ArgumentError, "Invalid port name #{port_name}")
      end
    end

    def name_to_partition(partition_name)
      if partition_name =~ /([0-9]*)/
        $1.to_i
      else
        raise(ArgumentError, "Invalid partition name #{partition_name}")
      end
    end

    def get_partitions(*network_types)
      cards.collect do |fabric|
        fabric.interfaces.collect do |port|
          port.partitions.find_all do |partition|
            partition.networkObjects&.find do |network|
              network_types.include?(network.type)
            end
          end
        end
      end.flatten
    end

    # Retrieve all partitions that have the specified network
    #
    # @param network_id [String] network id
    # @return [Array<Hash>] list of partitions with the network
    def get_partitions_by_id(network_id)
      collect_from_partitions do |partition|
        partition if partition.networkObjects && partition.networkObjects.find do |network|
          network["id"] == network_id
        end
      end.flatten.compact
    end

    def get_all_partitions # rubocop:disable Naming/AccessorMethodName
      cards.collect do |fabric|
        fabric.interfaces.collect do |port|
          port.partitions.find_all do |partition|
            partition.networkObjects && !partition.networkObjects.empty?
          end
        end
      end.flatten
    end

    def collect_from_partitions
      cards.collect do |fabric|
        fabric.interfaces.collect do |port|
          port.partitions.collect do |partition|
            yield partition
          end
        end
      end
    end

    def get_all_fqdds # rubocop:disable Naming/AccessorMethodName
      collect_from_partitions(&:fqdd).flatten
    end

    # Finds all networks of one of the specified network types
    def get_networks(*network_types)
      collect_from_partitions do |partition|
        (partition.networkObjects || []).find_all do |network|
          network_types.include?(network.type)
        end
      end.flatten.uniq
    end

    def macs_for_network(network_id)
      collect_from_partitions do |partition|
        (partition.networkObjects || []).collect do |network_obj|
          partition.mac_address if network_obj["id"] == network_id
        end
      end.flatten.compact
    end

    # Returns the network object for the given network type.  This method raises
    # an exception if more than one network is found, so it is never valid to
    # call it for network types that may have more than one network associated
    # with them such as iSCSI or public/private lan.
    def get_network(network_type)
      ret = get_networks(network_type)
      # If we get an empty network, send back as nil
      # We don't want to raise an error for brownfield where networks can be missing
      return nil if ret.empty?

      if ret.size == 1
        ret[0]
      else
        raise("There should be only one #{network_type} network but found #{ret.size}: #{ret.collect(&:name)}")
      end
    end

    def get_static_ips(*network_types)
      get_networks(*network_types).collect do |network|
        network.staticNetworkConfiguration.ipAddress if ASM::Util.to_boolean(network.static)
      end.compact.uniq
    end

    def build_cards(interfaces)
      return [] unless interfaces

      partition_i = 0
      interface_i = 0
      card_i = 0
      cards = []
      @has_fc = false

      interfaces.each do |orig_card| # rubocop:disable Metrics/BlockLength
        # For now we are discarding FC interfaces!
        @has_fc ||= ASM::Util.to_boolean(orig_card.enabled) && orig_card.fabrictype == "fc"

        next unless ASM::Util.to_boolean(orig_card.enabled) && orig_card.fabrictype != "fc"

        card = Hashie::Mash.new(orig_card)
        card.interfaces = []
        card.nictype = NicType.new(card.nictype)
        orig_card.interfaces.each do |orig_interface| # rubocop:disable Metrics/BlockLength
          interface = Hashie::Mash.new(orig_interface)
          interface.partitions = []
          port_no = name_to_port(orig_interface.name).to_i
          # Assuming all usable ports enumerate first, which is currently the
          # case but may not always be... (i.e. on 2x10Gb,2x1Gb combo cards
          # the 1Gb ports come second)
          n_ports = card.nictype.n_usable_ports
          max_partitions = card.nictype.n_partitions
          next unless n_ports >= port_no

          orig_interface.interface_index = interface_i
          interface_i += 1
          orig_interface.partitions.each do |partition|
            partition_no = name_to_partition(partition.name)
            # at some point the partitioned flag moved from the interface
            # to the card (which is the correct place, all ports must be
            # either partitioned or not)
            partitioned = card.partitioned || interface.partitioned
            next unless partition_no == 1 || (partitioned && partition_no <= max_partitions)

            partition.port_no = port_no
            partition.partition_no = partition_no
            partition.partition_index = partition_i
            partition_i += 1

            # Strip networkObject ipRange which can vary for the same network,
            # making it difficult to determine network uniqueness
            partition.networkObjects = (partition.networkObjects || []).map do |network|
              network = network.dup
              if network.staticNetworkConfiguration
                network.staticNetworkConfiguration = network.staticNetworkConfiguration.dup
                network.staticNetworkConfiguration.delete("ipRange")
              end
              network
            end

            interface.partitions.push(partition)
          end
          card.interfaces.push(interface)
        end
        card.card_index = card_i
        card_i += 1
        cards.push(card)
      end
      cards
    end

    # Compare nics at the card level by type and card number. Type is compared
    # lexicographically, but the real intent is that Integrated nics are ordered
    # before Slot nics.
    def compare_cards(nic1, nic2)
      type_cmp = nic1.type <=> nic2.type
      if type_cmp != 0
        type_cmp
      else
        nic1.card.to_i <=> nic2.card.to_i
      end
    end

    def n_partitions(card)
      ns = card.interfaces.map { |i| i.partitions.size }.uniq

      return 1 if ns.empty?
      return ns.first if ns.size == 1

      raise("Different number of partitions requested for ports on %s: %s" %
                [card.name, card.interfaces.map { |i| "Interface: %s # partitions: %d" % [i.name, i.partitions.size] }.join(", ")])
    end

    # Add nic, fqdd and mac_address fields to the partition data. This info
    # is obtained by calling WsMan to get the NicInfo.
    #
    # By default an exception is raised if nic info is not found for a
    # partition; however if options[:add_partitions] is set to true, nic
    # and fqdd fields will be generated for partition numbers greater than one
    # based off of the partition 1 fqdd. This allows the partitions to be used
    # directly for generating partitioned config.xml data even when the server
    # nics are not currently partitioned.
    def add_nics!(endpoint, options={})
      options = {:add_partitions => false}.merge(options)
      nics = NicInfo.fetch(endpoint, logger)

      # Instance variable to track, add_nics! is invoked
      @network_config_add_nic = true

      missing = []
      cards.each do |card| # rubocop:disable Metrics/BlockLength
        fqdd = card.interfaces.first.fqdd
        if fqdd
          # If FQDD passed through in config data, use that
          fqdd_nic_view = NicView.new(fqdd)
          index = nics.find_index do |nic|
            fqdd_nic_view.card_prefix == nic.ports.first.nic_view.card_prefix
          end
        else
          # otherwise match by type and number partitions
          index = nics.find_index { |n| !n.disabled? && n.nic_type == card.nictype.nictype && n.n_partitions >= n_partitions(card) }
        end

        if index.nil?
          missing << card
        else
          nic = nics.delete_at(index)
          card.nic_info = nic
          card.interfaces.each_with_index do |interface, interface_i|
            interface.nic_port = nic.ports[interface_i]
            interface.partitions.each_with_index do |partition, partition_i|
              partition.nic_view = nic.ports[interface_i].partitions[partition_i]
              partition_no = name_to_partition(partition.name)
              nic_partition = nic.find_partition(name_to_port(interface.name).to_s, partition_no.to_s)
              if nic_partition
                partition.fqdd = nic_partition.fqdd
                partition.mac_address = nic_partition.mac_address
              elsif partition_no > 1 && options[:add_partitions]
                first_partition = nic.find_partition(name_to_port(interface.name).to_s, "1")
                partition.fqdd = first_partition.create_with_partition(partition_no).fqdd
              end
            end
            interface.fqdd = interface.partitions.first.fqdd
          end
        end
      end

      unless missing.empty?
        card_list = missing.map { |card| "%s (%s)" % [card.name, card.nictype.nictype] }.join(", ")
        available_list = "available: %s" % nics.map do |nic|
          "%s (%s%s)" % [nic.card_prefix, nic.nic_type, !nic.disabled? ? "" : ", disabled"]
        end.join(", ")
        raise("Missing NICs for %s; %s" % [card_list, nics.empty? ? "none found" : available_list])
      end
    end

    # resets virtual mac addresses of partitions to their permanent mac address
    def reset_virt_mac_addr(endpoint)
      permanent_macs = ASM::WsMan.get_permanent_mac_addresses(endpoint, logger)
      get_all_partitions.each do |partition|
        partition["lanMacAddress"] = permanent_macs[partition.fqdd]
        partition["iscsiMacAddress"] = permanent_macs[partition.fqdd]
        partition["iscsiIQN"] = ""
        partition.networkObjects.each do |net|
          next unless net.static

          static_net = net.staticNetworkConfiguration
          static_net.gateway = "0.0.0.0"
          static_net.subnet = "0.0.0.0"
          static_net.ipAddress = "0.0.0.0"
        end
      end
    end

    # Returns the information to be used for creating the NIC Team / NIC Bonding
    # Information contains the networks and associated MAC Addresses
    #
    # @option options [Boolean] :include_pxe flag to include pxe in teams or not
    # @return [Hash] Hash having unique list of networks and corresponding server MAC addresses
    # @example
    #   { [ :TeamInfo => { :networks => [...], :mac_addresses => [ ... ] ] }
    def teams(opt={})
      @teams = nil if opt[:refresh_info]

      @teams ||= begin
        raise("NIC MAC Address information needs to updated to network configuration. Invoke nc.add_nics!") unless @network_config_add_nic

        networks = []
        mac_teams = {}
        partitions = get_all_partitions
        partitions.each do |partition|
          network_objects = partition.networkObjects.dup
          network_objects.reject! { |network| network.type == "PXE" } unless opt[:include_pxe]

          # Need to find partitions which has same set of networks, for team
          next unless network_objects && !network_objects.empty?

          network_objects.each do |obj|
            networks.push(obj).uniq!
          end
        end
        @teams = []
        networks.each do |network|
          mac_team = macs_for_network(network["id"])
          mac_teams[mac_team] ||= []
          mac_teams[mac_team].push(network)
        end
        mac_teams.each do |macs, team_networks|
          @teams.push(:networks => team_networks, :mac_addresses => macs)
        end
        @teams
      end
    end

    # Returns the network configuration data in hash form
    #
    # The returned value is roughly analogous to the hash that the NetworkConfiguration
    # instance was created from with the following modifications:
    #
    # - disabled / unused interfaces are not returned
    # - the port and partition data is augmented with the chosen NIC FQDD and mac
    #   address data for the matching physical NIC if {#add_nics!} was previously called.
    # - order of the cards (called "interfaces" at the top level) is not preserved.
    #   In particular all FC interfaces will be at the end of the "interfaces" list.
    #
    # @note The returned data will not have any complex types, so it can be safely
    # used in yaml data.
    #
    # @return [Hash]
    def to_hash
      ret = {"id" => @hash["id"], "interfaces" => []}

      # Get the ethernet data sans complex types like NicView and NicPort
      cards.each do |card|
        card_data = card.to_hash
        card_data["nictype"] = card_data["nictype"].to_s # convert back to string like 2x10Gb
        card_data.delete("nic_info") # remove NicInfo instance
        card_data["interfaces"].each do |port|
          port.delete("nic_port") # remove NicPort instance
          port["partitions"].each do |partition|
            partition.delete("nic_view") # remove NicView instance
          end
        end
        ret["interfaces"] << card_data
      end

      # Add back in the FC interfaces which aren't captured in #cards
      @hash["interfaces"].each do |interface|
        ret["interfaces"] << interface.dup if interface["fabrictype"] != "ethernet"
      end

      ret
    end
  end
end
