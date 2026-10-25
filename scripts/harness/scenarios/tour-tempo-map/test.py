"""Every protocol operation against a tempo-mapped project with ramps and meter changes (see corpus/tempo-map.lua)."""
import os

from tour import main

main("/tmp/corpus/tempo-map/tempo-map.RPP", "tempo-map", only=os.environ.get("TOUR_ONLY", "").split() or None)
