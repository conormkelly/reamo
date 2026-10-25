"""Custom mixer banks saved from the phone load back on the next visit.

useCustomBanks saves JSON.stringify(banks) with extstate/projSet and later
JSON.parses what extstate/projGet returns; a parse failure silently resets
the banks to []. So the value read back must be the exact string written,
and REAPER must hold that same string (it is what lands in the .rpp).
"""
import json

from reamo_client import Client, reaper

banks = [{"id": "b1", "name": "Drums \"kit\"", "trackGuids": ["{AB-1}", "{CD-2}"]},
         {"id": "b2", "name": "Vox / Gäste", "trackGuids": []}]
value = json.dumps(banks, separators=(",", ":"), ensure_ascii=False)  # JSON.stringify

with Client() as c:
    r = c.command("extstate/projSet", extname="Reamo", key="CustomBanks", value=value)
    assert r["success"], r
    in_reaper = reaper('local _, v = reaper.GetProjExtState(0, "Reamo", "CustomBanks"); return v')
    r = c.command("extstate/projGet", extname="Reamo", key="CustomBanks")
    assert r["success"], r
    back = r["payload"]["value"]
    print("sent  :", value)
    print("REAPER:", in_reaper)
    print("read  :", back)
    problems = []
    if in_reaper != value:
        problems.append("REAPER stores a different string than the client sent")
    if back != value:
        problems.append("projGet returns a different string than projSet stored")
    try:
        assert json.loads(back) == banks
    except Exception as e:
        problems.append(f"JSON.parse of the value read back fails ({e}): the UI would reset the banks to []")
    assert not problems, "\n".join(problems)
