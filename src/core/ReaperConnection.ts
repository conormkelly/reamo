/**
 * REAPER Connection Client
 * TypeScript rewrite of REAPER's main.js polling system
 */

import { parseResponse } from './ResponseParser';
import type { ParsedResponse } from './types';

export interface ReaperConnectionOptions {
  /** Base URL for REAPER's HTTP server (default: '') */
  baseUrl?: string;
  /** Base timer frequency in ms (default: 100) */
  timerFrequency?: number;
  /** Request timeout in ms (default: 3000) */
  requestTimeout?: number;
  /** Callback when responses are received */
  onResponse?: (responses: ParsedResponse[]) => void;
  /** Callback when connection status changes */
  onConnectionChange?: (connected: boolean, errorCount: number) => void;
}

interface RecurringRequest {
  command: string;
  interval: number;
  nextTime: number;
}

/**
 * Manages HTTP polling communication with REAPER
 */
export class ReaperConnection {
  private baseUrl: string;
  private timerFrequency: number;
  private requestTimeout: number;
  private onResponse: (responses: ParsedResponse[]) => void;
  private onConnectionChange: (connected: boolean, errorCount: number) => void;

  private pendingCommands: string = '';
  private recurringRequests: RecurringRequest[] = [];
  private xhr: XMLHttpRequest | null = null;
  private mainTimer: ReturnType<typeof setTimeout> | null = null;
  private timeoutTimer: ReturnType<typeof setTimeout> | null = null;
  private errorCount: number = 0;
  private running: boolean = false;

  constructor(options: ReaperConnectionOptions = {}) {
    this.baseUrl = options.baseUrl ?? '';
    this.timerFrequency = options.timerFrequency ?? 100;
    this.requestTimeout = options.requestTimeout ?? 3000;
    this.onResponse = options.onResponse ?? (() => {});
    this.onConnectionChange = options.onConnectionChange ?? (() => {});
  }

  /**
   * Start the connection polling loop
   */
  start(): void {
    if (this.running) return;
    this.running = true;
    this.runUpdate();
  }

  /**
   * Stop the connection and clean up
   */
  stop(): void {
    this.running = false;

    if (this.mainTimer) {
      clearTimeout(this.mainTimer);
      this.mainTimer = null;
    }

    if (this.timeoutTimer) {
      clearTimeout(this.timeoutTimer);
      this.timeoutTimer = null;
    }

    if (this.xhr) {
      this.xhr.abort();
      this.xhr = null;
    }

    this.pendingCommands = '';
    this.recurringRequests = [];
    this.errorCount = 0;
  }

  /**
   * Send a one-time command (or multiple commands separated by semicolons)
   */
  send(command: string): void {
    this.pendingCommands += command + ';';
  }

  /**
   * Set up a recurring poll for a command
   * @param command - The command(s) to poll
   * @param intervalMs - Polling interval in milliseconds
   */
  poll(command: string, intervalMs: number): void {
    // Check if already polling this command
    const existing = this.recurringRequests.find((r) => r.command === command);
    if (existing) {
      existing.interval = intervalMs;
      return;
    }

    this.recurringRequests.push({
      command,
      interval: intervalMs,
      nextTime: 0, // Execute immediately on next cycle
    });
  }

  /**
   * Cancel a recurring poll
   */
  cancelPoll(command: string): void {
    this.recurringRequests = this.recurringRequests.filter(
      (r) => r.command !== command
    );
  }

  /**
   * Get current error count
   */
  getErrorCount(): number {
    return this.errorCount;
  }

  /**
   * Check if currently connected (no recent errors)
   */
  isConnected(): boolean {
    return this.errorCount === 0;
  }

  /**
   * Main update loop
   */
  private runUpdate(): void {
    if (!this.running) return;

    this.mainTimer = null;

    // Initialize XHR if needed
    if (!this.xhr) {
      this.xhr = new XMLHttpRequest();
    }

    // Check recurring requests and add due ones to pending
    const now = Date.now();
    let recurringCommands = '';

    for (const req of this.recurringRequests) {
      if (req.nextTime < now) {
        req.nextTime = now + req.interval;
        recurringCommands += req.command + ';';
      }
    }

    // Combine pending and recurring commands
    const allCommands = this.pendingCommands + recurringCommands;
    this.pendingCommands = '';

    if (allCommands) {
      // Make the request
      const url = this.baseUrl + '/_/' + allCommands;

      this.xhr.open('GET', url, true);
      this.xhr.onreadystatechange = () => {
        if (!this.xhr || this.xhr.readyState !== 4) return;

        // Clear timeout timer
        if (this.timeoutTimer) {
          clearTimeout(this.timeoutTimer);
          this.timeoutTimer = null;
        }

        if (this.xhr.responseText !== '') {
          // Success
          const previousErrorCount = this.errorCount;
          this.errorCount = 0;

          if (previousErrorCount > 0) {
            this.onConnectionChange(true, 0);
          }

          // Parse and dispatch response
          const responses = parseResponse(this.xhr.responseText);
          this.onResponse(responses);
        } else if (this.xhr.getResponseHeader('Server') === null) {
          // Connection error
          this.handleError();
        }

        // Schedule next update
        this.scheduleNextUpdate();
      };

      // Set up timeout timer
      if (this.timeoutTimer) {
        clearTimeout(this.timeoutTimer);
      }

      this.timeoutTimer = setTimeout(() => {
        this.timeoutTimer = null;
        if (this.xhr && this.xhr.readyState !== 0 && this.xhr.readyState !== 4) {
          if (this.mainTimer) {
            clearTimeout(this.mainTimer);
            this.mainTimer = null;
          }
          this.xhr.abort();
          this.handleError();
          this.scheduleNextUpdate();
        }
      }, this.requestTimeout);

      this.xhr.send(null);
    } else {
      // No commands to send, wait and try again
      this.mainTimer = setTimeout(() => this.runUpdate(), this.timerFrequency);
    }
  }

  /**
   * Handle connection error with exponential backoff
   */
  private handleError(): void {
    const previousErrorCount = this.errorCount;

    if (this.errorCount < 8) {
      this.errorCount++;
    }

    if (previousErrorCount === 0) {
      this.onConnectionChange(false, this.errorCount);
    }
  }

  /**
   * Schedule the next update with appropriate delay
   */
  private scheduleNextUpdate(): void {
    if (!this.running) return;

    if (this.errorCount > 2) {
      // Exponential backoff: 100ms, 200ms, 400ms, 800ms, 1600ms, 3200ms
      const delay = 100 << (this.errorCount - 3);
      this.mainTimer = setTimeout(() => this.runUpdate(), delay);
    } else {
      // Immediate retry
      this.runUpdate();
    }
  }
}

// Singleton instance for simple usage
let defaultConnection: ReaperConnection | null = null;

/**
 * Get or create the default connection instance
 */
export function getConnection(options?: ReaperConnectionOptions): ReaperConnection {
  if (!defaultConnection) {
    defaultConnection = new ReaperConnection(options);
  }
  return defaultConnection;
}

/**
 * Reset the default connection (useful for testing)
 */
export function resetConnection(): void {
  if (defaultConnection) {
    defaultConnection.stop();
    defaultConnection = null;
  }
}
