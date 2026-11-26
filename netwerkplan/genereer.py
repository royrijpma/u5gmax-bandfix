#!/usr/bin/env python3
"""Maakt een netwerkplan in de Apple Notes-opzet.
Gebruik: python3 genereer.py event.json > plan.txt
Poortgegevens komen uit poorten.json; lijnen verwijzen met 'uitlaat' (id) en optioneel 'poort' (index)."""
import json, sys, os
hier = os.path.dirname(os.path.abspath(__file__))
uitlaten = {}
for zaal, lst in json.load(open(os.path.join(hier, "poorten.json"))).items():
    for u in lst: uitlaten[u["id"]] = (zaal, u)
ev = json.load(open(sys.argv[1]))
POOLS = json.load(open(os.path.join(hier, "vlans.json")))
TOEGESTAAN = {v for pl in POOLS.values() for v in pl["vlans"]}
gebruikt = set()
def vlan_voor(waarde, pool):
    """'auto' = eerste vrije VLAN uit de pool; een getal wordt gecontroleerd tegen de toegestane lijst."""
    if waarde in (None, "...", ""): return "…"
    if waarde == "auto":
        if POOLS[pool].get("gedeeld"):
            gebruikt.add(POOLS[pool]["vlans"][0]); return POOLS[pool]["vlans"][0]
        for v in POOLS[pool]["vlans"]:
            if v not in gebruikt:
                gebruikt.add(v); return v
        sys.exit(f"Geen vrije VLAN meer in pool '{pool}'")
    gebruikt.add(waarde)
    if waarde not in TOEGESTAAN: print(f"WAARSCHUWING: VLAN {waarde} staat niet in vlans.json", file=sys.stderr)
    return waarde
LEASE = "1 Day / 1 Week (3 dagen of meer)"
o = []; p = o.append
def lijn(l):
    zaal, u = uitlaten[l["uitlaat"]]
    poorten = u["poorten"]
    poort = poorten[l["poort"]] if "poort" in l else " | ".join(poorten)
    p(f'{l["titel"]}\n')
    p(f'* [{poort}] - 🟢')
    p(f'* VLAN: {vlan_voor(l.get("vlan"), l.get("pool", "vaste_lijn"))} - Untagged')
    p(f'* DHCP Lease: {LEASE}')
    p('* Access Port: Auto-100, RSTP, BPDU Guard')
    p(f'* WAN: {l.get("wan","…")}')
    p(f'* Label: {l.get("label","…")}')
    p(f'* Kabel: {l.get("kabel","…")}')
    if u["notitie"]: p(f'* Locatie: {zaal} - {u["notitie"]} ({u["id"]})')
    p('')
p(f'Event - ⚫️ {ev["naam"]}\n')
p(f'Datum: {ev["datum"]}\nReferentienummer: {ev["referentie"]}\nPAX: {ev["pax"]}')
p(f'Main contact:\nIT-lead: {ev["it_lead"]}\nOpbouw: {ev["opbouw"]}\nAfbouw: {ev["afbouw"]}\n')
p('Administratie\n\n* Offerte\n\n* Factuur\n\n\n⸻\n')
p('1. Afspraak\n')
for a in ev["afspraken"]: p(f'* {a}')
p('\n\nBijzonderheden:\n\n* …\n\n\nRecente bespreking:\n\n* …\n\n\n⸻\n')
p('2. Planning:')
for dag, (titel, nt) in ev["planning"].items():
    p(f'{dag}: {titel}\n\n* {nt or "…"}\n\n')
p('Bijzonderheden:\n\n* …\n\n\n⸻\n')
p('3. Inrichting:')
p(f'WAN 1: … \nWAN 2: … \n')
w = ev["wifi"]
p(f'WiFi\n\n* SSID: {w["ssid"]}\n* Password: {w["wachtwoord"]}\n* DHCP Guard 🟢 (Alleen voor WiFi’s)\n* DHCP Lease: {w["lease"]}\n* Dekking: {w["dekking"]}\n* VLAN: {vlan_voor(w["vlan"], "wifi")}\n* WAN: {ev["wan_wifi"]}\n* 🟢\n\n')
r = ev["registratie_wifi"]
p(f'Registratie:\nRegistratie WiFi:\n\n* SSID: {r["ssid"]}\n* Password: {r["wachtwoord"]}\n* DHCP Guard 🟢 (Alleen voor WiFi’s)\n* DHCP Lease: {LEASE}\n* Dekking: {r["dekking"]}\n* VLAN: {vlan_voor(r["vlan"], "registratie")}\n* WAN: {ev["wan_registratie"]}\n* 🟢\n\n')
p('Vaste lijnen')
zalen = []
for l in ev["lijnen"]:
    z = uitlaten[l["uitlaat"]][0]
    if z not in zalen: zalen.append(z)
for z in zalen:
    p(z)
    for l in ev["lijnen"]:
        if uitlaten[l["uitlaat"]][0] == z: lijn(l)
p('\n⸻\n\n4. Afbouw checklist\n')
for c in ev["afbouw_checklist"]: p(f'* {c} 🔴')
print("\n".join(o))
