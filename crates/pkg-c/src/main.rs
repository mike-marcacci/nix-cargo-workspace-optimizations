use pkg_a::greet;

fn main() {
    let mut buf = itoa::Buffer::new();
    let num = buf.format(42);
    println!("{} ({})", greet("from pkg-c"), num);
}
