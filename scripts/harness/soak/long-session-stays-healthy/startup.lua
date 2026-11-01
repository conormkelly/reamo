-- Builds corpus/band-session.lua (tracks with FX, audio and MIDI items,
-- markers, regions, sends) and leaves an empty project tab open; the soak
-- opens the session as a user would, then plays it on repeat.
dofile("/harness/corpus/band-session.lua")
harness.ready()
