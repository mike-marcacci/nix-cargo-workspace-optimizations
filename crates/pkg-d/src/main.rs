use arrayvec::ArrayVec;

fn main() {
    let mut v: ArrayVec<i32, 4> = ArrayVec::new();
    v.push(1);
    v.push(2);
    v.push(3);
    println!("pkg-d: {:?}", v);
}
