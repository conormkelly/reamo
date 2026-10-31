/**
 * Mix Monitoring audio frame decoder (binary WebSocket message type 0x01).
 *
 * Wire format (extension/src/audio/stream.zig):
 *   [0]     u8      message type (0x01)
 *   [1..4]  u32 LE  sequence number
 *   [5..]   i16 LE  interleaved stereo PCM (L,R,L,R,...)
 *
 * Both playback paths (AudioWorklet and AudioBufferSourceNode scheduling)
 * consume this decoder's output, so the wire format is parsed in one place.
 */

/** Type byte + u32 sequence number */
const AUDIO_FRAME_HEADER_SIZE = 5;

/** One stereo pair: two i16 samples */
const BYTES_PER_PAIR = 4;

export interface DecodedAudioFrame {
  left: Float32Array<ArrayBuffer>;
  right: Float32Array<ArrayBuffer>;
}

/** Decode a frame's PCM payload to float samples in [-1, 1). Returns null if it holds no samples. */
export function decodeAudioFrame(data: ArrayBuffer): DecodedAudioFrame | null {
  const pairCount = Math.floor((data.byteLength - AUDIO_FRAME_HEADER_SIZE) / BYTES_PER_PAIR);
  if (pairCount <= 0) return null;

  const view = new DataView(data);
  const left = new Float32Array(pairCount);
  const right = new Float32Array(pairCount);
  for (let i = 0; i < pairCount; i++) {
    const offset = AUDIO_FRAME_HEADER_SIZE + i * BYTES_PER_PAIR;
    left[i] = view.getInt16(offset, true) / 32768;
    right[i] = view.getInt16(offset + 2, true) / 32768;
  }
  return { left, right };
}
