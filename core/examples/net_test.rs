//! cargo run -p jinject-core --example net_test
#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let dir = std::env::temp_dir().join("jinject-net-test");
    let e = jinject_core::Engine::new(dir, std::sync::Arc::new(|_| {}));
    println!("{}", serde_json::to_string_pretty(&e.net_test().await).unwrap());
}
