-- Track names users type: quotes, a backslash, accents, and a long one.
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
harness.track('Lead "Strat" \\ DI')
harness.track("Guitare acoustique — prise 2 " .. string.rep("ü", 60))
harness.ready()
