/**
 * Audio Stream Manager
 *
 * Manages the audio monitoring lifecycle:
 * - Creates/destroys AudioContext + AudioWorkletNode (secure contexts)
 * - Falls back to AudioBufferSourceNode scheduling on insecure contexts (HTTP over LAN)
 * - Routes binary WebSocket frames to the audio pipeline
 * - Handles iOS AudioContext suspension
 * - Polls for stats (buffer health, underflows)
 */

export type AudioMonitorState = 'stopped' | 'buffering' | 'streaming' | 'error';

export interface AudioWorkletStats {
  buffered: number;
  bufferSize: number;
  underflows: number;
  overflows: number;
  framesReceived: number;
  state: 'buffering' | 'playing';
}

/** Jitter buffer target before starting playback (seconds) */
const BUFFER_TARGET_S = 0.08; // 80ms

export class AudioStreamManager {
  private audioContext: AudioContext | null = null;
  private workletNode: AudioWorkletNode | null = null;
  private state: AudioMonitorState = 'stopped';
  private onStateChange?: (state: AudioMonitorState) => void;
  private onStats?: (stats: AudioWorkletStats) => void;
  private statsInterval: ReturnType<typeof setInterval> | null = null;

  // AudioBufferSourceNode scheduling fallback (insecure contexts)
  private nextPlayTime = 0;
  private pendingBuffers: AudioBuffer[] = [];
  private fallbackBuffering = true;
  private serverSampleRate = 48000;
  private underflowCount = 0;
  private framesReceived = 0;

  constructor(
    onStateChange?: (state: AudioMonitorState) => void,
    onStats?: (stats: AudioWorkletStats) => void,
  ) {
    this.onStateChange = onStateChange;
    this.onStats = onStats;
  }

  /**
   * Unlock the audio session within a user gesture handler.
   * iOS Safari requires AudioContext.resume() to be called synchronously
   * in a user-initiated event handler. Call this BEFORE any async work.
   */
  unlockAudio(): void {
    if (this.audioContext) return;
    // Create at device default rate — will be replaced in start() if needed
    this.audioContext = new AudioContext();
    this.audioContext.resume().catch(() => {});
  }

  /** Start the audio playback pipeline */
  async start(sampleRate: number): Promise<void> {
    try {
      this.serverSampleRate = sampleRate;

      // Replace context if sample rate doesn't match (unlockAudio may have created at device rate)
      if (this.audioContext && this.audioContext.sampleRate !== sampleRate) {
        this.audioContext.close().catch(() => {});
        this.audioContext = null;
      }

      if (!this.audioContext) {
        this.audioContext = new AudioContext({ sampleRate });
      }

      // Ensure resumed (may already be from unlockAudio)
      if (this.audioContext.state === 'suspended') {
        await this.audioContext.resume();
      }

      if (this.audioContext.audioWorklet) {
        // Secure context: AudioWorklet (off-main-thread, zero-copy transfer)
        await this.startWithWorklet();
      } else {
        // Insecure context (HTTP over LAN): AudioBufferSourceNode scheduling
        this.startWithBufferScheduling();
      }

      this.setState('buffering');

      console.log(`[Audio] Started (server: ${sampleRate}Hz, context: ${this.audioContext.sampleRate}Hz, worklet: ${!!this.workletNode})`);
    } catch (error) {
      console.error('[Audio] Failed to start:', error);
      this.setState('error');
      this.stop();
    }
  }

  /** Stop audio playback and clean up all resources */
  stop(): void {
    if (this.statsInterval) {
      clearInterval(this.statsInterval);
      this.statsInterval = null;
    }
    if (this.workletNode) {
      this.workletNode.port.postMessage('reset');
      this.workletNode.disconnect();
      this.workletNode = null;
    }
    // Reset scheduling fallback state
    this.nextPlayTime = 0;
    this.pendingBuffers = [];
    this.fallbackBuffering = true;
    this.underflowCount = 0;
    this.framesReceived = 0;
    if (this.audioContext) {
      this.audioContext.close().catch(() => {});
      this.audioContext = null;
    }
    if (this.state !== 'stopped') {
      this.setState('stopped');
    }
  }

  /** Route a binary WebSocket frame to the audio pipeline */
  handleAudioFrame(data: ArrayBuffer): void {
    if (this.workletNode) {
      // AudioWorklet path: transfer ownership for zero-copy
      this.workletNode.port.postMessage(data, [data]);
      return;
    }

    if (this.audioContext) {
      // Buffer scheduling path: parse PCM and schedule playback
      this.scheduleAudioBuffer(data);
    }
  }

  /** Current state */
  get currentState(): AudioMonitorState {
    return this.state;
  }

  /** Whether the audio pipeline is active (not stopped or error) */
  get isActive(): boolean {
    return this.state === 'buffering' || this.state === 'streaming';
  }

  // ==========================================================================
  // AudioWorklet path (secure contexts)
  // ==========================================================================

  private async startWithWorklet(): Promise<void> {
    if (!this.audioContext) return;

    await this.audioContext.audioWorklet.addModule('/audio-worklet-processor.js');

    this.workletNode = new AudioWorkletNode(
      this.audioContext,
      'pcm-playback-processor',
      { outputChannelCount: [2] },
    );
    this.workletNode.connect(this.audioContext.destination);

    // Listen for stats from worklet
    this.workletNode.port.onmessage = (event: MessageEvent) => {
      const data = event.data;
      if (data?.type === 'stats') {
        this.onStats?.(data as AudioWorkletStats);
        const newState: AudioMonitorState =
          data.state === 'buffering' ? 'buffering' : 'streaming';
        if (newState !== this.state) {
          this.setState(newState);
        }
      }
    };

    // Poll stats every 500ms for UI updates
    this.statsInterval = setInterval(() => {
      this.workletNode?.port.postMessage('getStats');
    }, 500);
  }

  // ==========================================================================
  // AudioBufferSourceNode scheduling fallback (insecure contexts)
  //
  // Uses AudioContext.currentTime for sample-accurate scheduling.
  // Each incoming PCM chunk becomes an AudioBuffer scheduled at nextPlayTime.
  // Jitter buffer absorbs network timing variance before starting playback.
  // ==========================================================================

  private startWithBufferScheduling(): void {
    this.nextPlayTime = 0;
    this.pendingBuffers = [];
    this.fallbackBuffering = true;
    this.underflowCount = 0;
    this.framesReceived = 0;

    // Stats polling for UI
    this.statsInterval = setInterval(() => {
      if (!this.audioContext) return;
      const ahead = Math.max(0, this.nextPlayTime - this.audioContext.currentTime);
      const aheadSamples = Math.round(ahead * this.serverSampleRate);
      this.onStats?.({
        buffered: aheadSamples,
        bufferSize: Math.round(BUFFER_TARGET_S * this.serverSampleRate),
        underflows: this.underflowCount,
        overflows: 0,
        framesReceived: this.framesReceived,
        state: this.fallbackBuffering ? 'buffering' : 'playing',
      });
      // Sync external state
      const newState: AudioMonitorState = this.fallbackBuffering ? 'buffering' : 'streaming';
      if (newState !== this.state) {
        this.setState(newState);
      }
    }, 500);
  }

  /**
   * Parse binary frame and schedule for playback.
   * Frame format: [4-byte u32 LE sequence][interleaved i16 LE stereo PCM]
   *
   * Creates an AudioBuffer at the server's sample rate. If the AudioContext
   * runs at a different rate (e.g. iOS forcing 48kHz when REAPER is at 44.1kHz),
   * the browser resamples automatically during playback.
   */
  private scheduleAudioBuffer(data: ArrayBuffer): void {
    const ctx = this.audioContext!;
    this.framesReceived++;

    // Parse PCM: skip 4-byte header, read interleaved i16 stereo
    const pairCount = (data.byteLength - 4) / 4; // 4 bytes per stereo pair (2 * i16)
    if (pairCount <= 0) return;

    const view = new DataView(data);

    const audioBuffer = ctx.createBuffer(2, pairCount, this.serverSampleRate);
    const left = audioBuffer.getChannelData(0);
    const right = audioBuffer.getChannelData(1);

    for (let i = 0; i < pairCount; i++) {
      const offset = 4 + i * 4;
      left[i] = view.getInt16(offset, true) / 32768.0;
      right[i] = view.getInt16(offset + 2, true) / 32768.0;
    }

    // Buffering phase: accumulate jitter buffer before starting playback
    if (this.fallbackBuffering) {
      this.pendingBuffers.push(audioBuffer);
      let bufferedDuration = 0;
      for (const buf of this.pendingBuffers) {
        bufferedDuration += buf.duration;
      }
      if (bufferedDuration >= BUFFER_TARGET_S) {
        // Schedule all buffered data starting 10ms from now
        this.nextPlayTime = ctx.currentTime + 0.01;
        for (const buf of this.pendingBuffers) {
          this.scheduleSource(buf);
        }
        this.pendingBuffers = [];
        this.fallbackBuffering = false;
        this.setState('streaming');
      }
      return;
    }

    // Underrun: scheduled time has fallen behind the audio clock
    if (this.nextPlayTime < ctx.currentTime) {
      this.underflowCount++;
      this.fallbackBuffering = true;
      this.pendingBuffers = [audioBuffer];
      this.setState('buffering');
      return;
    }

    this.scheduleSource(audioBuffer);
  }

  /** Schedule a single AudioBuffer for playback at nextPlayTime */
  private scheduleSource(buffer: AudioBuffer): void {
    const source = this.audioContext!.createBufferSource();
    source.buffer = buffer;
    source.connect(this.audioContext!.destination);
    source.start(this.nextPlayTime);
    this.nextPlayTime += buffer.duration;
  }

  private setState(state: AudioMonitorState): void {
    this.state = state;
    this.onStateChange?.(state);
  }
}
