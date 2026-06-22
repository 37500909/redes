import asyncio
import sys
import json
import warnings
warnings.filterwarnings("ignore", message=".*pysnmp-lextudio.*")

from pysnmp.hlapi.asyncio import (
    SnmpEngine, CommunityData, UdpTransportTarget, ContextData,
    ObjectType, ObjectIdentity, nextCmd, getCmd
)

async def walk_oid(engine, transport, community, oid_str):
    """Walk an SNMP OID subtree using nextCmd."""
    results = []
    current_oid = ObjectType(ObjectIdentity(oid_str))
    
    for _ in range(1000):
        errorIndication, errorStatus, errorIndex, varBindTable = await nextCmd(
            engine,
            CommunityData(community),
            transport,
            ContextData(),
            current_oid,
        )
        if errorIndication or errorStatus or not varBindTable:
            break
            
        for varBind in varBindTable:
            oid_full = varBind[0].prettyPrint()
            val = varBind[1]
            results.append((oid_full, val))
            current_oid = ObjectType(varBind[0])
            
        # Check if we left the OID subtree (numeric OID check)
        last_oid = varBindTable[-1][0].prettyPrint()
        if all(c in '0123456789.' for c in last_oid):
            if not last_oid.startswith(oid_str + '.'):
                break
    
    return results

def mac_from_oid_suffix(oid_str):
    """Extract MAC address from the last 6 decimal octets of an OID."""
    parts = oid_str.split('.')
    if len(parts) >= 6:
        mac_parts = parts[-6:]
        try:
            return ':'.join(f'{int(p):02X}' for p in mac_parts)
        except ValueError:
            pass
    return oid_str

async def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Falta la IP del Switch"}))
        sys.exit(1)
        
    ip = sys.argv[1]
    community = sys.argv[2] if len(sys.argv) > 2 else "public"
    
    engine = SnmpEngine()
    transport = UdpTransportTarget((ip, 161), timeout=3, retries=1)
    
    # Test basic SNMP connectivity first
    try:
        errorIndication, errorStatus, errorIndex, varBinds = await getCmd(
            engine, CommunityData(community), transport, ContextData(),
            ObjectType(ObjectIdentity('1.3.6.1.2.1.1.1.0')),  # sysDescr
        )
        if errorIndication:
            print(json.dumps({"error": f"No se pudo conectar por SNMP: {errorIndication}"}))
            engine.closeDispatcher()
            sys.exit(0)
        if errorStatus:
            print(json.dumps({"error": f"Error SNMP: {errorStatus.prettyPrint()}"}))
            engine.closeDispatcher()
            sys.exit(0)
        
        sys_descr = varBinds[0][1].prettyPrint() if varBinds else ""
    except Exception as e:
        print(json.dumps({"error": f"Error de conexion SNMP: {str(e)}"}))
        sys.exit(0)
    
    # 1. Interface Descriptions (ifDescr)
    descs = await walk_oid(engine, transport, community, '1.3.6.1.2.1.2.2.1.2')
    if_desc_map = {}
    for oid, val in descs:
        idx = oid.split('.')[-1]
        if_desc_map[idx] = val.prettyPrint()
    
    # 2. Interface oper status (ifOperStatus)
    statuses = await walk_oid(engine, transport, community, '1.3.6.1.2.1.2.2.1.8')
    if_status_map = {}
    for oid, val in statuses:
        idx = oid.split('.')[-1]
        if_status_map[idx] = int(val)
    
    # 3. Interface speed (ifSpeed)
    speeds = await walk_oid(engine, transport, community, '1.3.6.1.2.1.2.2.1.5')
    if_speed_map = {}
    for oid, val in speeds:
        idx = oid.split('.')[-1]
        if_speed_map[idx] = int(val)
    
    # Build ports list (physical ports only)
    ports = []
    for idx in sorted(if_desc_map.keys(), key=lambda x: int(x)):
        descr = if_desc_map[idx]
        dl = descr.lower()
        if "gigabitethernet" in dl or "sfp" in dl or "ten-gigabitethernet" in dl:
            status = if_status_map.get(idx, 2)
            speed = if_speed_map.get(idx, 0)
            
            port_id = descr
            if "1/0/" in descr:
                port_id = descr.split("1/0/")[-1]
            
            port_type = "sfp" if "sfp" in dl else "rj45"
            
            ports.append({
                "ifIndex": idx,
                "name": descr,
                "portId": port_id,
                "type": port_type,
                "status": "up" if status == 1 else "down",
                "speed": f"{int(speed / 1000000)}M" if speed > 0 else "—"
            })
    
    def get_port_sort_key(p):
        try:
            return int(p["portId"])
        except ValueError:
            return 999
    ports.sort(key=get_port_sort_key)
    
    # 4. dot1dBasePortIfIndex (bridge port -> ifIndex mapping)
    base_ports = await walk_oid(engine, transport, community, '1.3.6.1.2.1.17.1.4.1.2')
    bp_to_if = {}
    for oid, val in base_ports:
        bp = oid.split('.')[-1]
        bp_to_if[bp] = str(int(val))
    
    # 5. FDB: MAC -> Bridge Port (standard bridge MIB)
    fdb_entries = []
    fdb = await walk_oid(engine, transport, community, '1.3.6.1.2.1.17.4.3.1.2')
    for oid, val in fdb:
        mac = mac_from_oid_suffix(oid)
        bridge_port = str(int(val))
        if_index = bp_to_if.get(bridge_port, bridge_port)
        if_name = if_desc_map.get(if_index, '')
        fdb_entries.append({
            "mac": mac,
            "ifIndex": if_index,
            "ifName": if_name,
            "bridgePort": bridge_port
        })
    
    # 6. Q-BRIDGE FDB (VLAN-aware, used by TP-Link managed switches)
    qfdb = await walk_oid(engine, transport, community, '1.3.6.1.2.1.17.7.1.2.2.1.2')
    for oid, val in qfdb:
        mac = mac_from_oid_suffix(oid)
        port = str(int(val))
        if_index = bp_to_if.get(port, port)
        if_name = if_desc_map.get(if_index, '')
        fdb_entries.append({
            "mac": mac,
            "ifIndex": if_index,
            "ifName": if_name,
            "bridgePort": port
        })
    
    # Deduplicate FDB entries by MAC
    seen_macs = set()
    unique_fdb = []
    for entry in fdb_entries:
        if entry["mac"] not in seen_macs:
            seen_macs.add(entry["mac"])
            unique_fdb.append(entry)
    
    engine.closeDispatcher()
    
    result = {
        "success": True,
        "sysDescr": sys_descr,
        "ports": ports,
        "fdb": unique_fdb
    }
    print(json.dumps(result))

if __name__ == "__main__":
    asyncio.run(main())
