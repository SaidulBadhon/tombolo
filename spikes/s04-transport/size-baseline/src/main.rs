//! Baseline for the size measurement: the same runtime (tokio current-thread) doing a UDP
//! echo over loopback, without iroh/noq/rustls/ring.
use tokio::net::UdpSocket;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let a = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let b = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    a.send_to(b"hello", b.local_addr().unwrap()).await.unwrap();
    let mut buf = [0u8; 64];
    let (n, from) = b.recv_from(&mut buf).await.unwrap();
    b.send_to(&buf[..n], from).await.unwrap();
    let (n, _) = a.recv_from(&mut buf).await.unwrap();
    println!("ok echo={n}");
}
