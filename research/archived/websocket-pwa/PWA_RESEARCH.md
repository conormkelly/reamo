# iOS PWA WebSocket connections fail silently after suspension

**Your REAPER controller works in Safari but fails in iOS PWA standalone mode because iOS aggressively suspends PWAs after ~5 seconds in background, killing WebSocket connections without firing the `onclose` event.** The connection appears open (`readyState === OPEN`) but is actually dead—a "zombie connection." Your existing reconnection logic never triggers because it waits for an event that never fires. The solution is to use `visibilitychange` events to force-check and reconnect on every app resume, never trusting the WebSocket's reported state.

---

## iOS suspends PWAs in 5 seconds and kills your WebSocket

When an iOS PWA goes to background (user switches apps, locks screen, or presses home), iOS gives it approximately **5 seconds of execution time**, then completely freezes JavaScript execution. This differs dramatically from Safari tabs, which continue running with throttling. The frozen PWA remains in memory but executes no code—timers stop, event handlers cease, and network connections become stale.

**Critical WebSocket behavior during iOS suspension:**

- WebSocket connections are **terminated by iOS** when the PWA freezes, but the JavaScript WebSocket object retains `readyState === WebSocket.OPEN`
- The `onclose` event is **not guaranteed to fire** during network disruption (this was a significant bug in Safari 15.6.1 through 16.x, partially fixed in Safari 17.3+)
- When the PWA resumes, your code believes the connection is active when it's actually dead
- Server-side sees no activity and may have already closed the connection, but your client doesn't know

The distinction that matters isn't foreground/background—it's **running versus suspended**. A WebSocket that was working fine will silently become unusable the moment iOS freezes your app.

## Timer suspension breaks exponential backoff logic

When iOS suspends your PWA, `setTimeout` and `setInterval` callbacks are **paused, not lost**. They resume when the app returns to foreground, but this creates several problems for reconnection logic:

Pending `setTimeout` callbacks that should have fired during suspension will fire immediately upon resume—potentially causing a burst of retry attempts. If your backoff calculates delays based on wall-clock time, the suspended period doesn't count toward your delay. Your code might attempt multiple reconnections in rapid succession because scheduled retries from before suspension suddenly all execute at once.

The safe pattern is to **reset your reconnection state entirely on visibility change** rather than relying on scheduled timers:

```javascript
let lastActiveTime = Date.now();

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    const elapsed = Date.now() - lastActiveTime;
    // If suspended for more than 10 seconds, assume connection is dead
    if (elapsed > 10000) {
      reconnectDelay = 1000; // Reset backoff
      forceReconnect();
    }
  } else {
    lastActiveTime = Date.now();
  }
});
```

## Detecting zombie connections requires application-level heartbeats

The browser's WebSocket API **does not expose RFC 6455 protocol-level ping/pong frames** to JavaScript. Browsers handle these automatically at the protocol level, but you cannot send ping frames from JavaScript, receive ping events, or access TCP keepalive settings. You must implement application-level heartbeats to reliably detect dead connections.

**Health check pattern for zombie detection:**

```javascript
function checkConnectionHealth() {
  return new Promise((resolve, reject) => {
    if (ws.readyState !== WebSocket.OPEN) {
      reject(new Error('Not connected'));
      return;
    }

    const timeout = setTimeout(() => {
      reject(new Error('Zombie connection detected'));
    }, 5000);

    const handler = (event) => {
      const data = JSON.parse(event.data);
      if (data.type === 'pong') {
        clearTimeout(timeout);
        ws.removeEventListener('message', handler);
        resolve(true);
      }
    };

    ws.addEventListener('message', handler);
    ws.send(JSON.stringify({ type: 'ping', timestamp: Date.now() }));
  });
}
```

**Recommended timeout values for DAW control applications:** Use a **10-15 second ping interval** with a **5-10 second pong timeout**. Low-latency applications like REAPER control benefit from faster detection. Always send a health check ping immediately when `visibilitychange` fires with `visible` state—don't trust that the connection survived suspension.

## The visibilitychange event is your primary weapon

The Page Lifecycle API (`freeze`/`resume` events) **does not work on iOS Safari**—it's Chromium-only. Safari does not fire `freeze`, `resume`, or set `document.wasDiscarded`. The `beforeunload` and `unload` events are deprecated on iOS and fire unreliably.

**`visibilitychange` is the only reliable cross-platform event** for detecting iOS PWA suspension and resume. It fires immediately when the page visibility changes and is supported with **96.73% global browser coverage**.

**Complete reconnection pattern for iOS PWA:**

```javascript
class PWAWebSocketManager {
  constructor(url) {
    this.url = url;
    this.lastActiveTime = Date.now();
    
    document.addEventListener('visibilitychange', () => this.handleVisibilityChange());
    window.addEventListener('online', () => this.connect());
    window.addEventListener('offline', () => this.ws?.close());
    
    // Initial connection with small delay for PWA launch timing
    setTimeout(() => this.connect(), 100);
  }

  handleVisibilityChange() {
    if (document.visibilityState === 'visible') {
      const elapsed = Date.now() - this.lastActiveTime;
      if (elapsed > 10000 || this.ws?.readyState !== WebSocket.OPEN) {
        this.forceReconnect();
      } else {
        this.sendHealthCheck();
      }
    } else {
      this.lastActiveTime = Date.now();
    }
  }

  forceReconnect() {
    this.ws?.close();
    this.connect();
    // Request full state sync from REAPER after reconnection
    this.requestStateSync();
  }
}
```

## iOS is far more aggressive than Android with PWA suspension

Android Chrome gives PWAs approximately **5+ minutes** before freezing, compared to iOS's **~5 seconds**. Android also fires the `freeze` event before suspension, allowing graceful connection cleanup, while iOS provides no warning.

| Capability | iOS Safari PWA | Android Chrome PWA |
|------------|----------------|-------------------|
| Background execution time | ~5 seconds | ~5 minutes |
| `freeze`/`resume` events | ❌ Not supported | ✅ Supported |
| `document.wasDiscarded` | ❌ Not supported | ✅ Supported |
| Background Sync API | ❌ Not supported | ✅ Supported |
| WebSocket during suspension | Killed silently | Stays open (timers suspended) |

**Android-specific note:** While Android keeps WebSocket connections open longer, JavaScript timers are completely suspended when the screen is off. Server-side timeouts will still disconnect idle clients. The same `visibilitychange` reconnection pattern works for both platforms, but Android developers can additionally use the Page Lifecycle API for more graceful handling.

## iOS PWA lacks native pull-to-refresh in standalone mode

Safari provides native pull-to-refresh in the browser, but **removes it entirely in standalone PWA mode** when you add the app to the home screen with `display: standalone`. The PWA must implement its own refresh mechanism.

**To implement custom pull-to-refresh:**

First, prevent the rubber-band overscroll effect using CSS (Safari 16+):

```css
html, body {
  overscroll-behavior-y: contain;
}
```

Then use a React library like `react-use-pull-to-refresh` which includes PWA detection and iOS-style spinner animations. Alternatively, implement touch event handlers that track `touchstart`, `touchmove`, and `touchend` to detect downward pulls at the top of the scroll container.

For a REAPER controller specifically, adding an explicit **reconnect button in the UI** may be more appropriate than pull-to-refresh, since users need immediate visual feedback about connection state.

## PWA initialization timing can cause initial connection failures

There are known differences in when JavaScript starts executing between browser page load and PWA standalone launch. On cold start, a PWA launched from the home screen after termination may have longer initialization as it loads from scratch. JavaScript may attempt WebSocket connection before the network stack is fully ready.

**Add a small delay before initial WebSocket connection:**

```javascript
// In PWA initialization
if (window.matchMedia('(display-mode: standalone)').matches) {
  // PWA standalone mode - add connection delay
  setTimeout(() => connectWebSocket(), 200);
} else {
  connectWebSocket();
}
```

Also check `navigator.onLine` before connecting and listen for the `online` event if initially offline. Service Worker initialization can also affect timing—ensure your WebSocket logic doesn't depend on Service Worker state.

## Recommended libraries for production use

**reconnecting-websocket** is the most battle-tested option with **382K+ weekly downloads**, built-in exponential backoff, message buffering during reconnection, and compatibility with React Native and Node.js:

```javascript
import ReconnectingWebSocket from 'reconnecting-websocket';

const rws = new ReconnectingWebSocket('ws://reaper-server/ws', [], {
  connectionTimeout: 4000,
  maxRetries: 10,
  maxReconnectionDelay: 30000,
  minReconnectionDelay: 1000 + Math.random() * 500 // Built-in jitter
});
```

**react-use-websocket** provides React hooks with built-in reconnection and works well with the visibility change pattern:

```javascript
const { sendJsonMessage, lastJsonMessage, readyState } = useWebSocket(url, {
  shouldReconnect: () => true,
  reconnectAttempts: 10,
  reconnectInterval: 3000,
  retryOnError: true
});
```

**For your REAPER controller, combine `reconnecting-websocket` with custom `visibilitychange` handling** since the library's reconnection logic won't detect iOS zombie connections on its own.

## The critical Safari bug is fixed, but use fallbacks

**WebKit Bug #247943** caused `onclose` events to not fire when network connectivity was lost in Safari 15.6.1 through 16.x. This was fixed in Safari 17.3+. However, the `onclose` event still doesn't fire reliably during iOS PWA suspension—the fix addressed network disconnection, not app freezing.

**Always implement the `online`/`offline` event fallback for older iOS versions:**

```javascript
window.addEventListener('offline', () => {
  ws.close();
  setConnectionState('offline');
});

window.addEventListener('online', () => {
  forceReconnect();
});
```

## Conclusion

Your iOS PWA WebSocket issues stem from iOS's aggressive ~5-second suspension policy that kills connections without triggering `onclose` events. The solution requires three components: **use `visibilitychange` as your primary suspension detection** (Page Lifecycle API doesn't work on iOS), **implement application-level heartbeat ping/pong** to detect zombie connections, and **force-reconnect on every resume** with full state synchronization from REAPER.

The `reconnecting-websocket` library handles exponential backoff and message buffering, but you must add custom `visibilitychange` handling on top of it. For your REAPER controller specifically, add a visible connection status indicator in the UI and consider a manual reconnect button—users controlling audio equipment need immediate feedback about connection state. The **100-200ms initialization delay** for PWA cold starts should resolve your initial connection failures in standalone mode.
