-- Project digest: every user-visible fact about the open project, as REAPER
-- reports it. tour.py runs this through reaper() before and after each
-- operation and diffs the two, so an operation that changes the wrong track,
-- or anything besides what it should, is caught. Keys are stable (GUIDs, not
-- indices) so an insert or delete shows up as exactly that.
local D = {}

local function r6(x) return math.floor(x * 1e6 + 0.5) / 1e6 end

local function guid_of_track(tr)
  if tr == reaper.GetMasterTrack(0) then return "master" end
  return reaper.GetTrackGUID(tr)
end

local function str_hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%d:%08x", #s, h)
end

local function fx_list(tr, rec)
  local out = {}
  local count = rec and reaper.TrackFX_GetRecCount(tr) or reaper.TrackFX_GetCount(tr)
  for i = 0, count - 1 do
    local idx = rec and (0x1000000 + i) or i
    local _, name = reaper.TrackFX_GetFXName(tr, idx, "")
    local _, preset = reaper.TrackFX_GetPreset(tr, idx, "")
    local pidx, pcount = reaper.TrackFX_GetPresetIndex(tr, idx)
    local np = reaper.TrackFX_GetNumParams(tr, idx)
    local params = {}
    for p = 0, math.min(np, 6) - 1 do params[#params + 1] = r6(reaper.TrackFX_GetParamNormalized(tr, idx, p)) end
    out[reaper.TrackFX_GetFXGUID(tr, idx)] = {
      pos = i, name = name, enabled = reaper.TrackFX_GetEnabled(tr, idx),
      offline = reaper.TrackFX_GetOffline(tr, idx), preset = preset, preset_idx = pidx,
      preset_count = pcount, nparams = np, params = params,
    }
  end
  return out
end

local function routes(tr, cat)
  local out = {}
  for i = 0, reaper.GetTrackNumSends(tr, cat) - 1 do
    local e = {
      vol = r6(reaper.GetTrackSendInfo_Value(tr, cat, i, "D_VOL")),
      pan = r6(reaper.GetTrackSendInfo_Value(tr, cat, i, "D_PAN")),
      mute = reaper.GetTrackSendInfo_Value(tr, cat, i, "B_MUTE"),
      mode = reaper.GetTrackSendInfo_Value(tr, cat, i, "I_SENDMODE"),
      dstchan = reaper.GetTrackSendInfo_Value(tr, cat, i, "I_DSTCHAN"),
      srcchan = reaper.GetTrackSendInfo_Value(tr, cat, i, "I_SRCCHAN"),
    }
    if cat == 0 then e.dest = guid_of_track(reaper.GetTrackSendInfo_Value(tr, cat, i, "P_DESTTRACK")) end
    if cat == -1 then e.src = guid_of_track(reaper.GetTrackSendInfo_Value(tr, cat, i, "P_SRCTRACK")) end
    out[#out + 1] = e
  end
  return out
end

local function track_digest(tr, pos)
  local t = {
    pos = pos,
    name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)),
    vol = r6(reaper.GetMediaTrackInfo_Value(tr, "D_VOL")),
    pan = r6(reaper.GetMediaTrackInfo_Value(tr, "D_PAN")),
    mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
    solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"),
    arm = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM"),
    mon = reaper.GetMediaTrackInfo_Value(tr, "I_RECMON"),
    input = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"),
    fxen = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN"),
    sel = reaper.GetMediaTrackInfo_Value(tr, "I_SELECTED"),
    color = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"),
    depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"),
    freemode = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE"),
    nlanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES"),
    nchan = reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN"),
    mainsend = reaper.GetMediaTrackInfo_Value(tr, "B_MAINSEND"),
    razor = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_RAZOREDITS", "", false)),
    fx = fx_list(tr, false),
    infx = fx_list(tr, true),
    sends = routes(tr, 0),
    recvs = routes(tr, -1),
    hw = routes(tr, 1),
    envs = {},
    lanes = {},
  }
  for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do
    local env = reaper.GetTrackEnvelope(tr, e)
    local _, name = reaper.GetEnvelopeName(env)
    t.envs[name] = reaper.CountEnvelopePoints(env)
  end
  for l = 0, t.nlanes - 1 do
    t.lanes[#t.lanes + 1] = {
      plays = reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l),
      name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "", false)),
    }
  end
  if t.freemode == 2 then
    -- The comp target lane (which lane a new comp area lands in) is only in
    -- the state chunk's LANEREC line.
    local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
    t.lanerec = chunk:match("\nLANEREC ([^\r\n]*)") or ""
  end
  return t
end

local function item_digest(it, track_guid, idx)
  local takes = {}
  local active = reaper.GetActiveTake(it)
  local active_idx = -1
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk == active then active_idx = k end
    local src = tk and reaper.GetMediaItemTake_Source(tk)
    takes[#takes + 1] = tk and {
      guid = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false)),
      name = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)),
      color = reaper.GetMediaItemTakeInfo_Value(tk, "I_CUSTOMCOLOR"),
      offs = r6(reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")),
      rate = r6(reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE")),
      midi = reaper.TakeIsMIDI(tk),
      src = src and reaper.GetMediaSourceType(src, "") or "",
      -- Which recording the take plays (comp areas differ only in this).
      file = src and (reaper.GetMediaSourceFileName(src) or ""):match("[^/\\]*$") or "",
      fx = reaper.TakeFX_GetCount(tk),
    } or {empty = true}
  end
  return {
    track = track_guid, idx = idx,
    pos = r6(reaper.GetMediaItemInfo_Value(it, "D_POSITION")),
    len = r6(reaper.GetMediaItemInfo_Value(it, "D_LENGTH")),
    color = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR"),
    lock = reaper.GetMediaItemInfo_Value(it, "C_LOCK"),
    sel = reaper.GetMediaItemInfo_Value(it, "B_UISEL"),
    mute = reaper.GetMediaItemInfo_Value(it, "B_MUTE"),
    lane = reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"),
    notes = str_hash(select(2, reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "", false))),
    active = active_idx,
    takes = takes,
  }
end

function D.digest()
  local d = {tracks = {}, items = {}, markers = {}, tempo = {}}
  local master = reaper.GetMasterTrack(0)
  d.tracks.master = track_digest(master, 0)
  d.tracks.master.mono = reaper.GetToggleCommandState(40917)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local g = reaper.GetTrackGUID(tr)
    d.tracks[g] = track_digest(tr, i + 1)
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, j)
      local ig = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))
      d.items[ig] = item_digest(it, g, j)
    end
  end
  local i = 0
  while true do
    local ok, isrgn, pos, rend, name, id, color = reaper.EnumProjectMarkers3(0, i)
    if ok == 0 then break end
    -- A region's render-matrix routing: the tracks (or master) it renders.
    local render = nil
    if isrgn then
      render = {}
      local k = 0
      while true do
        local tr = reaper.EnumRegionRenderMatrix(0, id, k)
        if not tr then break end
        render[#render + 1] = guid_of_track(tr)
        k = k + 1
      end
    end
    d.markers[(isrgn and "R" or "M") .. id] = {
      pos = r6(pos), ["end"] = isrgn and r6(rend) or nil, name = name, color = color,
      bars = reaper.format_timestr_pos(pos, "", 2),
      end_bars = isrgn and reaper.format_timestr_pos(rend, "", 2) or nil,
      guid = select(2, reaper.GetSetProjectInfo_String(0, "MARKER_GUID:" .. i, "", false)),
      render = render,
    }
    i = i + 1
  end
  for k = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
    local _, tpos, _, _, bpm, num, den, linear = reaper.GetTempoTimeSigMarker(0, k)
    d.tempo[#d.tempo + 1] = {pos = r6(tpos), bpm = r6(bpm), num = num, den = den, linear = linear}
  end
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  local loop_start, loop_end = reaper.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)
  -- The tempo and meter at the edit cursor, from the tempo map (what the
  -- transport bar shows). Master_GetTempo follows a moved cursor only on
  -- REAPER's next UI refresh, so it is not read here.
  local num, den, cursor_bpm = reaper.TimeMap_GetTimeSigAtTime(0, reaper.GetCursorPosition())
  d.project = {
    play = reaper.GetPlayState(),
    cursor = r6(reaper.GetCursorPosition()),
    timesel = {r6(ts_start), r6(ts_end)},
    -- "timesel" while the loop points equal the time selection (REAPER links
    -- them by default), so an op that sets one is not charged with both.
    loop = (r6(loop_start) == r6(ts_start) and r6(loop_end) == r6(ts_end)) and "timesel"
      or {r6(loop_start), r6(loop_end)},
    ["repeat"] = reaper.GetSetRepeat(-1),
    metronome = reaper.GetToggleCommandState(40364),
    metro_vol = select(2, reaper.get_config_var_string("projmetrov1")),
    metro_flags = select(2, reaper.get_config_var_string("projmetroen")),
    bpm = r6(cursor_bpm),
    timesig = {num, den},
    start_measure = select(2, reaper.get_config_var_string("projmeasoffs")),
    notes = str_hash(reaper.GetSetProjectNotes(0, false, "")),
    reamo = {},
    seek = {
      select(2, reaper.get_config_var_string("smoothseek")),
      select(2, reaper.get_config_var_string("smoothseekmeas")),
    },
  }
  -- REAmo's own project state (custom banks, playlists), every key.
  local k = 0
  while true do
    local ok, key, val = reaper.EnumProjExtState(0, "Reamo", k)
    if not ok then break end
    -- Playlists are short and the tour decodes them (tour_mirror.py); other
    -- values (custom banks, up to 16 KB) are compared by hash.
    -- EnumProjExtState cuts values at 4095 bytes; GetProjExtState does not.
    val = select(2, reaper.GetProjExtState(0, "Reamo", key))
    -- REAPER reports ExtState keys in upper case.
    local raw = key == "PLAYLISTCOUNT" or key:match("^PLAYLIST_%d+$")
    d.project.reamo[key] = raw and val or str_hash(val)
    k = k + 1
  end
  -- Volatile: changes with any edit; the tour checks them separately.
  d.undo = {can_undo = reaper.Undo_CanUndo2(0) or "", can_redo = reaper.Undo_CanRedo2(0) or "",
            dirty = reaper.IsProjectDirty(0)}
  return d
end

return D
