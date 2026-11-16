//! Dev check: sign an (already patched) guest .app with a throwaway
//! self-signed cert, the same way the app signs guests with the real one.
//! cargo run -p jinject-core --example sign_guest -- /path/App.app TEAMID
use isideload::sideload::cert_identity::CertificateIdentity;
use rsa::pkcs8::{EncodePrivateKey, LineEnding};
use x509_cert::der::Decode;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let key = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
    let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
    let kp = rcgen::KeyPair::from_pkcs8_pem_and_sign_algo(&pem, &rcgen::PKCS_RSA_SHA256).unwrap();
    let mut params = rcgen::CertificateParams::new(vec![]).unwrap();
    params.distinguished_name.push(rcgen::DnType::CommonName, "Apple Development: Test (TEST)");
    let cert = params.self_signed(&kp).unwrap();
    let ident = CertificateIdentity {
        machine_id: "test".into(),
        machine_name: "test".into(),
        private_key: key,
        certificate: x509_cert::Certificate::from_der(cert.der()).unwrap(),
    };
    jinject_core::guest::sign_bundle(std::path::Path::new(&a[1]), &ident, &a[2]).expect("sign");
    println!("signed {}", a[1]);
}

