import Foundation

// Identifying a network, and deciding what to try first on it. Both are pure, so both
// are checked against real command output captured from a live machine.
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)   \(detail())") }
}

print("Test 1 - the gateway comes out of `route -n get default`")
let routeOutput = """
   route to: default
destination: default
       mask: default
    gateway: 192.0.2.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
"""
check("found", NetworkIdentity.parseGateway(routeOutput) == "192.0.2.1",
      String(describing: NetworkIdentity.parseGateway(routeOutput)))
// "route to: default" comes first and would match a looser parser.
check("not confused by the line above it",
      NetworkIdentity.parseGateway(routeOutput) != "default")
check("no default route means no network",
      NetworkIdentity.parseGateway("   route to: default\n") == nil)
check("empty output is safe", NetworkIdentity.parseGateway("") == nil)

print("Test 2 - the router's MAC comes out of `arp`")
// Real output. Note the THIRD octet: arp does not zero-pad, and every other tool does.
let arpOutput = "? (192.0.2.1) at a1:b:22:33:44:55 on en0 ifscope [ethernet]"
check("parsed", NetworkIdentity.parseMAC(arpOutput) != nil)
check("ZERO-PADDED, so one router is one key",
      NetworkIdentity.parseMAC(arpOutput) == "a1:0b:22:33:44:55",
      NetworkIdentity.parseMAC(arpOutput) ?? "nil")
check("already-padded input is unchanged",
      NetworkIdentity.parseMAC("? (1.2.3.4) at a1:0b:22:33:44:55 on en0 [ethernet]")
        == "a1:0b:22:33:44:55")
check("case does not make a second network",
      NetworkIdentity.parseMAC("? (1.2.3.4) at A1:0B:22:33:44:55 on en0 [ethernet]")
        == NetworkIdentity.parseMAC(arpOutput))
check("an unresolved gateway is not a network",
      NetworkIdentity.parseMAC("192.0.2.1 (192.0.2.1) -- no entry") == nil)
check("an incomplete entry is rejected",
      NetworkIdentity.parseMAC("? (1.2.3.4) at (incomplete) on en0") == nil)
check("a short address is rejected",
      NetworkIdentity.parseMAC("? (1.2.3.4) at a1:0b:22 on en0") == nil)

print("Test 3 - a network that names itself in its DHCP lease")
let dhcp = """
server_identifier (ip): 192.0.2.53
router (ip_mult): {192.0.2.1}
domain_name_server (ip_mult): {192.0.2.53, 192.0.2.54}
domain_name (string): corp.example.com
"""
check("the domain is the label", NetworkIdentity.parseDHCPDomain(dhcp) == "corp.example.com",
      NetworkIdentity.parseDHCPDomain(dhcp) ?? "nil")
// domain_name_server appears FIRST and starts with the same eleven characters.
check("not the list of DNS servers",
      !(NetworkIdentity.parseDHCPDomain(dhcp) ?? "").contains("192.0.2.5"))
check("a lease without one falls through",
      NetworkIdentity.parseDHCPDomain("router (ip_mult): {192.168.1.1}\n") == nil)

print("Test 4 - what to try first")
check("nothing learned means the usual order",
      RouteStore.probeOrder(pinned: nil, remembered: nil) == [.direct, .viaNAS])
check("a network where direct worked tries direct first",
      RouteStore.probeOrder(pinned: nil, remembered: .direct) == [.direct, .viaNAS])
// The whole point: skip the probe that is known to time out here.
check("a network that needed the NAS tries the NAS FIRST",
      RouteStore.probeOrder(pinned: nil, remembered: .viaNAS) == [.viaNAS, .direct],
      "\(RouteStore.probeOrder(pinned: nil, remembered: .viaNAS))")
check("but the other route still follows, so a network can change its mind",
      RouteStore.probeOrder(pinned: nil, remembered: .viaNAS).count == 2)
check("a pinned route overrides what was learned",
      RouteStore.probeOrder(pinned: .direct, remembered: .viaNAS) == [.direct])
check("and is the only thing tried",
      RouteStore.probeOrder(pinned: .viaNAS, remembered: .direct) == [.viaNAS])

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
