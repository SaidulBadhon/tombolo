//! Spike S4 benchmark driver.
//!
//!   bench run --transport quic|tcp|tunnel --cond clean|jitter|loss1|burst3|cap100|usb
//!             [--seed N] [--out DIR]
//!
//! `run` is the driver: it hosts the impairment proxy in-process (its CPU is reported
//! separately) and spawns two child processes of this binary, `phone` and `mac`, so each
//! side's CPU can be measured on its own. Results go to `<out>/<cond>-<transport>-s<seed>.json`.

mod clock;
mod cond;
mod proxy;
mod session;
mod work;

use std::{
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use serde_json::json;

use crate::{clock::now_ns, cond::Cond};

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

fn need(args: &[String], name: &str) -> Result<String> {
    arg(args, name).with_context(|| format!("missing {name}"))
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "error".into()),
        )
        .with_writer(std::io::stderr)
        .init();
    let args: Vec<String> = std::env::args().collect();
    // `--cc` is passed explicitly to the children: `adb shell` does not forward the environment.
    if let Some(cc) = arg(&args, "--cc") {
        // SAFETY: single-threaded at this point (no runtime started yet).
        unsafe { std::env::set_var("S4_CC", cc) };
    }
    match args.get(1).map(String::as_str) {
        Some("run") => driver(&args),
        Some("phone") => tokio_main(phone(args)),
        Some("mac") => tokio_main(mac(args)),
        // For phone runs: write the test certificate locally, then `adb push` it.
        Some("gen-cert") => {
            let d = PathBuf::from(args.get(2).context("usage: bench gen-cert <dir>")?);
            std::fs::create_dir_all(&d)?;
            session::write_test_cert(&d)
        }
        _ => bail!("usage: bench run --transport quic|tcp|tunnel --cond <name> [--seed N] [--out DIR]"),
    }
}

fn tokio_main<F: std::future::Future<Output = Result<()>>>(f: F) -> Result<()> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?
        .block_on(f)
}

fn cond_of(args: &[String]) -> Result<Cond> {
    let name = need(args, "--cond")?;
    Cond::by_name(&name).with_context(|| format!("unknown condition {name}"))
}

async fn phone(args: Vec<String>) -> Result<()> {
    let transport = need(&args, "--transport")?;
    let cond = cond_of(&args)?;
    let seed: u64 = need(&args, "--seed")?.parse()?;
    let cert_dir = PathBuf::from(need(&args, "--cert-dir")?);
    let bind_any = arg(&args, "--bind").as_deref() == Some("any");
    let port: u16 = arg(&args, "--port").unwrap_or_else(|| "0".into()).parse()?;
    let (listener, addr) =
        session::PhoneListener::bind(&transport, &cert_dir, bind_any, port).await?;
    println!("READY {addr}");
    std::io::stdout().flush()?;
    let mut line = String::new();
    if std::io::stdin().read_line(&mut line)? == 0 {
        // stdin not forwarded (old adb): start 3 s from now.
        line = "GOIN 3000".into();
    }
    // "GO <t0>": absolute start time on the shared clock (loopback runs).
    // "GOIN <ms>": start this many ms from now on our own clock (phone runs).
    let t0: u64 = if let Some(v) = line.strip_prefix("GOIN ") {
        now_ns() + v.trim().parse::<u64>()? * 1_000_000
    } else {
        line.strip_prefix("GO ")
            .context("expected GO <t0> or GOIN <ms>")?
            .trim()
            .parse()?
    };
    let ch = listener.accept().await?;
    let setup_done = now_ns();
    let mut r = work::phone_run(ch, &cond, t0, seed).await?;
    r["setup_slack_ms"] = ((t0 as f64 - setup_done as f64) / 1e6).into();
    println!("RESULT_JSON {r}");
    Ok(())
}

async fn mac(args: Vec<String>) -> Result<()> {
    let transport = need(&args, "--transport")?;
    let cond = cond_of(&args)?;
    let addr = need(&args, "--connect")?.parse()?;
    let t0: u64 = need(&args, "--t0")?.parse()?;
    let cert_dir = PathBuf::from(need(&args, "--cert-dir")?);
    let bind_any = arg(&args, "--bind").as_deref() == Some("any");
    let t = now_ns();
    let ch = session::mac_connect(&transport, addr, &cert_dir, bind_any).await?;
    let connect_ms = (now_ns() - t) as f64 / 1e6;
    let mut r = work::mac_run(ch, &cond, t0).await?;
    r["connect_ms"] = connect_ms.into();
    println!("RESULT_JSON {r}");
    Ok(())
}

fn driver(args: &[String]) -> Result<()> {
    let transport = need(args, "--transport")?;
    let cond = cond_of(args)?;
    let seed: u64 = arg(args, "--seed").unwrap_or_else(|| "1".into()).parse()?;
    // QUIC congestion controller (inherited by the children through the environment).
    let cc = arg(args, "--cc").unwrap_or_else(|| "cubic".into());
    unsafe { std::env::set_var("S4_CC", &cc) };
    let label = if cc == "cubic" || !(transport.contains("quic") || transport.contains("tunnel")) {
        transport.clone()
    } else {
        format!("{transport}+{cc}")
    };
    let out_dir = PathBuf::from(arg(args, "--out").unwrap_or_else(|| "results/s4/raw".into()));
    std::fs::create_dir_all(&out_dir)?;
    // `--cert-dir`: reuse a certificate made with `bench gen-cert` (phone runs push the same
    // files to the phone); otherwise a throwaway one per run.
    let own_cert = arg(args, "--cert-dir").is_none();
    let cert_dir = match arg(args, "--cert-dir") {
        Some(d) => PathBuf::from(d),
        None => {
            let d = std::env::temp_dir().join(format!("tombolo-s4-{}", std::process::id()));
            std::fs::create_dir_all(&d)?;
            session::write_test_cert(&d)?;
            d
        }
    };
    let exe = std::env::current_exe()?;
    let wall = Instant::now();
    let cpu0 = clock::cpu_us();

    // Where the phone side runs and how the Mac reaches it:
    //   proxy (default): phone is a local child process, reached through the impairment proxy;
    //   direct:          phone runs elsewhere (e.g. `--phone-cmd "adb shell /data/local/tmp/bench"`)
    //                    and is reached at --phone-host:<port> (Wi-Fi runs);
    //   adb-forward:     as direct, but reached through `adb forward` (USB runs; TCP only).
    let path = arg(args, "--path").unwrap_or_else(|| "proxy".into());
    let remote = path != "proxy";
    let phone_cmd: Vec<String> = match arg(args, "--phone-cmd") {
        Some(c) => c.split_whitespace().map(String::from).collect(),
        None => vec![exe.to_string_lossy().into_owned()],
    };
    let phone_cert_dir =
        arg(args, "--phone-cert-dir").unwrap_or_else(|| cert_dir.to_string_lossy().into_owned());
    let phone_port = arg(args, "--phone-port").unwrap_or_else(|| "0".into());
    if path == "adb-forward" && transport == "quic" {
        bail!("adb forward carries TCP only; use tcp, rawtcp, tunnel or tunnel-lean");
    }
    let mut phone = Command::new(&phone_cmd[0])
        .args(&phone_cmd[1..])
        .args(["phone", "--transport", &transport, "--cond", cond.name])
        .args(["--seed", &seed.to_string(), "--port", &phone_port])
        .args(["--bind", if remote { "any" } else { "loopback" }])
        .args(["--cert-dir", &phone_cert_dir, "--cc", &cc])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;
    let mut phone_out = BufReader::new(phone.stdout.take().unwrap());
    let mut line = String::new();
    phone_out.read_line(&mut line)?;
    let phone_addr: std::net::SocketAddr = line
        .strip_prefix("READY ")
        .with_context(|| format!("phone said {line:?}"))?
        .trim()
        .parse()?;

    let mut proxy = None;
    let mut forward = None;
    let connect: std::net::SocketAddr = match path.as_str() {
        "proxy" => {
            let p = match transport.as_str() {
                "quic" => proxy::udp_proxy(&cond, phone_addr, seed)?,
                "tcp" | "rawtcp" | "tunnel" | "tunnel-lean" => {
                    proxy::tcp_relay(&cond, phone_addr, seed)?
                }
                t => bail!("unknown transport {t}"),
            };
            let a = p.listen;
            proxy = Some(p);
            a
        }
        "direct" => {
            let host: std::net::IpAddr = need(args, "--phone-host")?.parse()?;
            (host, phone_addr.port()).into()
        }
        "adb-forward" => {
            let adb = arg(args, "--adb").unwrap_or_else(|| "adb".into());
            let o = Command::new(&adb)
                .args(["forward", "tcp:0", &format!("tcp:{}", phone_addr.port())])
                .output()?;
            let local: u16 = String::from_utf8_lossy(&o.stdout).trim().parse()
                .with_context(|| format!("adb forward said {:?}", String::from_utf8_lossy(&o.stderr)))?;
            forward = Some((adb, local));
            ([127, 0, 0, 1], local).into()
        }
        p => bail!("unknown --path {p}"),
    };
    // Start the workload after a fixed delay, leaving time for the handshake(s).
    let start_ms: u64 = if remote { 3000 } else { 2000 };
    let t0 = now_ns() + start_ms * 1_000_000;
    if remote {
        writeln!(phone.stdin.as_mut().unwrap(), "GOIN {start_ms}")?;
    } else {
        writeln!(phone.stdin.as_mut().unwrap(), "GO {t0}")?;
    }
    phone.stdin.as_mut().unwrap().flush()?;

    let mac = Command::new(&exe)
        .args(["mac", "--transport", &transport, "--cond", cond.name])
        .args(["--connect", &connect.to_string(), "--t0", &t0.to_string()])
        .args(["--bind", if path == "direct" { "any" } else { "loopback" }])
        .args(["--cc", &cc])
        .arg("--cert-dir")
        .arg(&cert_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;

    let budget = Duration::from_secs_f64(cond.secs + 30.0);
    let phone_json = std::thread::spawn(move || {
        let mut s = String::new();
        let mut l = String::new();
        while phone_out.read_line(&mut l).unwrap_or(0) > 0 {
            s.push_str(&l);
            l.clear();
        }
        let _ = phone.wait();
        s
    });
    let mac_out = wait_output(mac, budget)?;
    let phone_text = phone_json.join().unwrap();
    let parse = |s: &str| -> serde_json::Value {
        s.lines()
            .find_map(|l| l.strip_prefix("RESULT_JSON "))
            .and_then(|j| serde_json::from_str(j).ok())
            .unwrap_or(json!(null))
    };
    let result = json!({
        "transport": label,
        "cc": cc,
        "cond": cond.name,
        "cond_detail": format!("{cond:?}"),
        "seed": seed,
        "t0": t0,
        "phone": parse(&phone_text),
        "mac": parse(&mac_out),
        "path": path,
        "bulk_windows": cond.bulk.windows(),
        "proxy": proxy.as_ref().map(|p| p.json()),
        "proxy_cpu_s": (clock::cpu_us() - cpu0) as f64 / 1e6,
        "wall_s": wall.elapsed().as_secs_f64(),
    });
    let path = out_dir.join(format!("{}-{}-s{}.json", cond.name, label, seed));
    std::fs::write(&path, serde_json::to_string_pretty(&result)?)?;
    if own_cert {
        let _ = std::fs::remove_dir_all(&cert_dir);
    }
    if let Some((adb, local)) = forward {
        let _ = Command::new(adb).args(["forward", "--remove", &format!("tcp:{local}")]).status();
    }
    let f = &result["mac"]["frame_latency_ms"]["all"];
    println!(
        "{:<7} {:<6} seed={} frames p50={} p95={} p99={} | load p95={} | audio lost+late40={}% | ctrl rtt p95={} | bulk {} Mbit/s | -> {}",
        cond.name,
        label,
        seed,
        f["p50"],
        f["p95"],
        f["p99"],
        result["mac"]["frame_latency_ms"]["load"]["p95"],
        result["mac"]["audio"]["lost_or_late40_pct"],
        result["mac"]["control_rtt_ms"]["all"]["p95"],
        result["mac"]["bulk"]["mbit_s"],
        path.display()
    );
    Ok(())
}

fn wait_output(mut child: std::process::Child, budget: Duration) -> Result<String> {
    let mut out = child.stdout.take().unwrap();
    let h = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = std::io::Read::read_to_string(&mut out, &mut s);
        s
    });
    let start = Instant::now();
    loop {
        if child.try_wait()?.is_some() {
            break;
        }
        if start.elapsed() > budget {
            let _ = child.kill();
            bail!("child timed out");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(h.join().unwrap())
}
