/**
 * PCM Playback AudioWorklet Processor
 *
 * Receives interleaved 16-bit stereo PCM frames from the main thread via MessagePort,
 * converts to float32, buffers in a ring, and outputs 128-sample render quanta.
 *
 * Frame format (from server):
 *   [0..3]  u32 LE: sequence number
 *   [4..]   i16 LE: interleaved stereo PCM (L,R,L,R,...)
 */
class PCMPlaybackProcessor extends AudioWorkletProcessor {
  constructor() {
    super();

    // Ring buffer: ~500ms at 48kHz = 24000 stereo pairs per channel
    this.bufferSize = 24000;
    this.leftBuffer = new Float32Array(this.bufferSize);
    this.rightBuffer = new Float32Array(this.bufferSize);
    this.writePos = 0;
    this.readPos = 0;
    this.buffered = 0;

    // Diagnostics
    this.underflowCount = 0;
    this.overflowCount = 0;
    this.framesReceived = 0;

    // Buffering state: accumulate ~100ms before starting playback
    // This absorbs WiFi jitter without adding excessive latency
    this.targetLevel = 4800; // ~100ms at 48kHz
    this.state = 'buffering'; // 'buffering' | 'playing'

    this.port.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        this.handleFrame(event.data);
      } else if (event.data === 'getStats') {
        this.port.postMessage({
          type: 'stats',
          buffered: this.buffered,
          bufferSize: this.bufferSize,
          underflows: this.underflowCount,
          overflows: this.overflowCount,
          framesReceived: this.framesReceived,
          state: this.state,
        });
      } else if (event.data === 'reset') {
        this.writePos = 0;
        this.readPos = 0;
        this.buffered = 0;
        this.state = 'buffering';
        this.underflowCount = 0;
        this.overflowCount = 0;
        this.framesReceived = 0;
      }
    };
  }

  handleFrame(buffer) {
    // Header: 4 bytes (u32 sequence, skip for now)
    const HEADER_SIZE = 4;
    if (buffer.byteLength <= HEADER_SIZE) return;

    const view = new DataView(buffer);
    // const sequence = view.getUint32(0, true); // For future gap detection
    const pcmBytes = buffer.byteLength - HEADER_SIZE;
    const numSamples = pcmBytes / 4; // 2 channels * 2 bytes per sample

    this.framesReceived++;

    for (let i = 0; i < numSamples; i++) {
      const offset = HEADER_SIZE + i * 4;
      const leftSample = view.getInt16(offset, true) / 32768.0;
      const rightSample = view.getInt16(offset + 2, true) / 32768.0;

      if (this.buffered >= this.bufferSize) {
        // Overflow: drop oldest by advancing read position
        this.readPos = (this.readPos + 1) % this.bufferSize;
        this.buffered--;
        this.overflowCount++;
      }

      this.leftBuffer[this.writePos] = leftSample;
      this.rightBuffer[this.writePos] = rightSample;
      this.writePos = (this.writePos + 1) % this.bufferSize;
      this.buffered++;
    }

    // Transition from buffering to playing when we hit target level
    if (this.state === 'buffering' && this.buffered >= this.targetLevel) {
      this.state = 'playing';
    }
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;

    const left = output[0];
    const right = output.length > 1 ? output[1] : null;
    const frames = left.length; // 128

    if (this.state !== 'playing' || this.buffered < frames) {
      // Output silence during buffering or underflow
      if (this.state === 'playing' && this.buffered < frames) {
        this.underflowCount++;
        if (this.buffered === 0) {
          this.state = 'buffering';
        }
      }
      left.fill(0);
      if (right) right.fill(0);
      return true;
    }

    // Read from ring buffer
    for (let i = 0; i < frames; i++) {
      left[i] = this.leftBuffer[this.readPos];
      if (right) right[i] = this.rightBuffer[this.readPos];
      this.readPos = (this.readPos + 1) % this.bufferSize;
    }
    this.buffered -= frames;

    return true; // Keep processor alive
  }
}

registerProcessor('pcm-playback-processor', PCMPlaybackProcessor);
