/**
 * PCM Playback AudioWorklet Processor
 *
 * Receives decoded stereo PCM from the main thread via MessagePort, buffers it
 * in a ring, and outputs 128-sample render quanta.
 *
 * Message: { type: 'pcm', left: Float32Array, right: Float32Array }
 * The main thread decodes the server's wire format (src/audio/audioFrame.ts).
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
      if (event.data?.type === 'pcm') {
        this.handleFrame(event.data.left, event.data.right);
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

  handleFrame(left, right) {
    this.framesReceived++;

    for (let i = 0; i < left.length; i++) {
      if (this.buffered >= this.bufferSize) {
        // Overflow: drop oldest by advancing read position
        this.readPos = (this.readPos + 1) % this.bufferSize;
        this.buffered--;
        this.overflowCount++;
      }

      this.leftBuffer[this.writePos] = left[i];
      this.rightBuffer[this.writePos] = right[i];
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
