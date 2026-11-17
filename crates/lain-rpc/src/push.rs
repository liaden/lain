//! Frames the server originates: msgpack-RPC notifications, `[2, method, params]`, sent to the
//! one connection whose [`Push`] a handler holds.

use std::sync::Arc;

use rmpv::Value;
use thiserror::Error;
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{Notify, mpsc};

/// The most pushes one connection may have waiting for its writer. A peer that lets this many
/// pile up is not reading, and is closed rather than allowed to grow the server.
pub(crate) const PUSH_BUFFER: usize = 256;

/// A connection's outbound channel for frames that answer no request. It has no public
/// constructor, so only the server can attach a connection's writer to one.
#[derive(Clone, Debug)]
pub struct Push {
    frames: mpsc::Sender<Value>,
    overflow: Arc<Notify>,
}

/// The connection behind a [`Push`] is gone, or was closed because it stopped reading.
#[derive(Debug, Error, PartialEq, Eq)]
#[error("the connection is closed")]
pub struct Closed;

pub(crate) struct Outbox {
    pub(crate) frames: mpsc::Receiver<Value>,
    pub(crate) overflow: Arc<Notify>,
}

impl Push {
    pub(crate) fn channel() -> (Self, Outbox) {
        let (sender, frames) = mpsc::channel(PUSH_BUFFER);
        let overflow = Arc::new(Notify::new());
        let push = Self {
            frames: sender,
            overflow: Arc::clone(&overflow),
        };
        (push, Outbox { frames, overflow })
    }

    /// Queues `[2, method, params]` for the connection without waiting. A full queue closes the
    /// connection, so a peer that stopped reading cannot stall the handler pushing to it.
    ///
    /// Pushes keep their order among themselves, but not against responses: a push sent before
    /// a handler returns may reach the client after that handler's response.
    pub fn send(&self, method: &str, params: Vec<Value>) -> Result<(), Closed> {
        let frame = Value::Array(vec![
            Value::from(2),
            Value::from(method),
            Value::Array(params),
        ]);
        match self.frames.try_send(frame) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => {
                self.overflow.notify_one();
                Err(Closed)
            }
            Err(TrySendError::Closed(_)) => Err(Closed),
        }
    }
}

#[cfg(test)]
mod tests {
    use rmpv::Value;

    use super::{Closed, PUSH_BUFFER, Push};
    use crate::support::RESPONSE_WAIT;

    #[tokio::test]
    async fn a_push_is_a_notification_frame() {
        let (push, mut outbox) = Push::channel();
        push.send("answer", vec![Value::from(7)])
            .expect("room in the queue");
        let frame = Value::Array(vec![
            Value::from(2),
            Value::from("answer"),
            Value::Array(vec![Value::from(7)]),
        ]);
        assert_eq!(Some(frame), outbox.frames.recv().await);
    }

    #[tokio::test]
    async fn a_full_queue_refuses_the_push_and_asks_for_a_close() {
        let (push, outbox) = Push::channel();
        for _ in 0..PUSH_BUFFER {
            push.send("tick", vec![]).expect("room in the queue");
        }
        assert!(matches!(push.send("tick", vec![]), Err(Closed)));
        tokio::time::timeout(RESPONSE_WAIT, outbox.overflow.notified())
            .await
            .expect("the overflow asked for a close");
    }

    #[test]
    fn a_push_to_a_gone_connection_is_closed() {
        let (push, outbox) = Push::channel();
        drop(outbox);
        assert!(matches!(push.send("tick", vec![]), Err(Closed)));
    }
}
