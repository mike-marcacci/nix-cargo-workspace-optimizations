use once_cell::sync::Lazy;
use pkg_a::greet;

static APP_NAME: Lazy<String> = Lazy::new(|| "pkg-b".to_string());

fn main() {
    println!("[{}] {}", *APP_NAME, greet("Nix"));
}
