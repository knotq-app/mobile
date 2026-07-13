//! Mobile WebSocket sync transport.
//!
//! Reuses the shared `knotq_sync::ws` client core (reconnect, multiplexing,
//! keepalive, changed/presence callbacks) over a blocking tungstenite socket, and
//! a `FallbackTransport` that prefers the live socket and falls back to HTTP. When
//! connected, `sync_once`'s pull/push ride the persistent socket and a server
//! `changed` nudge forces a prompt sync; otherwise the HTTP path is unchanged.
use std::io::{self, ErrorKind};
use std::net::TcpStream;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use knotq_sync::ws::{
    RawSocket, RawSocketFactory, WsCallbacks, WsClient, WsConfig, WsRequestError,
};
use knotq_sync::{
    BatchPullRequest, BatchPullResponse, BatchPushRequest, BatchPushResponse, SyncPushRejected,
    SyncTransport,
};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{ClientRequestBuilder, Message, WebSocket};

use crate::media_sync::MobileSyncHttpClient;
use crate::MobileCoreInner;

type TokenProvider = Arc<dyn Fn() -> Option<String> + Send + Sync>;

// ── tungstenite RawSocket ───────────────────────────────────────────────────

struct TgSocket {
    socket: WebSocket<MaybeTlsStream<TcpStream>>,
}

impl RawSocket for TgSocket {
    fn poll(&mut self, timeout: Duration) -> io::Result<Option<String>> {
        set_read_timeout(self.socket.get_mut(), Some(timeout))?;
        match self.socket.read() {
            Ok(Message::Text(text)) => Ok(Some(text)),
            Ok(Message::Close(_)) => Err(io::Error::new(ErrorKind::ConnectionAborted, "ws closed")),
            Ok(_) => Ok(None),
            Err(tungstenite::Error::Io(err))
                if matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
            {
                Ok(None)
            }
            Err(err) => Err(io::Error::new(ErrorKind::Other, err.to_string())),
        }
    }

    fn send(&mut self, text: &str) -> io::Result<()> {
        self.socket
            .send(Message::Text(text.to_string()))
            .map_err(|err| io::Error::new(ErrorKind::Other, err.to_string()))
    }

    fn close(&mut self) {
        let _ = self.socket.close(None);
    }
}

fn set_read_timeout(
    stream: &mut MaybeTlsStream<TcpStream>,
    timeout: Option<Duration>,
) -> io::Result<()> {
    match stream {
        MaybeTlsStream::Plain(tcp) => tcp.set_read_timeout(timeout),
        MaybeTlsStream::Rustls(tls) => tls.sock.set_read_timeout(timeout),
        _ => Ok(()),
    }
}

struct TgFactory {
    ws_url: String,
    token_provider: TokenProvider,
}

impl RawSocketFactory for TgFactory {
    fn connect(&self) -> io::Result<Box<dyn RawSocket>> {
        let token = (self.token_provider)()
            .ok_or_else(|| io::Error::new(ErrorKind::Other, "no auth token for ws connect"))?;
        let uri = self
            .ws_url
            .parse::<tungstenite::http::Uri>()
            .map_err(|err| io::Error::new(ErrorKind::InvalidInput, err.to_string()))?;
        let request =
            ClientRequestBuilder::new(uri).with_header("Authorization", format!("Bearer {token}"));
        let (socket, _response) = tungstenite::connect(request)
            .map_err(|err| io::Error::new(ErrorKind::Other, err.to_string()))?;
        Ok(Box::new(TgSocket { socket }))
    }
}

/// `https://host[/...]` (or `http://...`) → `wss://host/v1/sync/ws` (or `ws://...`).
pub(crate) fn ws_url_from_api_base(api_base: &str) -> String {
    let trimmed = api_base.trim().trim_end_matches('/');
    let swapped = if let Some(rest) = trimmed.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = trimmed.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        trimmed.to_string()
    };
    format!("{swapped}/v1/sync/ws")
}

// ── transport (WS preferred, HTTP fallback) ─────────────────────────────────

pub(crate) struct FallbackTransport<'a> {
    ws: Option<&'a WsClient>,
    http: &'a MobileSyncHttpClient,
}

impl<'a> FallbackTransport<'a> {
    pub(crate) fn new(ws: Option<&'a WsClient>, http: &'a MobileSyncHttpClient) -> Self {
        Self { ws, http }
    }
}

impl SyncTransport for FallbackTransport<'_> {
    fn pull(&self, request: &BatchPullRequest) -> Result<BatchPullResponse> {
        if let Some(ws) = self.ws {
            if ws.is_connected() {
                match ws.request_pull(request) {
                    Ok(response) => return Ok(response),
                    Err(WsRequestError::Server { status, code }) => {
                        return Err(ws_server_pull_error(status, code))
                    }
                    Err(_) => { /* transport hiccup → HTTP fallback this run */ }
                }
            }
        }
        self.http.pull(request)
    }

    fn push(&self, request: &BatchPushRequest) -> Result<BatchPushResponse> {
        if let Some(ws) = self.ws {
            if ws.is_connected() {
                match ws.request_push(request) {
                    Ok(response) => return Ok(response),
                    Err(WsRequestError::Server { status, code }) => {
                        return Err(ws_server_push_error(status, code))
                    }
                    Err(_) => { /* transport hiccup → HTTP fallback this run */ }
                }
            }
        }
        self.http.push(request)
    }
}

fn ws_server_pull_error(_status: Option<u16>, code: String) -> anyhow::Error {
    anyhow!("sync backend rejected request: {code}")
}

fn ws_server_push_error(status: Option<u16>, code: String) -> anyhow::Error {
    if is_unauthorized(status, &code) {
        return anyhow!("sync backend rejected request: {code}");
    }
    // See media_sync::mobile_sync_push_http_error — must NOT become
    // SyncPushRejected, or the engine's reseed self-heal would rebuild and
    // re-push a full snapshot only to be rejected the same way again.
    if is_protocol_outdated(status, &code) {
        return anyhow!("sync backend rejected request: {code}");
    }
    anyhow::Error::new(SyncPushRejected { code })
}

fn is_unauthorized(status: Option<u16>, code: &str) -> bool {
    status == Some(401) || code == "unauthorized"
}

fn is_protocol_outdated(status: Option<u16>, code: &str) -> bool {
    status == Some(426) || code == "client_protocol_outdated"
}

// ── lifecycle on MobileCoreInner ────────────────────────────────────────────

impl MobileCoreInner {
    /// Start (or re-point) the persistent WebSocket for the given account, and keep
    /// the shared token holder fresh. A server `changed` nudge sets `ws_changed` so
    /// the next `sync_once` runs even if it would otherwise coalesce.
    pub(crate) fn start_ws_sync(&mut self, api_base: &str, bearer_token: &str) {
        if let Ok(mut token) = self.ws_token.lock() {
            *token = bearer_token.to_string();
        }
        if self.ws_api_base.as_deref() != Some(api_base) {
            self.stop_ws_sync();
        }
        if self.ws_client.is_some() {
            return;
        }
        let token_holder = Arc::clone(&self.ws_token);
        let token_provider: TokenProvider = Arc::new(move || {
            token_holder
                .lock()
                .ok()
                .map(|token| token.clone())
                .filter(|token| !token.is_empty())
        });
        let ws_changed = Arc::clone(&self.ws_changed);
        let ws_changed_on_connect = Arc::clone(&self.ws_changed);
        let callbacks = WsCallbacks {
            on_changed: Box::new(move || ws_changed.store(true, Ordering::SeqCst)),
            on_presence: Box::new(|_event| {}),
            // (Re)connected: flag a catch-up so the next nudge tick syncs — this
            // reconciles any `changed` missed while the socket was down without
            // foreground polling.
            on_connect: Box::new(move || ws_changed_on_connect.store(true, Ordering::SeqCst)),
        };
        let factory = Box::new(TgFactory {
            ws_url: ws_url_from_api_base(api_base),
            token_provider,
        });
        self.ws_client = Some(Arc::new(WsClient::start(
            factory,
            WsConfig::default(),
            callbacks,
        )));
        self.ws_api_base = Some(api_base.to_string());
    }

    /// Stop and drop the WebSocket (sign-out / app backgrounded / account switch).
    pub(crate) fn stop_ws_sync(&mut self) {
        if let Some(client) = self.ws_client.take() {
            client.shutdown();
        }
        self.ws_api_base = None;
    }

    pub(crate) fn is_ws_connected(&self) -> bool {
        self.ws_client
            .as_ref()
            .is_some_and(|client| client.is_connected())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ws_push_unauthorized_is_not_a_content_rejection() {
        let err = ws_server_push_error(Some(401), "unauthorized".to_string());

        assert!(err.downcast_ref::<SyncPushRejected>().is_none());
        assert!(format!("{err:#}").contains("unauthorized"));
    }

    #[test]
    fn ws_push_content_rejection_still_uses_push_rejected() {
        let err = ws_server_push_error(Some(403), "crdt_schema_invalid".to_string());

        let rejected = err
            .downcast_ref::<SyncPushRejected>()
            .expect("content rejection should drive push self-heal");
        assert_eq!(rejected.code, "crdt_schema_invalid");
    }

    #[test]
    fn ws_push_protocol_outdated_is_not_push_rejected() {
        let err = ws_server_push_error(Some(426), "client_protocol_outdated".to_string());

        assert!(err.downcast_ref::<SyncPushRejected>().is_none());
        assert!(format!("{err:#}").contains("client_protocol_outdated"));
    }
}
