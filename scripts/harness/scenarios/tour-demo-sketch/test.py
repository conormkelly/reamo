"""Every protocol operation against an evening's demo sketch (see corpus/demo-sketch.lua)."""
import os

from tour import main

main("/tmp/corpus/demo-sketch/demo-sketch.RPP", "demo-sketch", only=os.environ.get("TOUR_ONLY", "").split() or None)
