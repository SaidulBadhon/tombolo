// SPDX-License-Identifier: GPL-3.0-or-later
//! Smallest useful Tombolo-style endpoint: no relays, no address lookup, direct address
//! only; one connection with a bi stream, a datagram and a TLS exporter call, so none of
//! that code is dead-stripped.
use iroh::{
    Endpoint, EndpointAddr, TransportAddr,
    endpoint::{NetReportConfig, presets},
};

const ALPN: &[u8] = b"tombolo/1";

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mk = || {
        Endpoint::builder(presets::Minimal)
            .clear_ip_transports()
            .bind_addr("127.0.0.1:0")
            .unwrap()
            .net_report_config(NetReportConfig::minimal())
    };
    let server = mk().alpns(vec![ALPN.to_vec()]).bind().await.unwrap();
    let client = mk().bind().await.unwrap();
    let addr = EndpointAddr::from_parts(
        server.id(),
        server.bound_sockets().into_iter().map(TransportAddr::Ip),
    );
    let srv = server.clone();
    let task = tokio::spawn(async move {
        let conn = srv.accept().await.unwrap().await.unwrap();
        let (mut s, mut r) = conn.accept_bi().await.unwrap();
        let d = r.read_to_end(1024).await.unwrap();
        s.write_all(&d).await.unwrap();
        s.finish().unwrap();
        let dg = conn.read_datagram().await.unwrap();
        conn.send_datagram(dg).unwrap();
        conn.closed().await;
    });
    let conn = client.connect(addr, ALPN).await.unwrap();
    let mut ekm = [0u8; 32];
    conn.export_keying_material(&mut ekm, b"EXPORTER-tombolo", b"").unwrap();
    let (mut s, mut r) = conn.open_bi().await.unwrap();
    s.write_all(b"hello").await.unwrap();
    s.finish().unwrap();
    let echoed = r.read_to_end(1024).await.unwrap();
    conn.send_datagram(bytes::Bytes::from_static(b"dg")).unwrap();
    let dg = conn.read_datagram().await.unwrap();
    println!("ok echo={} dg={} ekm={:02x}{:02x}", echoed.len(), dg.len(), ekm[0], ekm[1]);
    conn.close(0u32.into(), b"");
    client.close().await;
    server.close().await;
    let _ = task.await;
}
