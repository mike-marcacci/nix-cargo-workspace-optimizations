use either::Either;
use once_cell::sync::Lazy;

static GREETING: Lazy<String> = Lazy::new(|| "Hello".to_string());

pub fn greet(name: &str) -> String {
    format!("{}, {name}!", *GREETING)
}

pub fn greet_either(name: Either<&str, String>) -> String {
    match name {
        Either::Left(s) => greet(s),
        Either::Right(s) => greet(&s),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greet() {
        assert_eq!(greet("world"), "Hello, world!");
    }
}
