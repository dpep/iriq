use iriq::{normalize, parse};

#[test]
fn basic_normalize() {
    assert_eq!(
        normalize("https://foo.com/users/123").unwrap(),
        "https://foo.com/users/{user_id}"
    );
}

#[test]
fn version_path() {
    assert_eq!(
        normalize("https://foo.com/api/v1/status").unwrap(),
        "https://foo.com/api/{version}/status"
    );
}

#[test]
fn currency_upcase() {
    assert_eq!(
        normalize("https://shop.com/pricing/usd?currency=eur").unwrap(),
        "https://shop.com/pricing/USD?currency=EUR"
    );
}

#[test]
fn ip_collapse() {
    assert_eq!(
        normalize("https://foo.com/probe/192.168.1.1").unwrap(),
        "https://foo.com/probe/{ip}"
    );
}

#[test]
fn urn_isbn() {
    assert_eq!(
        normalize("urn:isbn:0451450523").unwrap(),
        "urn:isbn:{isbn_id}"
    );
}

#[test]
fn parse_https() {
    let iri = parse("https://Foo.com:443/Bar").unwrap();
    assert_eq!(iri.host, "foo.com");
    assert_eq!(iri.port, 0);
    assert_eq!(iri.path_segments, vec!["Bar"]);
}

#[test]
fn param_phone_hint() {
    let out = normalize("https://foo.com/x?phone=unknown&email=tbd").unwrap();
    assert_eq!(out, "https://foo.com/x?email={email}&phone={phone}");
}
