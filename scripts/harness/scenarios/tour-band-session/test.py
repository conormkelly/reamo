"""Every protocol operation against a typical band session (see corpus/band-session.lua)."""
import os

from tour import main

main("/tmp/corpus/band-session/band-session.RPP", "band-session", only=os.environ.get("TOUR_ONLY", "").split() or None)
