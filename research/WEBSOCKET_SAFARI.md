# Safari 18 WebSocket cold-start failure: diagnosis and workarounds

**Safari's NSURLSession WebSocket backend, introduced in iOS 15 and now mandatory, exhibits lazy initialization that causes WebSocket connections to hang on initial page load.** Your symptoms match a well-documented pattern across iOS 15–18+, where the network stack isn't fully initialized on cold start but "warms up" after page refreshes or visibility changes. The good news: aggressive retry strategies and several code-level workarounds can resolve this without user interaction.

## The root cause: NSURLSession WebSocket lazy initialization

Safari switched from its legacy WebSocket implementation to **NSURLSession WebSocket** starting with iOS 15. This architectural change introduced multiple regressions documented in WebKit Bugzilla, including the exact "WebSocket is closed before the connection is established" error you're experiencing.

**Critical discovery from WebKit source analysis**: WebKit intentionally delays network initialization as a launch-time optimization. The documentation states: *"Delay issuing ManagedSession & Network Extension sandbox extensions until a load is actually issued. This is a Safari launch time optimization since the checks needed to decide whether or not to issue the extensions are expensive."* This explains why HTTP fetches work immediately (they trigger initialization) but WebSocket connections on a separate code path remain stuck.

The **90-second warm-up phenomenon** was reported on Apple Developer Forums—one developer found WebSocket "consistently succeeds after 90 seconds of the app being in the foreground initially." Your 2-refresh pattern and visibility-change fix align perfectly with this: each interaction progressively initializes Safari's network subsystems.

## Why refreshes and visibility changes fix it

The behavior you're seeing follows a clear pattern documented across multiple bug reports:

- **First load**: NSURLSession WebSocket backend isn't initialized; connection attempts queue or block
- **First refresh**: Partial cache/state warming occurs; still insufficient for WebSocket
- **Second refresh**: Network process fully running; WebSocket connects in 26ms
- **Visibility change**: Triggers internal network stack reinitialization; equivalent to a "soft restart"

WebKit Bug 228296 revealed an additional wrinkle: closing WebSockets while in CONNECTING state can corrupt Safari's internal state, requiring browser restart. Jorge Manrubia from Basecamp discovered that proactive visibility-change handlers prevented this corruption—implementing them stopped customer complaints "within a day."

## Near-identical bug confirmed in iOS 26 Beta

An Apple Developer Forums post from July 2025 describes your exact symptom: *"Need to call connectWebSocket() twice—calling connectWebSocket() once will sometimes work, sometimes not."* This was reported **fixed in iOS 26 Beta 5**, confirming Apple is aware of and actively fixing this class of bugs. However, waiting for iOS 26 isn't practical for your users.

## Workarounds that don't require user interaction

Based on community reports and WebKit bug discussions, here are the most effective programmatic solutions:

### Aggressive retry with short delays (most reliable)

Since the issue is timing-related, rapid-fire connection attempts can hit the initialization window:

```javascript
class SafariWebSocketConnect {
  constructor(url, onConnected) {
    this.url = url;
    this.onConnected = onConnected;
    this.attempts = 0;
    this.maxAttempts = 20;
    this.connect();
  }

  connect() {
    const ws = new WebSocket(this.url);
    const attemptNum = this.attempts;
    
    const timeout = setTimeout(() => {
      if (ws.readyState === WebSocket.CONNECTING) {
        ws.close();
        if (this.attempts < this.maxAttempts) {
          this.attempts++;
          setTimeout(() => this.connect(), 50 + (this.attempts * 50));
        }
      }
    }, 2000);

    ws.onopen = () => {
      clearTimeout(timeout);
      console.log(`Connected after ${attemptNum + 1} attempts`);
      this.onConnected(ws);
    };
    
    ws.onerror = () => { clearTimeout(timeout); ws.close(); };
  }
}
```

This pattern mirrors what naturally happens when you refresh twice—it just automates it. The incremental delay (50ms, 100ms, 150ms...) allows Safari's network stack to catch up.

### Pre-warm the network stack before WebSocket

Fire multiple small HTTP requests to "wake up" Safari's networking before attempting WebSocket:

```javascript
async function prewarmAndConnect(httpBase, wsUrl) {
  // Fire 5 parallel HEAD requests to trigger network initialization
  const warmups = Array(5).fill().map((_, i) => 
    fetch(`${httpBase}/?warmup=${Date.now()}-${i}`, { 
      method: 'HEAD', 
      cache: 'no-store' 
    }).catch(() => {})
  );
  await Promise.allSettled(warmups);
  
  // Wait for triple requestAnimationFrame (browser fully "settled")
  await new Promise(resolve => {
    requestAnimationFrame(() => 
      requestAnimationFrame(() => 
        requestAnimationFrame(resolve)
      )
    );
  });
  
  return new WebSocket(wsUrl);
}
```

The triple `requestAnimationFrame` ensures the browser has completed initial rendering cycles before WebSocket creation.

### Hidden iframe pre-connection trick

Create a hidden iframe that attempts WebSocket first, potentially triggering initialization in the main page's shared network context:

```javascript
function warmupViaIframe(wsUrl) {
  return new Promise((resolve) => {
    const iframe = document.createElement('iframe');
    iframe.style.cssText = 'position:absolute;width:0;height:0;border:0;';
    iframe.srcdoc = `<script>
      const ws = new WebSocket('${wsUrl}');
      ws.onopen = ws.onerror = ws.onclose = () => parent.postMessage('ws-warmed','*');
      setTimeout(() => parent.postMessage('ws-warmed','*'), 1500);
    </script>`;
    
    const handler = (e) => {
      if (e.data === 'ws-warmed') {
        iframe.remove();
        window.removeEventListener('message', handler);
        setTimeout(resolve, 100);
      }
    };
    window.addEventListener('message', handler);
    document.body.appendChild(iframe);
  });
}

// Usage: await warmupViaIframe(wsUrl); then connect normally
```

### Recommended combined approach for your DAW controller

```javascript
async function connectToDAW(httpPort, wsPort, host = '192.168.1.26') {
  const httpBase = `http://${host}:${httpPort}`;
  const wsUrl = `ws://${host}:${wsPort}`;
  
  // Step 1: Pre-warm with HTTP requests
  await Promise.allSettled(
    Array(3).fill().map(() => fetch(httpBase, { method: 'HEAD', cache: 'no-store' }).catch(() => {}))
  );
  
  // Step 2: Wait for browser to settle
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  
  // Step 3: Aggressive retry
  return new Promise((resolve, reject) => {
    let attempts = 0;
    const maxAttempts = 15;
    
    function attempt() {
      const ws = new WebSocket(wsUrl);
      const timer = setTimeout(() => {
        if (ws.readyState === WebSocket.CONNECTING) {
          ws.close();
          if (++attempts < maxAttempts) {
            setTimeout(attempt, 100);
          } else {
            reject(new Error('WebSocket connection failed after retries'));
          }
        }
      }, 2000);
      
      ws.onopen = () => { clearTimeout(timer); resolve(ws); };
      ws.onerror = () => { clearTimeout(timer); ws.close(); };
    }
    attempt();
  });
}
```

## Server-side mitigation: disable WebSocket compression

WebKit Bug 228296 revealed that the `permessage-deflate` WebSocket extension triggers additional issues in Safari's NSURLSession implementation. If you can modify REAPER's WebSocket server configuration or use a proxy, **disable compression**:

```javascript
// Node.js ws server example
const wss = new WebSocket.Server({ 
  port: 9224,
  perMessageDeflate: false  // Critical for Safari compatibility
});
```

This eliminates an entire class of Safari-specific failures related to fragmented compressed frames.

## Fallback strategy: HTTP long-polling

If WebSocket proves unreliable, implement automatic fallback to HTTP polling. For a DAW controller where latency matters, **100ms polling** is acceptable:

```javascript
class DAWConnection {
  constructor(wsUrl, httpUrl) {
    this.wsUrl = wsUrl;
    this.httpUrl = httpUrl;
    this.mode = 'websocket';
    this.connect();
  }

  connect() {
    if (this.mode === 'polling') return this.startPolling();
    
    this.ws = new WebSocket(this.wsUrl);
    const timeout = setTimeout(() => {
      if (this.ws.readyState !== WebSocket.OPEN) {
        this.ws.close();
        this.mode = 'polling';
        this.connect();
      }
    }, 5000);
    
    this.ws.onopen = () => clearTimeout(timeout);
    this.ws.onerror = () => { this.mode = 'polling'; this.connect(); };
  }

  startPolling() {
    this.pollInterval = setInterval(async () => {
      const data = await fetch(this.httpUrl).then(r => r.json());
      this.onMessage?.(data);
    }, 100);
  }
}
```

## What to tell your musician users

For the README or setup instructions:

> **Safari users**: The app will automatically retry connections on first load. If you see a brief "connecting" status, this is normal—it should connect within 5-10 seconds. If issues persist, one page refresh will resolve it.

This sets expectations while your code handles the retry logic transparently.

## Conclusion

Your issue stems from Safari's NSURLSession WebSocket lazy initialization—a known architectural limitation, not a bug in your code. The **aggressive retry pattern combined with HTTP pre-warming** is your best bet for seamless cold-start connections without user interaction. The nearly identical bug fixed in iOS 26 Beta 5 suggests Apple is aware of this; future iOS updates may resolve it entirely. Until then, the workarounds above should provide reliable connections for your DAW controller users on Safari 18.x.
