/**
 * Binary peaks tile decoder.
 *
 * Decodes the binary tile batch format sent by the Zig server into
 * PeaksTile objects matching the existing JSON interface. This allows
 * the rest of the pipeline (peaksSlice, TileBitmapCache, WaveformCanvas)
 * to work unchanged.
 *
 * Binary format (see extension/src/core/binary_protocol.zig):
 *
 * Batch envelope (4 bytes):
 *   u8   message_type = 0x02
 *   u8   reserved
 *   u16  tile_count (LE)
 *
 * Per-tile:
 *   Header (20 bytes):
 *     u8   lod_level
 *     u8   channels (1 or 2)
 *     u16  tile_index (LE)
 *     u16  num_peaks (LE)
 *     u16  reserved
 *     u32  epoch (LE)
 *     f32  start_time (LE)
 *     f32  item_position (LE)
 *
 *   GUID (40 bytes): null-padded ASCII
 *
 *   Peak data (num_peaks * channels * 2 bytes):
 *     Per peak per channel: i8 min, i8 max
 *     Stereo: [L_min, L_max, R_min, R_max] per peak
 *     Mono: [min, max] per peak
 */

import type {
  PeaksTile,
  StereoPeak,
  MonoPeak,
  LODLevel,
} from './WebSocketTypes';
import { LOD_CONFIGS } from './WebSocketTypes';

const BATCH_ENVELOPE_SIZE = 4;
const TILE_HEADER_SIZE = 20;
const GUID_SIZE = 40;

/**
 * Decode a binary peaks batch into PeaksTile array.
 * The input buffer includes the 1-byte type prefix (0x02) at position 0
 * which was already used for routing — we skip it here.
 */
export function decodePeaksBatch(buffer: ArrayBuffer): PeaksTile[] {
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);

  if (buffer.byteLength < BATCH_ENVELOPE_SIZE) return [];

  // Envelope: skip byte 0 (message_type, already checked by router)
  const tileCount = view.getUint16(2, true);
  if (tileCount === 0) return [];

  const tiles: PeaksTile[] = new Array(tileCount);
  let offset = BATCH_ENVELOPE_SIZE;
  let decoded = 0;

  for (let i = 0; i < tileCount; i++) {
    if (offset + TILE_HEADER_SIZE + GUID_SIZE > buffer.byteLength) break;

    // Parse 20-byte tile header
    const lodLevel = view.getUint8(offset) as LODLevel;
    const channels = view.getUint8(offset + 1) as 1 | 2;
    const tileIndex = view.getUint16(offset + 2, true);
    const numPeaks = view.getUint16(offset + 4, true);
    // offset + 6: reserved u16
    const epoch = view.getUint32(offset + 8, true);
    const startTime = view.getFloat32(offset + 12, true);
    const itemPosition = view.getFloat32(offset + 16, true);
    offset += TILE_HEADER_SIZE;

    // Parse 40-byte GUID (null-terminated ASCII)
    let guidEnd = offset;
    while (guidEnd < offset + GUID_SIZE && bytes[guidEnd] !== 0) {
      guidEnd++;
    }
    const takeGuid = String.fromCharCode(...bytes.slice(offset, guidEnd));
    offset += GUID_SIZE;

    // Parse peak data
    const peakDataSize = numPeaks * channels * 2;
    if (offset + peakDataSize > buffer.byteLength) break;

    const peakBytes = new Int8Array(buffer, offset, peakDataSize);
    let peaks: StereoPeak[] | MonoPeak[];

    if (channels === 2) {
      const stereoPeaks: StereoPeak[] = new Array(numPeaks);
      for (let p = 0; p < numPeaks; p++) {
        const base = p * 4; // 4 bytes per stereo peak: L_min, L_max, R_min, R_max
        stereoPeaks[p] = {
          l: [peakBytes[base] / 127.0, peakBytes[base + 1] / 127.0],
          r: [peakBytes[base + 2] / 127.0, peakBytes[base + 3] / 127.0],
        };
      }
      peaks = stereoPeaks;
    } else {
      const monoPeaks: MonoPeak[] = new Array(numPeaks);
      for (let p = 0; p < numPeaks; p++) {
        const base = p * 2; // 2 bytes per mono peak: min, max
        monoPeaks[p] = [peakBytes[base] / 127.0, peakBytes[base + 1] / 127.0];
      }
      peaks = monoPeaks;
    }
    offset += peakDataSize;

    // Compute endTime from LOD config
    const lodConfig = LOD_CONFIGS[lodLevel];
    const endTime = startTime + (lodConfig?.duration ?? 1);

    tiles[decoded] = {
      takeGuid,
      epoch,
      lod: lodLevel,
      tileIndex,
      itemPosition,
      startTime,
      endTime,
      channels,
      peaks,
    };
    decoded++;
  }

  // Trim if we decoded fewer than expected
  return decoded < tileCount ? tiles.slice(0, decoded) : tiles;
}
