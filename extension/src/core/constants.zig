/// Shared constants used across multiple modules.
/// Consolidates duplicated definitions to ensure consistency.

// =============================================================================
// String Length Limits
// =============================================================================

/// Maximum length for track, item, playlist names
pub const MAX_NAME_LEN: usize = 128;

/// Maximum length for FX plugin names
pub const MAX_FX_NAME_LEN: usize = 128;

/// Maximum length for send/receive names
pub const MAX_SEND_NAME_LEN: usize = 128;

/// GUID string length: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} = 38 chars + padding
pub const MAX_GUID_LEN: usize = 40;

// =============================================================================
// Entity Limits (Production)
// =============================================================================

/// Maximum tracks supported (including master at index 0)
pub const MAX_TRACKS: usize = 128;

/// Maximum FX plugins per track
pub const MAX_FX_PER_TRACK: usize = 64;

/// Maximum sends per track
pub const MAX_SENDS_PER_TRACK: usize = 16;

/// Maximum items supported
pub const MAX_ITEMS: usize = 512;

/// Maximum takes per item
pub const MAX_TAKES_PER_ITEM: usize = 8;

/// Maximum markers in project
pub const MAX_MARKERS: usize = 256;

/// Maximum regions in project
pub const MAX_REGIONS: usize = 256;

// =============================================================================
// Subscription Limits
// =============================================================================

/// Maximum WebSocket clients for subscriptions
pub const MAX_SUBSCRIPTION_CLIENTS: usize = 16;

/// Maximum tracks a single client can subscribe to
pub const MAX_TRACKS_PER_CLIENT: usize = 64;

/// Maximum GUIDs a single client can subscribe to
pub const MAX_GUIDS_PER_CLIENT: usize = 64;

/// Maximum toggle command IDs a single client can subscribe to
pub const MAX_COMMAND_IDS_PER_CLIENT: usize = 256;
